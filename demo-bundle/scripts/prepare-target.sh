#!/usr/bin/env bash
# Provision infrastructure BEFORE declaring the target offline:
# ./scripts/prepare-target.sh
# kind create cluster --name offline-bundle-demo --image kindest/node:v1.35.0
# Isolation changes only the disposable node's network namespace:
# docker exec offline-bundle-demo-control-plane ip -4 route del default
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
banner "2 / TARGET: provision Kubernetes, then cut its internet route"
require_tools
for image in "$NODE_IMAGE" "$ZOT" "$SKOPEO" "$COSIGN"; do ensure_image "$image"; done

if ! docker network inspect "$NETWORK" >/dev/null 2>&1; then
    docker network create --label offline-bundle-demo=true "$NETWORK" >/dev/null
fi
[[ "$(docker network inspect "$NETWORK" --format '{{index .Labels "offline-bundle-demo"}}')" == true ]] ||
    die "Refusing to reuse an unowned network named $NETWORK."
if ! kind get clusters | grep -Fxq "$CLUSTER"; then
    KIND_EXPERIMENTAL_DOCKER_NETWORK="$NETWORK" timeout 120s kind create cluster \
        --name "$CLUSTER" --image "$NODE_IMAGE" --config "$DEMO_DIR/kind.yaml" \
        --kubeconfig "$STATE/kubeconfig" --wait 60s
    docker inspect --format '{{.Id}}' "$NODE" > "$STATE/node-id"
fi
assert_target_owned
docker cp "$(realpath "$(command -v helm)")" "$NODE:/usr/local/bin/offline-demo-helm"
docker exec "$NODE" sh -ec 'if [ -n "$(ip -4 route show default)" ]; then ip -4 route del default; fi'
assert_offline
printf 'OFFLINE: target has no IPv4/IPv6 default route; host networking is unchanged.\n'
kube get nodes
printf 'Infrastructure is pre-staged; all following supply-chain steps are offline.\n'
