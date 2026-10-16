#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
umask 077
START=$SECONDS
mkdir -p "$STATE/bin" "$STATE/evidence" "$STATE/docker" "$BUNDLE/truststore/x509/ca/offline-demo"
rm -f "$STATE/evidence/result.txt"
trap 'rc=$?; if (( rc != 0 )); then echo "FAILED after $((SECONDS-START))s; resources retained for diagnosis. Run scripts/cleanup.sh." >&2; fi' EXIT
for tool in docker kind helm curl jq openssl sha256sum tar timeout clear \
  bash uname grep sed sort tr cut base64 diff date; do need "$tool"; done
[[ $(uname -m) == x86_64 ]] || fail "This demo pins Linux amd64 images"
[[ $(kind version) == "kind $KIND_VERSION "* ]] || fail "Install kind $KIND_VERSION"
[[ $(helm version --short) == "$HELM_VERSION"* ]] || fail "Install Helm $HELM_VERSION"
docker info >/dev/null

phase '1: CONNECTED - acquire pinned tools, charts and images'
"$ROOT/scripts/cleanup.sh"
if [[ ! -x "$STATE/bin/notation" ]]; then
  base="https://github.com/notaryproject/notation/releases/download/v$NOTATION_VERSION"
  archive="notation_${NOTATION_VERSION}_linux_amd64.tar.gz"
  curl --noproxy '*' -fSL "$base/$archive" -o "$STATE/$archive"
  curl --noproxy '*' -fSL "$base/notation_${NOTATION_VERSION}_checksums.txt" -o "$STATE/notation-checksums.txt"
  (cd "$STATE"; grep " $archive\$" notation-checksums.txt | sha256sum -c -)
  echo "$NOTATION_SHA256  $STATE/$archive" | sha256sum -c -
  tar -xzf "$STATE/$archive" -C "$STATE/bin" notation
fi
notation version | tee "$STATE/evidence/notation-version.txt"
notation version | grep -Fq "Version:     $NOTATION_VERSION" || fail "Unexpected Notation version"
curl --noproxy '*' -fSL \
  "https://notaryproject.github.io/ratify/ratify-$RATIFY_CHART_VERSION.tgz" \
  -o "$STATE/ratify.tgz"
echo "$RATIFY_CHART_SHA256  $STATE/ratify.tgz" | sha256sum -c -
helm pull gatekeeper --repo https://open-policy-agent.github.io/gatekeeper/charts \
  --version "$GATEKEEPER_CHART_VERSION" --destination "$STATE"
echo "$GATEKEEPER_CHART_SHA256  $STATE/gatekeeper-$GATEKEEPER_CHART_VERSION.tgz" | sha256sum -c -
for image in "$NODE_IMAGE" "$ZOT_IMAGE" "$APP_IMAGE" "$SKOPEO_IMAGE" \
  "$HTPASSWD_IMAGE" "$PROBE_IMAGE" "$ROUTER_IMAGE"; do
  ensure_image "$image"
done
docker image inspect "$APP_IMAGE" --format '{{json .RepoDigests}}' >"$STATE/evidence/app-source-digest.json"
docker build --network=none --pull=false --build-arg "APP_IMAGE=$APP_IMAGE" \
  -f "$ROOT/config/Dockerfile.tampered" -t offline-ratify-httpbin:modified "$ROOT/config"
docker build --network=none --pull=false --build-arg "APP_IMAGE=$APP_IMAGE" \
  -f "$ROOT/config/Dockerfile.unsigned" -t offline-ratify-httpbin:unsigned "$ROOT/config"
docker save "$APP_IMAGE" -o "$STATE/original.tar"
docker save offline-ratify-httpbin:modified -o "$STATE/modified.tar"
docker save offline-ratify-httpbin:unsigned -o "$STATE/unsigned.tar"

phase '2: CONNECTED - local zot, three tags, Notation trust bundle'
docker network create --internal --subnet 172.30.87.0/24 "$INTERNAL" >/dev/null
docker network create --subnet 172.30.88.0/24 "$UPLINK" >/dev/null
openssl rand -hex 24 >"$STATE/registry-password"
PASSWORD="$(cat "$STATE/registry-password")"
printf '%s\n' "$PASSWORD" | docker run --rm -i --network none "$HTPASSWD_IMAGE" \
  htpasswd -niB presenter >"$STATE/htpasswd"
