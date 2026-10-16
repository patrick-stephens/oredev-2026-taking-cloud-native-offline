#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"

if [[ "${1:-}" == --k0s ]]; then
  shift
  exec "$ROOT/scripts/run-k0s.sh" "$@"
fi

started="$(date +%s)"
mkdir -p "$STATE"
chmod 700 "$STATE"
umask 077
on_exit() {
  local rc=$?
  trap - EXIT
  if (( rc != 0 )); then
    echo "FAILED (exit $rc). No success claimed. Retaining the node for diagnosis." >&2
    if [[ "$(docker inspect "$NODE" \
      --format '{{index .Config.Labels "io.taking-offline.demo"}}' 2>/dev/null)" == k3s-airgap ]]; then
      docker logs --tail 120 "$NODE" > "$STATE/node-failure.log" 2>&1
      echo "Node log: $STATE/node-failure.log" >&2
    fi
  fi
  echo "Total runtime: $(( $(date +%s) - started )) seconds (exit $rc)"
  exit "$rc"
}
trap on_exit EXIT

case "${1:-}" in
  '') phase '1: CONNECTED - acquire, verify and render'; "$ROOT/scripts/prepare.sh" ;;
  --prepare-only)
    phase '1: CONNECTED - acquire, verify and render'
    "$ROOT/scripts/prepare.sh"
    exit 0
    ;;
  --offline) check_host ;;
  *) die 'Usage: run-demo.sh [--k0s] [--prepare-only|--offline]' ;;
esac
require clear
rm -f -- "$STATE/node-failure.log"

phase '2: AIR-GAPPED - verify bundle and create a node that has never been online'
[[ -f "$ARTIFACTS/SHA256SUMS" ]] || die 'Run --prepare-only on the connected side first.'
(cd "$ARTIFACTS" && sha256sum -c SHA256SUMS)
grep -Fx "k3s=$K3S_VERSION" "$ARTIFACTS/versions.txt"
grep -Fx "workload=$WHOAMI_IMAGE" "$ARTIFACTS/versions.txt"
docker load -i "$ARTIFACTS/k3s-node.tar"
remove_runtime
docker network create --internal --ipv6=false --label "$LABEL" "$NETWORK"
# An internal bridge has no default route; give k3s an explicit node address.
node_ip="$(docker network inspect "$NETWORK" |
  jq -er '.[0].IPAM.Config[0].Gateway | split(".") |
    .[3] = ((.[3] | tonumber) + 1 | tostring) | join(".")')"
docker create --name "$NODE" --hostname offline-k3s \
  --label "$LABEL" --privileged --cgroupns=host --pull never \
  --network "$NETWORK" --ip "$node_ip" --dns 127.0.0.1 \
  --env HTTP_PROXY= --env HTTPS_PROXY= --env ALL_PROXY= \
  --env http_proxy= --env https_proxy= --env all_proxy= \
  --tmpfs /run --tmpfs /var/run \
  --volume /sys/fs/cgroup:/sys/fs/cgroup:rw \
  --mount "type=bind,src=$ROOT/config/resolv.conf,dst=/etc/resolv.conf,readonly" \
  --mount "type=bind,src=$ROOT/config/pod-resolv.conf,dst=/etc/offline-pod-resolv.conf,readonly" \
  --entrypoint /bin/k3s "$K3S_IMAGE" server \
  --node-ip "$node_ip" --advertise-address "$node_ip" --flannel-iface eth0 \
  --disable traefik --disable servicelb --disable metrics-server \
  --resolv-conf /etc/offline-pod-resolv.conf --write-kubeconfig-mode 600 \
  --kubelet-arg 'eviction-hard=nodefs.available<1Gi,imagefs.available<1Gi,nodefs.inodesFree<1%' \
  --kubelet-arg image-gc-high-threshold=99 --kubelet-arg image-gc-low-threshold=98
docker cp "$ARTIFACTS/k3s" "$NODE:/bin/k3s"
# Docker cp creates the last path component, not missing parents.
docker cp "$ROOT/config/seed/." "$NODE:/"
docker cp "$ARTIFACTS/k3s-airgap-images-amd64.tar.zst" \
  "$NODE:/var/lib/rancher/k3s/agent/images/"
docker cp "$ARTIFACTS/whoami.tar" "$NODE:/var/lib/rancher/k3s/agent/images/"
docker cp "$ARTIFACTS/whoami.yaml" "$NODE:/var/lib/rancher/k3s/server/manifests/whoami.yaml"
assert_isolated
docker start "$NODE"

phase '3: AIR-GAPPED - wait for auto-import, node Ready and manifest auto-deploy'
deadline=$((SECONDS + 300))
until k get nodes -o json > "$STATE/nodes.json" 2>"$STATE/api-wait.log" &&
  jq -e '.items | length == 1' "$STATE/nodes.json" >/dev/null; do
  [[ "$(docker inspect "$NODE" --format '{{.State.Running}}')" == true ]] ||
    die 'Node exited: check privileged/cgroup support and node-failure.log.'
  (( SECONDS < deadline )) || die 'API did not become ready in 300 seconds.'
  sleep 3
done
k wait --for=condition=Ready node --all --timeout=180s
k get nodes -o wide
k -n kube-system rollout status deployment/coredns --timeout=180s
k -n kube-system rollout status deployment/local-path-provisioner --timeout=180s
docker exec "$NODE" /bin/k3s --version
images | tee "$STATE/images.txt"
grep -F "$WHOAMI_IMAGE" "$STATE/images.txt" >/dev/null ||
  die 'whoami was not auto-imported.'
grep -F 'rancher/mirrored-pause:' "$STATE/images.txt" >/dev/null ||
  die 'Official air-gap pause image was not auto-imported.'
if grep -F "$MISSING_IMAGE" "$STATE/images.txt" >/dev/null; then
  die 'Negative-test image is unexpectedly seeded.'
fi
deadline=$((SECONDS + 120))
until k -n offline-demo get deployment whoami >/dev/null 2>&1; do
  (( SECONDS < deadline )) || die 'Embedded manifests directory did not create the deployment.'
  sleep 2
done
k -n offline-demo rollout status deployment/whoami --timeout=180s
k -n offline-demo get pods -o wide
k -n kube-system get addons whoami
[[ "$(k -n offline-demo get deployment whoami \
  -o jsonpath='{.spec.template.spec.containers[0].imagePullPolicy}')" == Never ]] ||
  die 'Workload must use imagePullPolicy Never.'
pod_ip="$(k -n offline-demo get pod -l app=whoami -o jsonpath='{.items[0].status.podIP}')"
docker exec "$NODE" /bin/busybox wget -T 10 -qO - "http://$pod_ip/" |
  tee "$STATE/whoami-response.txt"
grep -F 'Hostname:' "$STATE/whoami-response.txt" >/dev/null ||
  die 'whoami did not return its hostname.'

phase '4: AIR-GAPPED - prove external IP, DNS and an unseeded image cannot work'
verify_offline_network
echo 'PASS: Ready node, auto-imported images, auto-deployed whoami, blocked IP/DNS and failed unseeded pull.'
echo "Evidence: $STATE"
echo 'Node retained. Run scripts/cleanup.sh when finished.'
