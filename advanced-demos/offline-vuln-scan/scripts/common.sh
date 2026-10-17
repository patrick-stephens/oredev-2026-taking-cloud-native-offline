#!/usr/bin/env bash
# Shared variables are consumed by the scripts that source this file.
# shellcheck disable=SC2034
set -euo pipefail

DEMO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
DEMO_NETWORK="offline-vuln-scan-internal"
DEMO_REGISTRY="offline-vuln-scan-registry"
DEMO_NETWORK_LABEL="org.oredev.demo=offline-vuln-scan"
DEMO_REGISTRY_IMAGE="registry:2.8.3"
DEMO_SKOPEO_IMAGE="quay.io/skopeo/stable:v1.20.0"
DEMO_RUNTIME_IMAGE="alpine:3.22.1"
DEMO_TRIVY_VERSION="v0.76.0"
DEMO_GRYPE_VERSION="v0.120.1"
DEMO_BUNDLE="$DEMO_DIR/.bundle"
DEMO_STAGE="$DEMO_DIR/.state/stage"
DEMO_ARCHIVE="$DEMO_DIR/artifacts/offline-vuln-scan-bundle.tar.gz"

fail() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

managed_container_exists() {
    local name="$1"
    local label
    if ! docker container inspect "$name" >/dev/null 2>&1; then
        return 1
    fi
    label="$(docker container inspect --format '{{ index .Config.Labels "org.oredev.demo" }}' "$name")"
    [[ "$label" == "offline-vuln-scan" ]] ||
        fail "Container name '$name' is in use by a container not labelled for this demo."
}

ensure_internal_network() {
    local internal label
    if docker network inspect "$DEMO_NETWORK" >/dev/null 2>&1; then
        internal="$(docker network inspect --format '{{ .Internal }}' "$DEMO_NETWORK")"
        label="$(docker network inspect --format '{{ index .Labels "org.oredev.demo" }}' "$DEMO_NETWORK")"
        [[ "$label" == "offline-vuln-scan" ]] ||
            fail "Network '$DEMO_NETWORK' exists but is not labelled for this demo."
        [[ "$internal" == "true" ]] ||
            fail "Network '$DEMO_NETWORK' is not internal; refusing to run scans."
    else
        docker network create --internal --label "$DEMO_NETWORK_LABEL" "$DEMO_NETWORK" >/dev/null
    fi
}

phase() {
    if [[ -t 1 && -n "${TERM:-}" ]]; then
        clear
    fi
    printf '\n=== PHASE %s ===\n' "$1"
    sleep 1
}

presenter_pause() {
    if [[ "${DEMO_AUTO_ADVANCE:-0}" != "1" && -t 0 ]]; then
        read -r -p "Press Enter when ready to continue..."
    else
        sleep 2
    fi
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "Required command not found: $1"
}

require_docker() {
    require_command docker
    docker info >/dev/null 2>&1 || fail "Docker is unavailable or the current user cannot access it."
}

offline_run() {
    docker run --rm --pull=never --network "$DEMO_NETWORK" \
        --dns 127.0.0.1 --user "$(id -u):$(id -g)" \
        --cap-drop ALL --security-opt no-new-privileges \
        -e HOME=/tmp "$@"
}

repair_generated_ownership() {
    local directory
    for directory in "$DEMO_BUNDLE" "$DEMO_DIR/.state"; do
        if [[ -d "$directory" ]]; then
            docker run --rm --pull=never --network none --user 0:0 \
                -v "$directory:/generated" "$DEMO_RUNTIME_IMAGE" \
                chown -R "$(id -u):$(id -g)" /generated
        fi
    done
}

expect_network_failure() {
    local description="$1" log="$2"
    shift 2
    local status
    if "$@" >"$log" 2>&1; then
        cat "$log"
        fail "$description unexpectedly succeeded."
    else
        status=$?
    fi
    cat "$log"
    [[ "$status" == 1 ]] ||
        fail "$description returned $status instead of a scanner/network error (1)."
    grep -Eiq 'lookup .*(:53|no such host)|network (is )?unreachable|no route to host|i/o timeout|timed out|connection refused|server misbehaving|operation not permitted|bad address' "$log" ||
        fail "$description failed without evidence of a network error."
    printf '%s: expected network failure (exit %s)\n' "$description" "$status"
}
