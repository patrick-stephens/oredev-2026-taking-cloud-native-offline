#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../config/versions.env
source "$ROOT/config/versions.env"
TOOLS="$ROOT/.tools"

if [[ -x "$TOOLS/k3d" ]]; then
    "$TOOLS/k3d" cluster delete "$CLUSTER_NAME" >/dev/null 2>&1 || true
fi

if docker container inspect "$ZOT_CONTAINER" >/dev/null 2>&1; then
    docker rm --force "$ZOT_CONTAINER" >/dev/null
fi

if docker network inspect "$DOCKER_NETWORK" >/dev/null 2>&1; then
    if [[ "$(docker network inspect "$DOCKER_NETWORK" --format '{{.Labels.demo}}')" == apko-melange-offline ]]; then
        docker network rm "$DOCKER_NETWORK" >/dev/null
    else
        echo "Refusing to remove unowned Docker network $DOCKER_NETWORK." >&2
        exit 1
    fi
fi

rm -rf -- "$ROOT/.state" "$ROOT/.work" "$ROOT/artifacts"
printf 'Removed this demo cluster, zot container, generated signing key and artifacts.\n'
printf 'Pinned tool binaries and pulled Docker images were left in place.\n'
