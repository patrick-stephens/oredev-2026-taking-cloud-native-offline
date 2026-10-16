#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"

if [[ -x "$TOOLS_DIR/kind" ]]; then
    "$TOOLS_DIR/kind" delete cluster --name "$CLUSTER_NAME" >/dev/null 2>&1 || true
else
    docker rm -f "$CLUSTER_NODE" >/dev/null 2>&1 || true
fi

for container in "$GITEA_CONTAINER" "$REGISTRY_CONTAINER"; do
    if docker container inspect "$container" >/dev/null 2>&1; then
        docker rm -f "$container" >/dev/null
    fi
done

if docker network inspect "$NETWORK_NAME" >/dev/null 2>&1; then
    docker network rm "$NETWORK_NAME" >/dev/null
fi

if docker volume inspect offline-gitops-registry-data >/dev/null 2>&1; then
    docker volume rm offline-gitops-registry-data >/dev/null
fi
if docker volume inspect offline-gitops-gitea-data >/dev/null 2>&1; then
    docker volume rm offline-gitops-gitea-data >/dev/null
fi

rm -rf "$STATE_DIR"
printf 'Removed offline-gitops containers, cluster, network, volumes and local credentials.\n'
printf 'Pinned binaries in .tools/ were retained for a faster rerun.\n'
