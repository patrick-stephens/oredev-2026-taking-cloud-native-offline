#!/usr/bin/env bash
# AIR-GAPPED: ./scripts/air-gapped.sh
# All Zarf/kubectl operations run inside the node's blocked network namespace.
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
require_tools
assert_owned
[[ -s "$ARTIFACTS/$PACKAGE" && -s "$ARTIFACTS/$INIT" ]] ||
    die "Run the connected phase first; offline mode never downloads packages."
phase "PHASE 2: AIR-GAPPED - block and prove node/pod egress"
docker exec "$NODE" sh /work/config/isolate.sh
assert_isolated

# Numerical IP avoids mistaking a DNS failure for a blocked internet route.
if docker exec "$NODE" wget -T 3 -O /dev/null http://1.1.1.1 > "$STATE/probe.log" 2>&1; then
    die "External HTTP unexpectedly succeeded."
fi
grep -Eq 'refused|unreachable|timed out' "$STATE/probe.log" ||
    die "External probe failed for an unexpected reason; inspect .state/probe.log."
printf 'PROVED: external HTTP blocked; egress firewall covers node OUTPUT and pod FORWARD.\n'
audit_egress > "$ARTIFACTS/egress-before.txt"
docker exec "$NODE" iptables -t mangle -Z ZARF_DEMO_EGRESS
docker exec "$NODE" ip6tables -t mangle -Z ZARF_DEMO_EGRESS

phase "PHASE 3: AIR-GAPPED - Zarf injector bootstraps registry, agent and Git"
if kube -n zarf get secret zarf-package-init >/dev/null 2>&1; then
    printf 'REUSING: already-initialized local delivery services.\n'
    kube -n zarf rollout status deployment/zarf-docker-registry --timeout=90s
    kube -n zarf rollout status deployment/zarf-gitea --timeout=90s
else
    target_zarf init "/work/artifacts/$INIT" --confirm --components=git-server \
        --set-variables REGISTRY_PVC_SIZE=2Gi,GIT_SERVER_PVC_SIZE=2Gi,REGISTRY_HPA_ENABLE=false \
        --timeout 180s > "$STATE/init.log" 2>&1 ||
        die "Offline init failed. Private diagnostic log: .state/init.log (may contain credentials)."
fi
printf 'INITIALIZED: registry, mutating agent and local Gitea are running.\n'

phase "PHASE 4: AIR-GAPPED - deploy the complete package"
target_zarf package deploy "/work/artifacts/$PACKAGE" --confirm --timeout 180s \
    > "$STATE/deploy.log" 2>&1 ||
    die "Offline deploy failed. Private diagnostic log: .state/deploy.log."
kube -n podinfo rollout status deployment/podinfo --timeout=90s
kube -n podinfo describe pod -l app.kubernetes.io/name=podinfo > "$ARTIFACTS/after-describe.txt"
image="$(kube -n podinfo get pod -l app.kubernetes.io/name=podinfo -o json |
    jq -r '.items[0].spec.containers[0].image')"
[[ "$image" == 127.0.0.1:*/*podinfo* || "$image" == localhost:*/*podinfo* ]] ||
    die "Image was not rewritten to Zarf's local registry: $image"
printf 'BEFORE (packaged chart): ghcr.io/stefanprodan/podinfo:6.15.0\nAFTER (admitted pod): %s\n' "$image"
kube -n podinfo get pods -o wide
target_zarf tools registry catalog > "$ARTIFACTS/registry-catalog.txt"
grep -F 'podinfo' "$ARTIFACTS/registry-catalog.txt" || die "podinfo missing from seeded registry."
target_zarf package list > "$ARTIFACTS/package-list.txt"
grep -F 'podinfo-offline' "$ARTIFACTS/package-list.txt" || die "Package not recorded in cluster."
target_zarf package inspect sbom "/work/artifacts/$PACKAGE" --output /work/artifacts/sbom-offline
# This evidence is public; only the SBOM directory is made host-readable.
docker exec "$NODE" chmod -R a+rX /work/artifacts/sbom-offline
sbom="$ARTIFACTS/sbom-offline/podinfo-offline/ghcr.io_stefanprodan_podinfo_6.15.0.json"
jq -e '.artifacts|length>0' "$sbom" >/dev/null || die "Image SBOM missing or empty."
cmp "$ARTIFACTS/sbom-connected/podinfo-offline/ghcr.io_stefanprodan_podinfo_6.15.0.json" "$sbom"
# Variables in this command are expanded inside Gitea, not on the host.
# shellcheck disable=SC2016
kube -n zarf exec deployment/zarf-gitea -c gitea -- sh -ec '
    repository="$(find /data/git/gitea-repositories -maxdepth 2 -type d -name "podinfo-*.git")"
    test -n "$repository"
    git --git-dir="$repository" cat-file -e a9b846405af7697629de8a1da335aaf639a09f34^{commit}
'
printf 'VERIFIED: pinned podinfo Git commit is present in local Gitea.\n'
response="$(kube -n podinfo exec deployment/podinfo -- wget -qO- http://127.0.0.1:9898/)"
jq -e '.version=="6.15.0"' <<< "$response" >/dev/null
assert_isolated
audit_egress | tee "$ARTIFACTS/egress-after.txt"
for family in iptables ip6tables; do
    rejected="$(docker exec "$NODE" "$family" -t mangle -nvxL ZARF_DEMO_EGRESS |
        awk '$3=="DROP" {packets += $1} END {print packets+0}')"
    [[ "$rejected" == 0 ]] ||
        die "$family recorded $rejected forbidden egress attempts during deployment; inspect the firewall evidence."
done
printf 'PASS: pod Running, local registry seeded, package listed, SBOM recovered offline.\n'
printf 'PASS: no forbidden node/pod egress attempts during init, deploy or verification.\n'
# A deliberate negative control AFTER the zero-attempt lifecycle measurement.
if kube -n podinfo exec deployment/podinfo -- wget -T 3 -O /dev/null http://1.1.1.1 \
    > "$STATE/pod-probe.log" 2>&1; then
    die "Pod unexpectedly reached the internet."
fi
grep -Eq 'refused|unreachable|timed out' "$STATE/pod-probe.log" ||
    die "Pod probe failed for an unexpected reason; inspect .state/pod-probe.log."
audit_egress > "$ARTIFACTS/egress-deliberate-pod-probe.txt"
printf 'PROVED: deliberate external HTTP from the running pod is blocked too.\n'
