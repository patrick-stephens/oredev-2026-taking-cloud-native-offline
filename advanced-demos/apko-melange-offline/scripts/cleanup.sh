#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../config/versions.env
source "$ROOT/config/versions.env"
TOOLS="$ROOT/.tools"

if [[ -x "$TOOLS/k3d" ]] && "$TOOLS/k3d" cluster list --no-headers |
    awk -v name="$CLUSTER_NAME" '$1 == name { found=1 } END { exit !found }'; then
    node="k3d-${CLUSTER_NAME}-server-0"
    cluster_label="$(docker inspect "$node" \
        --format '{{index .Config.Labels "k3d.cluster"}}' 2>/dev/null || true)"
    if [[ "$cluster_label" != "$CLUSTER_NAME" ]]; then
        printf 'Refusing to remove cluster %s without its expected k3d ownership label.\n' \
            "$CLUSTER_NAME" >&2
        exit 1
    fi
    "$TOOLS/k3d" cluster delete "$CLUSTER_NAME" >/dev/null
fi

if docker container inspect "$ZOT_CONTAINER" >/dev/null 2>&1; then
    if [[ "$(docker container inspect "$ZOT_CONTAINER" --format '{{.Config.Labels.demo}}')" != apko-melange-offline ]]; then
        echo "Refusing to remove unowned container $ZOT_CONTAINER." >&2
        exit 1
    fi
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

if ! rm -rf -- "$ROOT/.state/apko-melange-offline" "$ROOT/artifacts/apko-melange-offline"; then
    echo 'Retrying generated-file cleanup through the local Alpine image.' >&2
    docker run --rm --pull=never --network none \
        --volume "$ROOT/.state:/demo-state" \
        --volume "$ROOT/artifacts:/demo-artifacts" \
        "$ALPINE_IMAGE" sh -ec '
            rm -rf /demo-state/apko-melange-offline
            rm -rf /demo-artifacts/apko-melange-offline
        '
    rm -rf -- "$ROOT/.state/apko-melange-offline" "$ROOT/artifacts/apko-melange-offline"
fi
printf 'Removed this demo cluster, zot container, generated signing key and artifacts.\n'
printf 'Pinned tools, pulled Docker images, and unrelated generated files were left in place.\n'
