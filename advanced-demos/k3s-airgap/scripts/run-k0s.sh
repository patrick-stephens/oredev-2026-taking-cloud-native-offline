#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/k0s-common.sh"

started="$(date +%s)"
mkdir -p "$STATE"
chmod 700 "$STATE"
umask 077
on_exit() {
  local rc=$?
  trap - EXIT
  if (( rc != 0 )); then
    echo "FAILED k0s (exit $rc). Node retained; no success claimed." >&2
    if [[ "$(docker inspect "$NODE" \
      --format '{{index .Config.Labels "io.taking-offline.demo"}}' 2>/dev/null)" == k3s-airgap ]]; then
      docker logs --tail 150 "$NODE" > "$STATE/node-failure.log" 2>&1
      echo "Node log: $STATE/node-failure.log" >&2
    fi
  fi
  echo "Total k0s runtime: $(( $(date +%s) - started )) seconds (exit $rc)"
  exit "$rc"
}
trap on_exit EXIT
case "${1:-}" in
  '') phase '1: CONNECTED - acquire k0s, official bundle and rendered whoami'
      "$ROOT/scripts/prepare-k0s.sh" ;;
  --prepare-only)
    phase '1: CONNECTED - acquire k0s, official bundle and rendered whoami'
    "$ROOT/scripts/prepare-k0s.sh"
    exit 0 ;;
  --offline) check_host ;;
  *) die 'Usage: run-demo.sh --k0s [--prepare-only|--offline]' ;;
esac
require clear sed
rm -f -- "$STATE/node-failure.log"

phase '2: AIR-GAPPED - create an isolated k0s controller-worker before first boot'
[[ -f "$ARTIFACTS/SHA256SUMS" ]] || die 'Prepare the k0s bundle while connected first.'
(cd "$ARTIFACTS" && sha256sum -c SHA256SUMS)
grep -Fx "k0s=$K0S_VERSION" "$ARTIFACTS/versions.txt"
grep -Fx "workload=$WHOAMI_IMAGE" "$ARTIFACTS/versions.txt"
docker load -i "$ARTIFACTS/node.tar"
remove_runtime
docker network create --internal --ipv6=false --label "$LABEL" "$NETWORK"
node_ip="$(docker network inspect "$NETWORK" |
  jq -er '.[0].IPAM.Config[0].Gateway | split(".") |
    .[3] = ((.[3] | tonumber) + 1 | tostring) | join(".")')"
sed "s/NODE_IP/$node_ip/" "$ROOT/config/k0s.yaml" > "$STATE/k0s.yaml"
docker create --name "$NODE" --hostname offline-k0s --label "$LABEL" \
  --privileged --cgroupns=host --pull never \
  --network "$NETWORK" --ip "$node_ip" --dns 127.0.0.1 \
  --env HTTP_PROXY= --env HTTPS_PROXY= --env ALL_PROXY= \
  --env http_proxy= --env https_proxy= --env all_proxy= \
  --env K0S_ENTRYPOINT_ENABLE_CGROUPV2_NESTING=0 \
  --env K0S_ENTRYPOINT_DNS_FIXUP=0 \
  --tmpfs /run --tmpfs /var/run \
  --volume /sys/fs/cgroup:/sys/fs/cgroup:rw \
  --volume /var/lib/k0s --volume /var/log/pods \
  --mount "type=bind,src=$STATE/k0s.yaml,dst=/etc/k0s/k0s.yaml,readonly" \
  --mount "type=bind,src=$ROOT/config/resolv.conf,dst=/etc/resolv.conf,readonly" \
  --mount "type=bind,src=$ROOT/config/pod-resolv.conf,dst=/etc/offline-pod-resolv.conf,readonly" \
  --mount "type=bind,src=$ROOT/scripts/k0s-entrypoint.sh,dst=/offline-entrypoint.sh,readonly" \
  --entrypoint /offline-entrypoint.sh \
  "$K0S_IMAGE" k0s controller --single --profile offline \
  --disable-components metrics-server,update-prober \
  --kubelet-extra-args="--node-ip=$node_ip"
