#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/common.sh"
[[ $# == 0 ]] || fail "Usage: $0 (keeps local evidence, bundle, keys and downloads)"
if docker container inspect "$NODE" >/dev/null 2>&1; then
  kind delete cluster --name "$CLUSTER"
fi
if docker container inspect "$REGISTRY" >/dev/null 2>&1; then
  docker rm -f "$REGISTRY" >/dev/null
fi
for network in "$UPLINK" "$INTERNAL"; do
  if docker network inspect "$network" >/dev/null 2>&1; then
    docker network rm "$network" >/dev/null
  fi
done
echo "Removed only this demo's cluster, registry and networks."
echo "Retained $ROOT/.state (private demo state) and $ROOT/bundle (public trust exports) for all profiles; ignored by Git."