AUTH="$(printf 'presenter:%s' "$PASSWORD" | base64 -w0)"
jq -n --arg endpoint "$ENDPOINT" --arg auth "$AUTH" \
  '{auths:{($endpoint):{auth:$auth}}}' >"$STATE/docker/config.json"
docker run -d --name "$REGISTRY" --network "$INTERNAL" --ip 172.30.87.2 \
  -v "$ROOT/config/zot.json:/etc/zot/config.json:ro" \
  -v "$STATE/htpasswd:/auth/htpasswd:ro" \
  "$ZOT_IMAGE" serve /etc/zot/config.json >/dev/null
# shellcheck disable=SC2016
timeout 45 bash -c 'until curl --noproxy "*" -fsS -u "presenter:$1" "http://$2/v2/" >/dev/null; do sleep 1; done' \
  _ "$PASSWORD" "$ENDPOINT"
for tag in signed tampered; do registry_copy original "$tag"; done
registry_copy unsigned unsigned

# Only these generated, demo-owned paths are replaced on a fresh run.
rm -f "$STATE/xdg/notation/localkeys/offline-demo.crt" \
  "$STATE/xdg/notation/localkeys/offline-demo.key" \
  "$STATE/xdg/notation/signingkeys.json" \
  "$STATE/xdg/notation/truststore/x509/ca/offline-demo/offline-demo.crt"
notation cert generate-test --default offline-demo
cp "$STATE/xdg/notation/localkeys/offline-demo.crt" "$BUNDLE/truststore/x509/ca/offline-demo/root.crt"
cp "$ROOT/config/trustPolicy.json" "$BUNDLE/trustPolicy.json"
jq '{notation:{trustPolicies:[.trustPolicies[] |
  {name,level:.signatureVerification.level,registryScopes,trustedIdentities,trustStores:[]}]}}' \
  "$BUNDLE/trustPolicy.json" >"$STATE/trust-values.json"
notation policy import --force "$BUNDLE/trustPolicy.json"
printf '%s' "$PASSWORD" | notation login --insecure-registry --username presenter --password-stdin "$ENDPOINT"
notation sign --insecure-registry "$REPOSITORY:signed"
notation verify --insecure-registry "$REPOSITORY:signed"
notation verify --insecure-registry "$REPOSITORY:tampered"
registry_copy modified tampered
for tag in signed unsigned tampered; do
  curl --noproxy '*' -fsS -u "presenter:$PASSWORD" \
    -H 'Accept: application/vnd.oci.image.manifest.v1+json, application/vnd.docker.distribution.manifest.v2+json' \
    "http://$ENDPOINT/v2/demo/httpbin/manifests/$tag" >"$STATE/evidence/$tag-manifest.json"
  sha256sum "$STATE/evidence/$tag-manifest.json"
done
SIGNED_DIGEST="sha256:$(sha256sum "$STATE/evidence/signed-manifest.json" | cut -d' ' -f1)"
UNSIGNED_DIGEST="sha256:$(sha256sum "$STATE/evidence/unsigned-manifest.json" | cut -d' ' -f1)"
TAMPERED_DIGEST="sha256:$(sha256sum "$STATE/evidence/tampered-manifest.json" | cut -d' ' -f1)"
[[ $SIGNED_DIGEST != "$UNSIGNED_DIGEST" && $SIGNED_DIGEST != "$TAMPERED_DIGEST" ]] \
  || fail "Negative controls must have distinct manifest digests"
jq -n --arg signed "$SIGNED_DIGEST" --arg unsigned "$UNSIGNED_DIGEST" --arg tampered "$TAMPERED_DIGEST" \
  '{signed:$signed,unsigned:$unsigned,tampered:$tampered}' >"$STATE/evidence/digests.json"
diff <(jq '.layers' "$STATE/evidence/signed-manifest.json") \
  <(jq '.layers' "$STATE/evidence/unsigned-manifest.json")
