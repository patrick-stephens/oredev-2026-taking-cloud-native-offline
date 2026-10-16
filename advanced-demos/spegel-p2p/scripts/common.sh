#!/usr/bin/env bash
# shellcheck disable=SC2034
set -euo pipefail

DEMO_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
STATE="$DEMO_DIR/.state"
TOOLS="$DEMO_DIR/.tools"
CLUSTER=spegel-p2p
NETWORK=spegel-p2p-network
REGISTRY=spegel-p2p-registry
REGISTRY_PORT=5000
NODE_IMAGE=rancher/k3s:v1.35.5-k3s1
REGISTRY_IMAGE=registry:2.8.3
REDIS_SOURCE_IMAGE=docker.io/library/redis:alpine
REDIS_IMAGE=registry:5000/library/redis:alpine
SPEGEL_VERSION=0.8.0
SPEGEL_IMAGE="ghcr.io/spegel-org/spegel:v$SPEGEL_VERSION"
SPEGEL_CHART="oci://ghcr.io/spegel-org/helm-charts/spegel"
K3D_VERSION=5.9.0
K3D_SHA256=06d8f25bc3a971c4eb29e0ff08429b180402db0f4dec838c9eac427e296800a0

die() {
    printf 'ERROR: %s\n' "$*" >&2
    exit 1
}

banner() {
    if [[ -t 1 && ${TERM:-dumb} != dumb ]]; then
        clear
    fi
    printf '\n%s\n' "$1"
    sleep 2
}

advance() {
    if [[ -t 0 && -t 1 && ${DEMO_AUTO_ADVANCE:-0} != 1 ]]; then
        read -r -p 'Press Enter for the next phase... ' || die "Input ended before the next phase."
    fi
}

kube() {
    local server="k3d-$CLUSTER-server-0"
    docker exec "$server" kubectl --kubeconfig /etc/rancher/k3s/k3s.yaml "$@"
}

require_tools() {
    local tool
    for tool in docker curl helm sha256sum awk grep sed timeout; do
        command -v "$tool" >/dev/null || die "Required tool is missing: $tool"
    done
    [[ "$(docker info --format '{{.OSType}}/{{.Architecture}}')" == "linux/x86_64" ]] ||
        die "This demo requires a Linux amd64 Docker engine."
    [[ "$(helm version --short)" == v4.3.0* ]] ||
        die "Install the pinned Helm v4.3.0 release; found $(helm version --short)."
    mkdir -p "$STATE" "$TOOLS"
    chmod 700 "$STATE"
}

ensure_k3d() {
    local executable="$TOOLS/k3d" temporary="$TOOLS/k3d.download"
    if [[ -x "$executable" ]] &&
        printf '%s  %s\n' "$K3D_SHA256" "$executable" | sha256sum --check --status; then
        :
    else
        rm -f -- "$temporary"
        curl --fail --location --retry 3 --max-time 180 \
            "https://github.com/k3d-io/k3d/releases/download/v$K3D_VERSION/k3d-linux-amd64" \
            --output "$temporary"
        printf '%s  %s\n' "$K3D_SHA256" "$temporary" | sha256sum --check --status ||
            die "Downloaded k3d binary failed its pinned SHA-256 check."
        chmod 755 "$temporary"
        mv -- "$temporary" "$executable"
    fi
    [[ "$("$executable" version | awk 'NR == 1 { print $3 }')" == "v$K3D_VERSION" ]] ||
        die "Expected k3d v$K3D_VERSION."
}

assert_demo_resource_free() {
    if docker network inspect "$NETWORK" >/dev/null 2>&1; then
        die "Docker network $NETWORK already exists; run scripts/cleanup.sh first."
    fi
    if docker container inspect "$REGISTRY" >/dev/null 2>&1; then
        die "Container $REGISTRY already exists; run scripts/cleanup.sh first."
    fi
    if docker ps -aq --filter "label=k3d.cluster=$CLUSTER" | grep -q .; then
        die "A k3d cluster named $CLUSTER already exists; run scripts/cleanup.sh first."
    fi
    [[ ! -e "$STATE/cluster-owned" ]] ||
        die "A prior cluster ownership marker exists; run scripts/cleanup.sh first."
}

assert_cluster_owned() {
    [[ -f "$STATE/cluster-owned" && ! -L "$STATE/cluster-owned" ]] ||
        die "Cluster ownership marker is missing; refusing to delete a cluster."
    [[ "$(<"$STATE/cluster-owned")" == "$CLUSTER" ]] ||
        die "Cluster ownership marker does not match $CLUSTER."
    docker ps -aq --filter "label=k3d.cluster=$CLUSTER" |
        grep -q . || die "No k3d node with the expected cluster label exists."
    docker ps -aq --filter "label=k3d.cluster=$CLUSTER" --filter "label=demo=spegel-p2p" |
        grep -q . || die "Cluster containers do not have the demo ownership label."
}

block_external_egress() {
    local node subnet
    subnet="$(docker network inspect --format '{{range .IPAM.Config}}{{.Subnet}}{{end}}' "$NETWORK")"
    [[ "$subnet" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]] ||
        die "Unexpected Docker network subnet: $subnet"
    for node in "k3d-$CLUSTER-server-0" "k3d-$CLUSTER-agent-0" "k3d-$CLUSTER-agent-1"; do
        docker exec "$node" sh -ec '
            iptables -N SPEGEL_AIRGAP
            iptables -A SPEGEL_AIRGAP -d 127.0.0.0/8 -j RETURN
            iptables -A SPEGEL_AIRGAP -d "$1" -j RETURN
            iptables -A SPEGEL_AIRGAP -d 10.42.0.0/16 -j RETURN
            iptables -A SPEGEL_AIRGAP -d 10.43.0.0/16 -j RETURN
            iptables -A SPEGEL_AIRGAP -j REJECT
            iptables -I OUTPUT 1 -j SPEGEL_AIRGAP
            iptables -I FORWARD 1 -j SPEGEL_AIRGAP
        ' sh "$subnet"
    done
    printf 'Installed OUTPUT/FORWARD egress blocks on all nodes; allowed destinations are the node subnet and k3s pod/service CIDRs.\n'
}

assert_external_egress_blocked() {
    local node before after
    for node in "k3d-$CLUSTER-server-0" "k3d-$CLUSTER-agent-0" "k3d-$CLUSTER-agent-1"; do
        before="$(docker exec "$node" iptables -nvxL SPEGEL_AIRGAP |
            awk '$3 == "REJECT" { n += $1 } END { print n+0 }')"
        if docker exec "$node" sh -ec \
            'wget -T 3 -qO- http://1.1.1.1/ >/dev/null 2>&1'; then
            die "External HTTP probe unexpectedly succeeded from $node."
        fi
        after="$(docker exec "$node" iptables -nvxL SPEGEL_AIRGAP |
            awk '$3 == "REJECT" { n += $1 } END { print n+0 }')"
        [[ "$after" -gt "$before" ]] ||
            die "No egress-block counter increased on $node; cannot prove external traffic was denied."
        printf 'EXTERNAL EGRESS BLOCKED: %s (reject counter %s -> %s)\n' "$node" "$before" "$after"
    done
}

redis_image_on_node() {
    docker exec "$1" ctr --address /run/k3s/containerd/containerd.sock \
        --namespace k8s.io images list |
        awk -v image="$REDIS_IMAGE" '$1 == image { found = 1 } END { exit !found }'
}

ensure_docker_image() {
    if ! docker image inspect "$1" >/dev/null 2>&1; then
        docker pull "$1"
    fi
}
