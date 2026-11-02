#!/usr/bin/env bash
# Constants are shared with callers in this demo directory only.
# shellcheck disable=SC2034
set -euo pipefail
DEMO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
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
TOOLS="$DEMO_DIR/.tools"
STATE="$DEMO_DIR/.state"
ARTIFACTS="$DEMO_DIR/artifacts"
CLUSTER=zarf-lifecycle
NODE=k3d-zarf-lifecycle-server-0
PACKAGE=""
INIT=""
DEMO_ARCH=""
TARGET_PLATFORM=""
NODE_IMAGE=rancher/k3s:v1.35.5-k3s1
COSIGN=ghcr.io/sigstore/cosign/cosign:v2.4.3
KEYS="$DEMO_DIR/keys"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

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
        Darwin/arm64/arm64|Linux/x86_64/amd64) ;;
        *) die "Use Linux x86_64 or experimental macOS ARM with a matching Linux Docker engine." ;;
    esac
    DEMO_ARCH="$engine_arch"
    TARGET_PLATFORM="linux/$DEMO_ARCH"
    PACKAGE="zarf-package-podinfo-offline-$DEMO_ARCH-6.15.0.tar.zst"
    INIT="zarf-init-$DEMO_ARCH-v0.88.0.tar.zst"
    export DEMO_ARCH TARGET_PLATFORM
}

phase() {
    if [[ ${DEMO_RECORDING:-0} == 1 ]]; then sleep 3; fi
    if [[ -t 1 && ${TERM:-dumb} != dumb ]]; then clear; fi
    printf '\n=== %s ===\n' "$1"
    sleep 1
}

require_tools() {
    local tool
    for tool in docker curl jq sha256sum awk grep sed timeout head base64 cmp realpath; do
        command -v "$tool" >/dev/null || die "Missing required tool: $tool"
    done
    detect_target_platform
    mkdir -p "$STATE" "$ARTIFACTS"
    chmod 700 "$STATE"
    [[ -x "$TOOLS/zarf" && -x "$TOOLS/zarf-target" && -x "$TOOLS/k3d" ]] ||
        die "CONNECTED: run ./scripts/install-tools.sh first."
    [[ "$("$TOOLS/zarf" version)" == v0.88.0 ]] || die "Expected Zarf v0.88.0."
    "$TOOLS/k3d" version | grep -Fxq 'k3d version v5.9.0' || die "Expected k3d v5.9.0."
}

assert_owned() {
    [[ -s "$STATE/node-id" ]] || die "No local ownership record; refusing to use a possibly unrelated node."
    [[ "$(docker inspect --format '{{.Id}}' "$NODE")" == "$(<"$STATE/node-id")" ]] ||
        die "Node identity does not match the local ownership record."
}

assert_private_keys_unmounted() {
    docker inspect "$NODE" | jq -e --arg keys "$KEYS" --arg demo "$DEMO_DIR" '
        all(.[0].Mounts[]; .Source != $demo and .Source != $keys)
    ' >/dev/null || die "Old cluster mount exposes build-side keys. Run cleanup and recreate the target."
}

target_zarf() {
    docker exec --env KUBECONFIG=/etc/rancher/k3s/k3s.yaml \
        --env ZARF_CACHE_PATH=/work/.state/target-cache \
        --workdir /work/artifacts "$NODE" /work/.tools/zarf-target --no-color "$@"
}

kube() { docker exec "$NODE" /bin/kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml "$@"; }

assert_isolated() {
    assert_owned
    local family chain first
    for family in iptables ip6tables; do
        for chain in OUTPUT FORWARD; do
            first="$(docker exec "$NODE" "$family" -t mangle -S "$chain" | sed -n '2p')"
            [[ "$first" == "-A $chain -j ZARF_DEMO_EGRESS" ]] ||
                die "Isolation rule is no longer first in $family $chain: $first"
        done
        docker exec "$NODE" "$family" -t mangle -C ZARF_DEMO_EGRESS -j DROP
    done
    [[ "$(docker inspect "$NODE" | jq '.[0].NetworkSettings.Networks | length')" == 1 ]] ||
        die "Unexpected additional Docker network on target."
}

audit_egress() {
    local family
    for family in iptables ip6tables; do
        docker exec "$NODE" "$family" -t mangle -nvxL ZARF_DEMO_EGRESS
    done
}