[[ $(jq '.layers | length' "$STATE/evidence/tampered-manifest.json") \
   -eq $(($(jq '.layers | length' "$STATE/evidence/signed-manifest.json") + 1)) ]] \
  || fail "Tamper build must add exactly one filesystem layer"

phase '3: CONNECTED - install policy-enforcing cluster and Ratify'
export KIND_EXPERIMENTAL_DOCKER_NETWORK="$UPLINK"
kind create cluster --name "$CLUSTER" --image "$NODE_IMAGE" \
  --config "$ROOT/config/kind.yaml" --wait 120s
docker network connect "$INTERNAL" "$NODE"
docker exec "$NODE" mkdir -p "/etc/containerd/certs.d/$ENDPOINT"
printf 'server = "http://%s"\n[host."http://%s"]\n  capabilities = ["pull", "resolve"]\n' \
  "$ENDPOINT" "$ENDPOINT" | docker exec -i "$NODE" tee "/etc/containerd/certs.d/$ENDPOINT/hosts.toml" >/dev/null
kind load docker-image --name "$CLUSTER" "$PROBE_IMAGE" "$ROUTER_IMAGE"
k apply -f - <"$ROOT/manifests/kube-router.yaml"
k -n kube-system rollout status daemonset/offline-network-policy --timeout=120s
for namespace in gatekeeper-system offline-demo diagnostics; do
  k create namespace "$namespace"
done
for namespace in gatekeeper-system offline-demo; do
  jq -n --arg namespace "$namespace" --rawfile config "$STATE/docker/config.json" \
    '{apiVersion:"v1",kind:"Secret",metadata:{name:"registry-credentials",namespace:$namespace},
      type:"kubernetes.io/dockerconfigjson",data:{".dockerconfigjson":($config|@base64)}}' | k apply -f -
done

helm template gatekeeper "$STATE/gatekeeper-$GATEKEEPER_CHART_VERSION.tgz" --skip-tests \
  -n gatekeeper-system -f "$ROOT/config/gatekeeper-values.yaml" >"$STATE/gatekeeper-rendered.yaml"
helm template ratify "$STATE/ratify.tgz" --skip-tests -n gatekeeper-system \
  -f "$ROOT/config/ratify-values.yaml" \
  -f "$STATE/trust-values.json" \
  --set-file "notationCerts[0]=$BUNDLE/truststore/x509/ca/offline-demo/root.crt" >"$STATE/ratify-rendered.yaml"
mapfile -t policy_images < <(sed -nE 's/^[[:space:]]*image: ([^ ]+)[[:space:]]*$/\1/p' \
  "$STATE/gatekeeper-rendered.yaml" "$STATE/ratify-rendered.yaml" | tr -d "\"'" | sort -u)