docker cp "$ARTIFACTS/$BINARY" "$NODE:/usr/local/bin/k0s"
docker cp "$ROOT/config/k0s-seed/." "$NODE:/var/lib/k0s/"
docker cp "$ARTIFACTS/$BUNDLE" "$NODE:/var/lib/k0s/images/platform.tar"
docker cp "$ARTIFACTS/workloads.tar" "$NODE:/var/lib/k0s/images/workloads.tar"
docker cp "$ARTIFACTS/whoami.yaml" "$NODE:/var/lib/k0s/manifests/whoami/whoami.yaml"
assert_isolated
docker start "$NODE"

phase '3: AIR-GAPPED - k0s auto-imports images and reconciles the manifest stack'
deadline=$((SECONDS + 300))
until k get nodes -o json > "$STATE/nodes.json" 2>"$STATE/api-wait.log" &&
  jq -e '.items | length == 1' "$STATE/nodes.json" >/dev/null; do
  [[ "$(docker inspect "$NODE" --format '{{.State.Running}}')" == true ]] ||
    die 'k0s node exited; inspect node-failure.log.'
  (( SECONDS < deadline )) || die 'k0s API/node did not appear in 300 seconds.'
  sleep 3
done
k wait --for=condition=Ready node --all --timeout=180s
k get nodes -o wide
k -n kube-system rollout status deployment/coredns --timeout=180s
k -n kube-system rollout status daemonset/kube-router --timeout=180s
k -n kube-system rollout status daemonset/kube-proxy --timeout=180s
docker exec "$NODE" k0s version
images | tee "$STATE/images.txt"
for image in "$WHOAMI_IMAGE" "$PROBE_IMAGE" 'quay.io/k0sproject/pause:'; do
  grep -F "$image" "$STATE/images.txt" >/dev/null || die "Auto-import missing: $image"
done
if grep -F "$MISSING_IMAGE" "$STATE/images.txt" >/dev/null; then
  die 'Negative-test image is unexpectedly seeded.'
fi
deadline=$((SECONDS + 120))
until k -n offline-demo get deployment whoami >/dev/null 2>&1; do
  (( SECONDS < deadline )) || die 'k0s manifest deployer did not create whoami.'
  sleep 2
done
k -n offline-demo rollout status deployment/whoami --timeout=180s
k -n offline-demo get pods -o wide
k -n offline-demo get deployment whoami --show-managed-fields -o json \
  > "$STATE/whoami-deployment.json"
jq -e '.metadata.managedFields | any(.manager == "k0s")' \
  "$STATE/whoami-deployment.json" >/dev/null ||
  die 'whoami was not reconciled by the k0s manifest deployer.'
[[ "$(k -n offline-demo get deployment whoami \
  -o jsonpath='{.spec.template.spec.containers[0].imagePullPolicy}')" == Never ]] ||
  die 'Workload must use imagePullPolicy Never.'
pod_ip="$(k -n offline-demo get pod -l app=whoami -o jsonpath='{.items[0].status.podIP}')"
docker exec "$NODE" /bin/busybox wget -T 10 -qO - "http://$pod_ip/" |
  tee "$STATE/whoami-response.txt"
grep -F 'Hostname:' "$STATE/whoami-response.txt" >/dev/null || die 'No whoami response.'

phase '4: AIR-GAPPED - k0s node/pod egress and unseeded pull negative controls'
docker exec "$NODE" sh -c 'test -z "$(ip -4 route show default)"' ||
  die 'Unexpected default IPv4 route on the k0s node.'
verify_offline_network
echo 'PASS k0s: Ready node, auto-imported images, auto-deployed whoami, blocked IP/DNS and failed unseeded pull.'
echo "Evidence: $STATE"
echo 'Node retained. Run scripts/cleanup.sh when finished.'
