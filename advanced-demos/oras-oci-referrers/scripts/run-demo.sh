#!/usr/bin/env bash
# Container commands intentionally expand variables in their own shell.
# shellcheck source-path=SCRIPTDIR disable=SC2016
set -euo pipefail
set -E
# shellcheck source=common.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"

START_SECONDS=$SECONDS
for command in flock jq diff sha256sum; do
  command -v "$command" >/dev/null || die "Required host command is missing: $command"
done
check_docker
mkdir -p "$ROOT/.state"
exec 9>"$ROOT/.demo.lock"
flock -n 9 || die "Another run or cleanup is using this demo."
RUN_DIR="$ROOT/.state/run-$(date -u +%Y%m%dT%H%M%SZ)-$$"
mkdir -p "$RUN_DIR"
ln -sfn "$(basename "$RUN_DIR")" "$ROOT/.state/latest"
trap 'echo "ERROR: demo stopped at line $LINENO after $((SECONDS - START_SECONDS))s; evidence: $RUN_DIR. Run scripts/cleanup.sh when ready." >&2' ERR
cleanup_resources

phase '1 / CONNECTED' 'preload pinned tooling and the official stable Alpine image'
docker pull "$ZOT_IMAGE"
docker build --build-arg "ALPINE_IMAGE=$ALPINE_IMAGE" \
  --build-arg "ORAS_IMAGE=$ORAS_IMAGE" --build-arg "SYFT_IMAGE=$SYFT_IMAGE" \
  -t "$TOOLS_IMAGE" -f "$ROOT/config/Dockerfile" "$ROOT/config"
docker network create --label "$LABEL=$PREFIX" "$UPLINK" >/dev/null
start_registry "$CONNECTED" "$UPLINK" "$PREFIX-connected-data"
tools "$CONNECTED" bash -euo pipefail -c \
  'oras version; syft version; curl --version; jq --version; iptables --version; apk info -v' \
  > "$RUN_DIR/tool-versions.txt"
docker version > "$RUN_DIR/docker-version.txt"
docker image inspect "$ZOT_IMAGE" "$TOOLS_IMAGE" > "$RUN_DIR/tool-images.json"

phase '2 / CONNECTED' 'build the image + SBOM + policy + fake model graph'
tools "$CONNECTED" oras copy --platform linux/amd64 \
  "$ALPINE_IMAGE" "$REPOSITORY:$TAG" --to-plain-http
SUBJECT="$(tools "$CONNECTED" oras resolve --plain-http "$REPOSITORY:$TAG")"
printf '%s\n' "$SUBJECT" > "$RUN_DIR/subject.txt"
# Scan the exact pushed image from a local layout, never the host Docker cache.
tools "$CONNECTED" oras copy --from-plain-http --to-oci-layout \
  "$REPOSITORY@$SUBJECT" /work/scan:alpine
tools "$CONNECTED" syft scan oci-dir:/work/scan \
  -o spdx-json=/work/sbom.spdx.json
tools "$CONNECTED" jq -e '.spdxVersion == "SPDX-2.3" and (.packages | length > 0)' \
  /work/sbom.spdx.json >/dev/null
tools "$CONNECTED" bash -euo pipefail -c '
  cp /demo/policy.json policy.json
  printf "FAKE MODEL: demo bytes only; not a trained model or a ModelKit package.\n" > model.bin
  head -c $((1024 - $(wc -c < model.bin))) /dev/zero >> model.bin
  [[ $(wc -c < model.bin) == 1024 ]]
  sha256sum sbom.spdx.json policy.json model.bin > payloads.sha256
'
for artifact in "sbom.spdx.json:$SBOM_TYPE" "policy.json:$POLICY_TYPE" "model.bin:$MODEL_TYPE"; do
  tools "$CONNECTED" oras attach --plain-http --distribution-spec v1.1-referrers-api \
    --artifact-type "${artifact#*:}" "$REPOSITORY@$SUBJECT" "$artifact"
done
tools "$CONNECTED" bash /scripts/snapshot.sh connected "$SUBJECT"
echo 'Raw OCI 1.1 referrers endpoint (not a synthetic sha256-*.referrers tag):'
jq . "$RUN_DIR/connected/referrers.json"

phase '3 / CONNECTED' 'export the entire graph, not just the image'
tools "$CONNECTED" oras copy --recursive --from-plain-http \
  --from-distribution-spec v1.1-referrers-api --to-oci-layout \
  "$REPOSITORY@$SUBJECT" /work/bundle:alpine
tools "$CONNECTED" bash -euo pipefail -c '
  cd bundle
  find . -type f -print0 | sort -z | xargs -0 sha256sum > /work/bundle.sha256
'
du -sh "$RUN_DIR/bundle"