[[ ${#policy_images[@]} -gt 0 ]] || fail "No policy images discovered in pinned charts"
printf '%s\n' "${policy_images[@]}" >"$STATE/evidence/policy-images.txt"
for image in "${policy_images[@]}"; do
  [[ ${image##*/} == *:* && $image != *:latest ]] || fail "Unpinned policy image: $image"
  ensure_image "$image"
done
kind load docker-image --name "$CLUSTER" "${policy_images[@]}"
helm install gatekeeper "$STATE/gatekeeper-$GATEKEEPER_CHART_VERSION.tgz" \
  -n gatekeeper-system -f "$ROOT/config/gatekeeper-values.yaml" --wait --timeout 5m
helm install ratify "$STATE/ratify.tgz" -n gatekeeper-system \
  -f "$ROOT/config/ratify-values.yaml" \
  -f "$STATE/trust-values.json" \
  --set-file "notationCerts[0]=$BUNDLE/truststore/x509/ca/offline-demo/root.crt" --wait --timeout 5m
k -n gatekeeper-system patch serviceaccount ratify-admin \
  -p '{"imagePullSecrets":[{"name":"registry-credentials"}]}'
k get verifier verifier-notation -o json | jq '.spec.parameters.trustPolicyDoc' \
  >"$STATE/evidence/deployed-trustPolicy.json"
diff <(jq -S '.trustPolicies[].trustStores=["ca:certs"]' "$BUNDLE/trustPolicy.json") \
  <(jq -S . "$STATE/evidence/deployed-trustPolicy.json")
k apply -f - <"$ROOT/manifests/admission.yaml"
k wait --for=create crd/offlinesignature.constraints.gatekeeper.sh --timeout=60s
k wait --for=condition=Established crd/offlinesignature.constraints.gatekeeper.sh --timeout=60s
k apply -f - <"$ROOT/manifests/constraint.yaml"
k -n diagnostics run egress-probe --image="$PROBE_IMAGE" --image-pull-policy=Never \
  --restart=Never --command -- sleep 86400
k -n diagnostics wait --for=condition=Ready pod/egress-probe --timeout=90s
probe https://1.1.1.1/cdn-cgi/trace >"$STATE/evidence/pod-connected.txt"
probe https://example.com >"$STATE/evidence/pod-connected-dns.txt"
docker exec "$NODE" curl --noproxy '*' -fsS --max-time 10 https://1.1.1.1/cdn-cgi/trace \
  >"$STATE/evidence/node-connected.txt"

phase '4: CONNECTED - prove NetworkPolicy enforcement before sealing the node'
for namespace in $(k get namespaces -o jsonpath='{.items[*].metadata.name}'); do
  k -n "$namespace" apply -f - <"$ROOT/manifests/network-policy.yaml"
done
sleep 10
expect_blocked pod-policy-external probe https://1.1.1.1/cdn-cgi/trace
docker exec "$NODE" curl --noproxy '*' -fsS --max-time 10 https://1.1.1.1/cdn-cgi/trace \
  >"$STATE/evidence/node-still-connected.txt"
probe "http://$ENDPOINT/v2/" -u "presenter:$PASSWORD" >/dev/null

# Seal both node-originated and forwarded traffic before declaring AIR-GAPPED.
NODE_IP="$(docker inspect "$NODE" --format "{{(index .NetworkSettings.Networks \"$UPLINK\").IPAddress}}")"
docker exec -i "$NODE" bash -s -- "$NODE_IP" <<'FIREWALL'
set -euo pipefail
iptables -N OFFLINE_EGRESS
iptables -A OFFLINE_EGRESS -d 127.0.0.11/32 -j REJECT
iptables -A OFFLINE_EGRESS -d 127.0.0.0/8 -j RETURN
for cidr in 10.244.0.0/16 10.96.0.0/16 172.30.87.2/32 "$1/32"; do
  iptables -A OFFLINE_EGRESS -d "$cidr" -j RETURN
done
iptables -A OFFLINE_EGRESS -j REJECT
iptables -I OUTPUT 1 -j OFFLINE_EGRESS
iptables -I FORWARD 1 -j OFFLINE_EGRESS
ip6tables -I OUTPUT 1 -o lo -j ACCEPT
ip6tables -P OUTPUT DROP
ip6tables -P FORWARD DROP
ip route add 10.96.0.0/16 dev lo
ip route del default
FIREWALL
phase '5: AIR-GAPPED - node firewall sealed, no default route, local trust only'
docker network inspect "$INTERNAL" >"$STATE/evidence/internal-network.json"
[[ $(docker network inspect "$INTERNAL" --format '{{.Internal}}') == true ]] || fail "Not an internal network"
docker inspect "$NODE" "$REGISTRY" >"$STATE/evidence/container-networks.json"
networks="$(docker inspect "$REGISTRY" --format '{{json .NetworkSettings.Networks}}')"
jq -e --arg internal "$INTERNAL" 'keys == [$internal]' <<<"$networks" >/dev/null \
  || fail "Registry still has an unexpected network"
docker exec "$NODE" ip route >"$STATE/evidence/node-routes.txt"
if grep -q '^default' "$STATE/evidence/node-routes.txt"; then fail "Node still has a default route"; fi
expect_blocked node-offline-external docker exec "$NODE" curl --noproxy '*' -fsS \
  --connect-timeout 2 --max-time 5 https://1.1.1.1/cdn-cgi/trace
expect_blocked pod-offline-external probe https://1.1.1.1/cdn-cgi/trace
expect_dns_blocked node-offline-public-dns docker exec "$NODE" curl --noproxy '*' -fsS \
  --connect-timeout 2 --max-time 5 https://example.com
expect_dns_blocked pod-offline-public-dns probe https://example.com
probe "http://$ENDPOINT/v2/" -u "presenter:$PASSWORD" >"$STATE/evidence/registry-offline.txt"
# Probe the verifier's real network namespace without modifying its image.
RATIFY_POD="$(k -n gatekeeper-system get pods -l app.kubernetes.io/name=ratify -o jsonpath='{.items[0].metadata.name}')"
RATIFY_ID="$(k -n gatekeeper-system get pod "$RATIFY_POD" -o jsonpath='{.status.containerStatuses[0].containerID}')"
RATIFY_PID="$(docker exec "$NODE" crictl inspect "${RATIFY_ID#containerd://}" | jq -r '.info.pid')"
expect_blocked ratify-offline-external docker exec "$NODE" nsenter -t "$RATIFY_PID" -n \
  curl --noproxy '*' -fsS --connect-timeout 2 --max-time 5 https://1.1.1.1/cdn-cgi/trace
docker exec "$NODE" iptables-save >"$STATE/evidence/iptables.txt"

phase '6: AIR-GAPPED - signed allowed, unsigned and overwritten tag denied'
pod httpbin-signed signed
k -n offline-demo wait --for=condition=Ready pod/httpbin-signed --timeout=120s
ACTUAL_IMAGE="$(k -n offline-demo get pod httpbin-signed -o jsonpath='{.spec.containers[0].image}')"
[[ $ACTUAL_IMAGE == *"@$SIGNED_DIGEST" ]] || fail "Admission did not pin the verified digest: $ACTUAL_IMAGE"
k -n offline-demo get pod httpbin-signed -o json >"$STATE/evidence/signed-pod.json"
APP_IP="$(k -n offline-demo get pod httpbin-signed -o jsonpath='{.status.podIP}')"
probe "http://$APP_IP:8080/get?demo=offline" | tee "$STATE/evidence/httpbin-response.json"
jq -e '.args.demo == ["offline"]' "$STATE/evidence/httpbin-response.json" >/dev/null
for tag in unsigned tampered; do
  rc=0
  pod "httpbin-$tag" "$tag" >"$STATE/evidence/$tag-denial.txt" 2>&1 || rc=$?
  cat "$STATE/evidence/$tag-denial.txt"
  (( rc != 0 )) || fail "$tag was unexpectedly admitted"
  grep -F 'admission webhook "validation.gatekeeper.sh" denied' "$STATE/evidence/$tag-denial.txt" >/dev/null \
    || fail "$tag failed for a reason other than validating admission"
  grep -F 'Offline signature required:' "$STATE/evidence/$tag-denial.txt" >/dev/null \
    || fail "$tag did not fail signature verification"
  [[ $(k -n offline-demo get pods "httpbin-$tag" --ignore-not-found -o name) == "" ]] \
    || fail "Rejected Pod exists: $tag"
done
expect_blocked node-offline-final docker exec "$NODE" curl --noproxy '*' -fsS \
  --connect-timeout 2 --max-time 5 https://1.1.1.1/cdn-cgi/trace
expect_blocked pod-offline-final probe https://1.1.1.1/cdn-cgi/trace
k -n gatekeeper-system logs deployment/ratify --tail=200 >"$STATE/evidence/ratify.log"
k -n offline-demo get events -o yaml >"$STATE/evidence/events.yaml"
docker logs "$REGISTRY" >"$STATE/evidence/zot.log" 2>&1
{
  echo "PASS: signed allowed and digest-pinned; unsigned denied; tampered denied."
  echo "PASS: go-httpbin /get served locally; pod, verifier and node external access blocked."
  echo "Runtime: $((SECONDS-START)) seconds"
  echo "Completed: $(date -u +%FT%TZ)"
  docker version --format 'Docker client={{.Client.Version}} server={{.Server.Version}}'
  kind version
  helm version --short
  k version -o json | jq -r '"Kubernetes " + .serverVersion.gitVersion'
} | tee "$STATE/evidence/result.txt"
echo "Evidence: $STATE/evidence"
echo "Trust-only export: $BUNDLE (no signing private key)"
echo "Cluster remains isolated. Cleanup: $ROOT/scripts/cleanup.sh"
