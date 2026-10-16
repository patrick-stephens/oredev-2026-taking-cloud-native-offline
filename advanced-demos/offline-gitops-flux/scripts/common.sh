#!/usr/bin/env bash
# shellcheck disable=SC2034 # Shared values are consumed by scripts sourcing this file.
set -euo pipefail

DEMO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_DIR="$DEMO_DIR/.state"
TOOLS_DIR="$DEMO_DIR/.tools"
NETWORK_NAME="offline-gitops-net"
REGISTRY_CONTAINER="offline-gitops-registry"
GITEA_CONTAINER="offline-gitops-gitea"
CLUSTER_NAME="offline-gitops"
CLUSTER_NODE="${CLUSTER_NAME}-control-plane"
REGISTRY_IMAGE="registry:2.8.3"
GITEA_IMAGE="gitea/gitea:1.23.8"
KIND_NODE_IMAGE="kindest/node:v1.32.2"
PODINFO_IMAGE="ghcr.io/stefanprodan/podinfo:6.15.0"
CURL_IMAGE="curlimages/curl:8.12.1"
FLUX_VERSION="2.5.1"
KIND_VERSION="0.27.0"
KUBECTL_VERSION="1.32.2"
HELM_VERSION="3.17.1"
CHART_VERSION="6.15.0"

export PATH="$TOOLS_DIR:$PATH"

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

phase() {
    if [[ -t 1 && -n "${TERM:-}" ]]; then
        clear
    else
        printf '\n\n'
    fi
    printf "=== PHASE %s ===\n" "$1"
    sleep 1
}

pause_for_presenter() {
    if [[ "${DEMO_AUTO_ADVANCE:-0}" == "1" ]]; then
        sleep 1
    elif [[ -t 0 ]]; then
        read -r -p "Press Enter to continue... "
    fi
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

wait_for_url() {
    local url=$1
    local label=$2
    local attempt
    for attempt in {1..60}; do
        if curl --noproxy '*' --fail --silent --show-error "$url" >/dev/null 2>&1; then
            return 0
        fi
        sleep 2
    done
    die "Timed out waiting for $label at $url after $attempt attempts"
}

network_container_ip() {
    docker inspect --format \
        "{{with index .NetworkSettings.Networks \"$NETWORK_NAME\"}}{{.IPAddress}}{{end}}" "$1"
}