phase '4 / AIR-GAPPED' 'remove upstream; enforce and test isolation'
# No pulls, builds, package installs, host HTTP requests or source registry after this line.
remove_owned container "$CONNECTED"
remove_owned network "$UPLINK"
docker network create --internal --label "$LABEL=$PREFIX" "$INTERNAL" >/dev/null
start_registry "$OFFLINE" "$INTERNAL" "$PREFIX-airgapped-data"
firewall '
  iptables -N DEMO_OFFLINE
  iptables -A DEMO_OFFLINE -o lo -d 127.0.0.1/32 -j ACCEPT
  iptables -A DEMO_OFFLINE -j REJECT
  iptables -I OUTPUT 1 -j DEMO_OFFLINE
  ip6tables -N DEMO_OFFLINE
  ip6tables -A DEMO_OFFLINE -o lo -d ::1/128 -j ACCEPT
  ip6tables -A DEMO_OFFLINE -j REJECT
  ip6tables -I OUTPUT 1 -j DEMO_OFFLINE
'
docker network inspect "$INTERNAL" > "$RUN_DIR/offline-network.json"
docker inspect "$OFFLINE" > "$RUN_DIR/offline-container.json"
jq -e '.[0].Internal == true' "$RUN_DIR/offline-network.json" >/dev/null
jq -e --arg network "$INTERNAL" \
  '.[0].NetworkSettings.Networks | keys == [$network]' "$RUN_DIR/offline-container.json" >/dev/null
tools "$OFFLINE" bash -euo pipefail -c '
  ip route | tee /work/offline-routes.txt
  if ip route | grep -q "^default "; then echo "ERROR: unexpected default route" >&2; exit 1; fi
  ip -6 route | tee /work/offline-routes-v6.txt
  if ip -6 route | grep -q "^default "; then echo "ERROR: unexpected IPv6 default route" >&2; exit 1; fi
  blocked() {
    local name=$1
    shift
    if curl --noproxy "*" -fsS --connect-timeout 2 --max-time 3 "$@" > /work/probe-body.txt 2> /work/probe-error.txt; then
      echo "ERROR: $name unexpectedly reachable" >&2
      exit 1
    fi
    echo "BLOCKED as expected: $name"
    cat /work/probe-error.txt
  }
  blocked external-IPv4 https://1.1.1.1
  blocked external-IPv6 "https://[2606:4700:4700::1111]"
  blocked Docker-Hub-DNS https://registry-1.docker.io/v2/
  blocked embedded-DNS-proxy telnet://127.0.0.11:53
' | tee "$RUN_DIR/isolation-probes.txt"
firewall '
  iptables -vnxL DEMO_OFFLINE
  ip6tables -vnxL DEMO_OFFLINE
  iptables -vnxL DEMO_OFFLINE | awk '"'"'$3 == "REJECT" && $1 > 0 {found=1} END {if (!found) exit 1}'"'"'
  iptables -Z DEMO_OFFLINE
  ip6tables -Z DEMO_OFFLINE
' > "$RUN_DIR/firewall-probes.txt"

phase '5 / AIR-GAPPED' 'import bundle and prove every relationship survived'
tools "$OFFLINE" bash -euo pipefail -c 'cd bundle; sha256sum -c /work/bundle.sha256'
tools "$OFFLINE" oras copy --recursive --from-oci-layout --to-plain-http \
  --to-distribution-spec v1.1-referrers-api /work/bundle:alpine "$REPOSITORY:$TAG"
[[ "$(tools "$OFFLINE" oras resolve --plain-http "$REPOSITORY:$TAG")" == "$SUBJECT" ]]
tools "$OFFLINE" bash /scripts/snapshot.sh airgapped "$SUBJECT"
diff -u "$RUN_DIR/connected/digests.txt" "$RUN_DIR/airgapped/digests.txt"
diff -u "$RUN_DIR/connected/descriptors.json" "$RUN_DIR/airgapped/descriptors.json"
diff -u "$RUN_DIR/connected/tree.canonical.json" "$RUN_DIR/airgapped/tree.canonical.json"
while IFS= read -r artifact_digest; do
  tools "$OFFLINE" oras pull --plain-http "$REPOSITORY@$artifact_digest" \
    -o "/work/pulled/$artifact_digest"
done < <(jq -r '.manifests[].digest' "$RUN_DIR/airgapped/referrers.json")
tools "$OFFLINE" bash -euo pipefail -c '
  for file in sbom.spdx.json policy.json model.bin; do
    matches=(pulled/*/"$file")
    [[ ${#matches[@]} == 1 && -f "${matches[0]}" ]]
    cmp "$file" "${matches[0]}"
  done
  sha256sum -c payloads.sha256
'
firewall '
  iptables -vnxL DEMO_OFFLINE
  ip6tables -vnxL DEMO_OFFLINE
  for command in iptables ip6tables; do
    "$command" -vnxL DEMO_OFFLINE | awk '"'"'$3 == "REJECT" {if ($1 != 0) exit 1; found=1} END {if (!found) exit 1}'"'"'
  done
' > "$RUN_DIR/firewall-workload.txt"
tools "$OFFLINE" bash -euo pipefail -c 'cd bundle; sha256sum -c /work/bundle.sha256' >/dev/null
ELAPSED=$((SECONDS - START_SECONDS))
printf 'PASS: image + 3 referrers, identical digests, descriptors, trees and payload bytes.\nPASS: external egress blocked; zero rejected workload packets.\nTotal runtime: %ss\nEvidence: %s\n' \
  "$ELAPSED" "$RUN_DIR" | tee "$RUN_DIR/result.txt"
echo 'Registry remains isolated for inspection. Release resources with scripts/cleanup.sh.'
