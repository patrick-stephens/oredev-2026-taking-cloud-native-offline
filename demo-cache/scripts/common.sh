#!/usr/bin/env bash
set -euo pipefail

DEMO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
COMPOSE=(docker compose --project-name offline-cache-demo --file "$DEMO_DIR/compose.yaml")
# Shared by scripts that source this file.
# shellcheck disable=SC2034
CACHE_IMAGE="docker://localhost:5000/nginx:latest"

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

banner() {
    if [[ -t 1 && ${TERM:-dumb} != dumb ]]; then
        clear
    fi
    printf '\n============================================================\n%s\n============================================================\n' "$1"
}

require_tools() {
    local tool
    for tool in docker curl jq timeout sha256sum cut grep; do
        command -v "$tool" >/dev/null || die "Install the required tool: $tool"
    done
    docker compose version >/dev/null
    docker info >/dev/null
}

registry_id() {
    local id
    id="$("${COMPOSE[@]}" ps --status running --quiet zot)"
    [[ -n "$id" ]] || die "The cache is not running. Run ./scripts/start-cache.sh first."
    printf '%s\n' "$id"
}

uplink_name() {
    local id=$1 name
    name="$(docker network ls \
        --filter label=com.docker.compose.project=offline-cache-demo \
        --filter label=com.docker.compose.network=uplink --format '{{.Name}}')"
    [[ -n "$name" && "$name" != *$'\n'* ]] || die "Expected exactly one demo uplink network."
    # Check the container is inspectable before attempting a network change.
    docker inspect "$id" >/dev/null
    printf '%s\n' "$name"
}

ensure_online() {
    local id=$1 network=$2
    if ! docker inspect "$id" | jq -e --arg network "$network" \
        '.[0].NetworkSettings.Networks | has($network)' >/dev/null; then
        docker network connect "$network" "$id"
    fi
}

skopeo_run() {
    # Bound every operation, including Compose startup, without host-installed skopeo.
    timeout 100s "${COMPOSE[@]}" run --rm --no-deps -T skopeo \
        --command-timeout 90s "$@"
}

cache_ready() {
    curl --noproxy '*' --fail --silent --show-error --max-time 2 \
        http://localhost:5000/v2/ >/dev/null
}

set_registry_mode() {
    local mode=$1 config="$DEMO_DIR/zot-config.json" id network attempt
    if [[ "$mode" == offline ]]; then
        config="$DEMO_DIR/zot-offline-config.json"
    elif [[ "$mode" != online ]]; then
        die "Unknown registry mode: $mode"
    fi
    ZOT_CONFIG="$config" "${COMPOSE[@]}" up -d zot || return
    id="$(registry_id)" || return
    network="$(uplink_name "$id")" || return
    ensure_online "$id" "$network" || return
    for ((attempt = 0; attempt < 30; attempt++)); do
        if cache_ready 2>/dev/null; then
            return 0
        fi
        sleep 1
    done
    "${COMPOSE[@]}" logs --tail 50 zot >&2
    printf 'ERROR: zot did not become ready within 30 seconds (%s mode).\n' "$mode" >&2
    return 1
}
