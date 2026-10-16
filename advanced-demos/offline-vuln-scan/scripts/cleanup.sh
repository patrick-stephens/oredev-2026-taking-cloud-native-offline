#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC1091
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"

purge=0
if [[ "${1:-}" == "--purge" ]]; then
    purge=1
elif [[ $# -gt 0 ]]; then
    printf 'Usage: %s [--purge]\n' "$0" >&2
    exit 2
fi

require_docker

if managed_container_exists "$DEMO_REGISTRY"; then
    docker rm --force "$DEMO_REGISTRY" >/dev/null
fi

if docker network inspect "$DEMO_NETWORK" >/dev/null 2>&1; then
    label="$(docker network inspect --format '{{ index .Labels "org.oredev.demo" }}' "$DEMO_NETWORK")"
    [[ "$label" == "offline-vuln-scan" ]] ||
        fail "Network '$DEMO_NETWORK' exists but is not labelled for this demo; refusing to remove it."
    docker network rm "$DEMO_NETWORK" >/dev/null
fi

if [[ "$purge" == "1" ]]; then
    if [[ -d "$DEMO_DIR/.state/registry-data" ]]; then
        docker run --rm --user 0:0 \
            -v "$DEMO_DIR/.state/registry-data:/registry-data" \
            "$DEMO_RUNTIME_IMAGE" \
            chown -R "$(id -u):$(id -g)" /registry-data
    fi
    rm -rf -- "$DEMO_DIR/.bundle" "$DEMO_DIR/.work" "$DEMO_DIR/.state" \
        "$DEMO_DIR/.tools" "$DEMO_DIR/artifacts"
    printf "Removed this demo's generated bundle, registry state, staging area and archive.\n"
else
    printf "Stopped and removed this demo's registry and internal network. Bundle and archive retained.\n"
    printf 'Use %s --purge to remove generated files as well.\n' "$0"
fi
