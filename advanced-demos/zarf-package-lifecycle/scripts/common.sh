#!/usr/bin/env bash
# Constants are shared with callers in this demo directory only.
# shellcheck disable=SC2034
set -euo pipefail
DEMO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS="$DEMO_DIR/.tools"
STATE="$DEMO_DIR/.state"
ARTIFACTS="$DEMO_DIR/artifacts"
CLUSTER=zarf-lifecycle
NODE=k3d-zarf-lifecycle-server-0
PACKAGE=zarf-package-podinfo-offline-amd64-6.15.0.tar.zst
INIT=zarf-init-amd64-v0.88.0.tar.zst
NODE_IMAGE=rancher/k3s:v1.35.5-k3s1

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

phase() {
    if [[ -t 1 && ${TERM:-dumb} != dumb ]]; then clear; fi
    printf '\n=== %s ===\n' "$1"
    sleep 1
}

require_tools() {
    local tool
    for tool in docker curl jq sha256sum awk grep sed timeout; do
        command -v "$tool" >/dev/null || die "Missing required tool: $tool"
    done
    [[ "$(uname -s)/$(uname -m)" == Linux/x86_64 ]] || die "Use a Linux amd64 sandbox."
    [[ "$(docker info --format '{{.OSType}}/{{.Architecture}}')" == linux/x86_64 ]] ||
        die "Use a local Linux amd64 Docker engine."
    mkdir -p "$STATE" "$ARTIFACTS"
    chmod 700 "$STATE"
    [[ -x "$TOOLS/zarf" && -x "$TOOLS/k3d" ]] || die "CONNECTED: run ./scripts/install-tools.sh first."
    [[ "$("$TOOLS/zarf" version)" == v0.88.0 ]] || die "Expected Zarf v0.88.0."
    "$TOOLS/k3d" version | grep -Fxq 'k3d version v5.9.0' || die "Expected k3d v5.9.0."
}

assert_owned() {
    [[ -s "$STATE/node-id" ]] || die "No local ownership record; refusing to use a possibly unrelated node."
    [[ "$(docker inspect --format '{{.Id}}' "$NODE")" == "$(<"$STATE/node-id")" ]] ||
        die "Node identity does not match the local ownership record."
}

target_zarf() {
    docker exec --env KUBECONFIG=/etc/rancher/k3s/k3s.yaml \
        --env ZARF_CACHE_PATH=/work/.state/target-cache \
        --workdir /work/artifacts "$NODE" /work/.tools/zarf --no-color "$@"
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
