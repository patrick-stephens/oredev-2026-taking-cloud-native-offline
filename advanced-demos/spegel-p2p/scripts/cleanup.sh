#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

if [[ -f "$STATE/cluster-owned" && ! -L "$STATE/cluster-owned" ]]; then
    if [[ "$(<"$STATE/cluster-owned")" != "$CLUSTER" ]]; then
        die "Ownership marker does not match $CLUSTER; refusing cleanup."
    fi
    if docker ps -aq --filter "label=k3d.cluster=$CLUSTER" | grep -q .; then
        assert_cluster_owned
        "$TOOLS/k3d" cluster delete "$CLUSTER"
    fi
    rm -f -- "$STATE/cluster-owned"
fi

if docker container inspect "$REGISTRY" >/dev/null 2>&1; then
    label="$(docker inspect --format '{{index .Config.Labels "demo"}}' "$REGISTRY")"
    [[ "$label" == spegel-p2p ]] || die "Refusing to remove unowned container $REGISTRY."
    docker rm --force "$REGISTRY" >/dev/null
fi

if docker network inspect "$NETWORK" >/dev/null 2>&1; then
    label="$(docker network inspect --format '{{index .Labels "demo"}}' "$NETWORK")"
    [[ "$label" == spegel-p2p ]] || die "Refusing to remove unowned network $NETWORK."
    docker network rm "$NETWORK" >/dev/null
fi

if [[ -d "$STATE" && ! -L "$STATE" ]]; then
    rm -f -- "$STATE/spegel-0.8.0.tgz" "$STATE/cluster-owned"
    rmdir --ignore-fail-on-non-empty "$STATE"
fi

printf 'Cleaned up Spegel demo containers, cluster, network and temporary chart.\n'
