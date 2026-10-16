#!/usr/bin/env bash
# Constants in this sourced file are used by the caller scripts.
# shellcheck disable=SC2034
set -euo pipefail

DEMO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
STATE="$DEMO_DIR/.state"
CLUSTER=offline-bundle-demo
NODE="$CLUSTER-control-plane"
NETWORK=offline-bundle-target
REGISTRY=offline-bundle-registry
SKOPEO=quay.io/skopeo/stable:v1.20.0
COSIGN=ghcr.io/sigstore/cosign/cosign:v2.4.3
ZOT=ghcr.io/project-zot/zot-linux-amd64:v2.1.15
NODE_IMAGE=kindest/node:v1.35.0
CHART_VERSION=22.0.11

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

banner() {
    if [[ -t 1 && ${TERM:-dumb} != dumb ]]; then clear; fi
    printf '\n============================================================\n%s\n============================================================\n' "$1"
}

advance() {
    if [[ -t 0 && -t 1 && ${DEMO_AUTO_ADVANCE:-0} != 1 ]]; then
        read -r -p 'Press Enter for the next phase... ' || die "Input ended before the next phase."
    fi
}

require_tools() {
    local tool
    for tool in docker helm kind jq tar timeout sha256sum find sort \
        stat awk grep cmp base64 head realpath; do
        command -v "$tool" >/dev/null || die "Required tool is missing: $tool"
    done
    [[ "$(docker info --format '{{.OSType}}/{{.Architecture}}')" == linux/x86_64 ]] ||
        die "Use a Linux amd64 Docker engine and a native Linux amd64 host."
    [[ "$(uname -s)/$(uname -m)" == Linux/x86_64 ]] ||
        die "The bundled Helm management binary requires a native Linux amd64 host."
    mkdir -p "$STATE"
    chmod 700 "$STATE"
}

ensure_image() {
    if ! docker image inspect "$1" >/dev/null 2>&1; then
        timeout 120s docker pull "$1"
    fi
}

signing_tool() {
    docker run --rm --network none --user "$(id -u):$(id -g)" \
        --env COSIGN_PASSWORD --env HOME=/tmp \
        --mount "type=bind,src=$DEMO_DIR/keys,dst=/keys" \
        --mount "type=bind,src=$1,dst=/bundle" --workdir /keys \
        "$COSIGN" "${@:2}"
}

assert_offline() {
    local routes
    assert_target_owned
    [[ "$(docker inspect --format '{{.State.Running}}' "$NODE")" == true ]] ||
        die "Target is not running; run ./scripts/prepare-target.sh."
    routes="$(docker exec "$NODE" sh -ec 'ip -4 route show default; ip -6 route show default')"
    [[ -z "$routes" ]] || die "Target still has an internet/default route: $routes"
    docker inspect "$NODE" | jq -e --arg network "$NETWORK" \
        '.[0].NetworkSettings.Networks | keys == [$network]' >/dev/null ||
        die "Unexpected network attachment on the target."
}

assert_target_owned() {
    [[ -s "$STATE/node-id" ]] || die "Target ownership record is missing; refusing to touch a possibly unrelated cluster."
    [[ "$(docker inspect --format '{{.Id}}' "$NODE")" == "$(<"$STATE/node-id")" ]] ||
        die "Target identity differs from this demo's ownership record."
}

kube() {
    docker exec "$NODE" kubectl --kubeconfig /etc/kubernetes/admin.conf "$@"
}

# Only remove private mktemp directories made by these scripts.
remove_workdir() {
    local path=$1
    case "$path" in
        "$DEMO_DIR"/.build.*|"$DEMO_DIR"/.verify.*)
            [[ -d "$path" && ! -L "$path" ]] || return 0
            rm -rf -- "$path"
            ;;
        *) die "Refusing to remove unexpected work directory: $path" ;;
    esac
}
