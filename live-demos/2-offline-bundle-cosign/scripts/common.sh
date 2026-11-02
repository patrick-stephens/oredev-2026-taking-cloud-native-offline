#!/usr/bin/env bash
# Constants in this sourced file are used by the caller scripts.
# shellcheck disable=SC2034
set -euo pipefail

DEMO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
record_commands() { :; }
if [[ ${DEMO_RECORDING:-0} == 1 ]]; then
    source "$DEMO_DIR/../../scripts/recording-inspect.sh"
fi
if [[ "$(uname -s)" == Darwin ]]; then
    homebrew_prefix="${HOMEBREW_PREFIX:-/opt/homebrew}"
    if [[ -x "$homebrew_prefix/bin/brew" ]]; then
        PATH="$HOME/.local/bin:$homebrew_prefix/bin:$PATH"
        for formula in coreutils findutils gawk gnu-sed gnu-tar grep; do
            gnubin="$homebrew_prefix/opt/$formula/libexec/gnubin"
            [[ -d "$gnubin" ]] && PATH="$gnubin:$PATH"
        done
        export PATH
    fi
fi
STATE="$DEMO_DIR/.state"
KEYS_DIR="$DEMO_DIR/keys"
if [[ -e "$KEYS_DIR/cosign.key" || -e "$KEYS_DIR/password" ]]; then
    SIGNING_DIR="$KEYS_DIR"
else
    SIGNING_DIR="$STATE/signing"
fi
COSIGN_KEY="$SIGNING_DIR/cosign.key"
COSIGN_PUB="$SIGNING_DIR/cosign.pub"
COSIGN_PASSWORD_FILE="$SIGNING_DIR/password"
CLUSTER=offline-bundle-demo
NODE="$CLUSTER-control-plane"
NETWORK=offline-bundle-target
REGISTRY=offline-bundle-registry
SKOPEO=quay.io/skopeo/stable:v1.20.0
COSIGN=ghcr.io/sigstore/cosign/cosign:v2.4.3
NODE_IMAGE=kindest/node:v1.35.0
CHART_VERSION=0.1.0
POSTGRES_TAG=18.6-alpine3.23
POSTGRES_IMAGE="docker.io/library/postgres:$POSTGRES_TAG"
TARGET_PLATFORM=""
DEMO_ARCH=""
ZOT=""

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

banner() {
    if [[ ${DEMO_RECORDING:-0} == 1 ]]; then sleep 3; fi
    if [[ -t 1 && ${TERM:-dumb} != dumb ]]; then clear; fi
    printf '\n============================================================\n%s\n============================================================\n' "$1"
}

show_commands() {
    printf '\nShow this stage (read-only commands):\n'
    printf '  %s\n' "$@"
}

advance() {
    if [[ -t 0 && -t 1 && ${DEMO_AUTO_ADVANCE:-0} != 1 ]]; then
        read -r -p 'Press Enter for the next phase... ' || die "Input ended before the next phase."
    fi
}

detect_target_platform() {
    local engine_platform engine_arch host_os host_arch
    engine_platform="$(docker info --format '{{.OSType}}/{{.Architecture}}')"
    case "$engine_platform" in
        linux/x86_64|linux/amd64) engine_arch=amd64 ;;
        linux/aarch64|linux/arm64) engine_arch=arm64 ;;
        *) die "Unsupported Docker engine platform: $engine_platform" ;;
    esac
    host_os="$(uname -s)"
    host_arch="$(uname -m)"
    case "$host_os/$host_arch/$engine_arch" in
        Darwin/arm64/arm64|Linux/x86_64/amd64|Linux/aarch64/arm64|Linux/arm64/arm64) ;;
        *) die "Use a native Linux Docker engine matching this host, or macOS ARM with Docker Desktop Linux ARM64." ;;
    esac
    DEMO_ARCH="$engine_arch"
    TARGET_PLATFORM="linux/$DEMO_ARCH"
    ZOT="ghcr.io/project-zot/zot-linux-$DEMO_ARCH:v2.1.15"
    export DEMO_ARCH TARGET_PLATFORM
}

require_tools() {
    local tool
    for tool in docker helm kind jq tar timeout sha256sum find sort \
        stat awk grep cmp base64 head realpath; do
        command -v "$tool" >/dev/null || die "Required tool is missing: $tool"
    done
    detect_target_platform
    mkdir -p "$STATE"
    chmod 700 "$STATE"
}

ensure_image() {
    local platform
    platform="$(docker image inspect --format '{{.Os}}/{{.Architecture}}' "$1" 2>/dev/null || true)"
    if [[ "$platform" != "$TARGET_PLATFORM" ]]; then
        timeout 120s docker pull --platform "$TARGET_PLATFORM" "$1"
    fi
}

target_helm() {
    local version archive_url archive checksum work target
    version="$(helm version --template '{{.Version}}')"
    archive="helm-${version}-linux-${DEMO_ARCH}.tar.gz"
    work="$STATE/target-tools"
    target="$work/helm-${version}"
    mkdir -p "$work"
    if [[ ! -x "$target" ]]; then
        archive="$work/$archive"
        archive_url="https://get.helm.sh/$(basename -- "$archive")"
        checksum="$(curl -fsSL "$archive_url.sha256sum" | awk '{print $1}')"
        curl --fail --location --silent --show-error --retry 3 --connect-timeout 15 --max-time 180 \
            "$archive_url" -o "$archive.partial"
        printf '%s  %s\n' "$checksum" "$archive.partial" | sha256sum --check --status ||
            die "Helm archive checksum verification failed."
        mv "$archive.partial" "$archive"
        tar -xzf "$archive" -C "$work" "linux-$DEMO_ARCH/helm"
        cp "$work/linux-$DEMO_ARCH/helm" "$target"
        chmod 755 "$target"
        rm -rf -- "$work/linux-$DEMO_ARCH"
    fi
    printf '%s\n' "$target"
}

signing_tool() {
    docker run --rm --network none --user "$(id -u):$(id -g)" \
        --env COSIGN_PASSWORD --env HOME=/tmp \
        --mount "type=bind,src=$SIGNING_DIR,dst=/keys" \
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
