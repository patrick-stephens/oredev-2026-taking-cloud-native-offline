#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=common.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
export DEMO_DB_PASSWORD="${DEMO_DB_PASSWORD:-cleanup-only}"
dc down --volumes --remove-orphans
if [[ -s "$ROOT/.state/harbor.compose.json" ]]; then
    hc down --volumes --remove-orphans
fi
if docker network inspect "$NETWORK" >/dev/null 2>&1; then
    docker network rm "$NETWORK"
fi
if [[ "${1:-}" == "--reset" && -d "$ROOT/.state" ]]; then
    docker run --rm --pull never --network none \
        -v "$ROOT/.state:/state" --entrypoint /bin/sh "$SKOPEO_IMAGE" -ec '
        rm -rf /state/harbor /state/harbor-data /state/pulls /state/log /state/gateway
        rm -f /state/runtime.env /state/curl.conf /state/auth.json /state/manager.yaml /state/peer.yaml \
          /state/seed.yaml /state/harbor.compose.json /state/health.out /state/health.err \
          /state/egress.out /state/egress.err
        '
fi
echo "Demo containers and network removed. Evidence in $ROOT/artifacts is retained."
