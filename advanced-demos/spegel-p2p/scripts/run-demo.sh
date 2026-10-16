#!/usr/bin/env bash
set -euo pipefail
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=common.sh
source "$SCRIPT_DIR/common.sh"

[[ $# -eq 0 ]] || die "Usage: ./scripts/run-demo.sh"
require_tools
ensure_k3d
assert_demo_resource_free

started=$SECONDS
finish() {
    local status=$?
    local pods pod
    trap - EXIT INT TERM
    if [[ "$status" -ne 0 && -f "$STATE/cluster-owned" ]]; then
        printf '\nFailure diagnostics: node scheduling, workload events, and Spegel logs.\n' >&2
        if ! kube get pods -A -o wide; then
            printf 'Could not list cluster pods during failure diagnostics.\n' >&2
        fi
        if ! kube get nodes -o wide --show-labels; then
            printf 'Could not list node labels during failure diagnostics.\n' >&2
        fi
        if ! kube describe nodes; then
            printf 'Could not describe node conditions and taints during failure diagnostics.\n' >&2
        fi
        if ! kube describe pods -l app=redis-peer-demo; then
            printf 'Could not describe Redis workload pods during failure diagnostics.\n' >&2
        fi
        if ! kube get events -A --sort-by=.lastTimestamp; then
            printf 'Could not list cluster events during failure diagnostics.\n' >&2
        fi
        if pods="$(kube get pods -n spegel -o name)"; then
            while IFS= read -r pod; do
                [[ -n "$pod" ]] || continue
                printf '\nLogs: %s\n' "$pod" >&2
                if ! kube logs -n spegel "$pod" --all-containers=true --tail=100; then
                    printf 'Could not read logs for %s.\n' "$pod" >&2
                fi
            done <<<"$pods"
        else
            printf 'Could not identify Spegel pods during failure diagnostics.\n' >&2
        fi
    fi
    if ! "$SCRIPT_DIR/cleanup.sh"; then
        printf 'ERROR: cleanup failed; inspect the demo resources before retrying.\n' >&2
        status=1
    fi
    printf '\nTOTAL RUNTIME: %ss (including cleanup).\n' "$((SECONDS - started))"
    exit "$status"
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

banner '=== PHASE CONNECTED: seed the registry and prepare the three-node cluster ==='
docker network create --label demo=spegel-p2p "$NETWORK" >/dev/null
docker run --detach --name "$REGISTRY" --label demo=spegel-p2p \
    --publish "127.0.0.1:$REGISTRY_PORT:5000" "$REGISTRY_IMAGE" >/dev/null
docker network connect --alias registry "$NETWORK" "$REGISTRY"

for attempt in $(seq 1 30); do
    if curl --fail --silent "http://127.0.0.1:$REGISTRY_PORT/v2/" >/dev/null; then
        break
    fi
    [[ "$attempt" -lt 30 ]] || die "Local registry did not become ready."
    sleep 1
done

printf 'Pulling the official Redis Alpine image from Docker Hub on the connected host...\n'
docker pull "$REDIS_SOURCE_IMAGE"
docker tag "$REDIS_SOURCE_IMAGE" "localhost:$REGISTRY_PORT/library/redis:alpine"
docker push "localhost:$REGISTRY_PORT/library/redis:alpine"

printf 'Pulling pinned cluster and Spegel images, then downloading Helm chart v%s...\n' "$SPEGEL_VERSION"
ensure_docker_image "$NODE_IMAGE"
ensure_docker_image "$SPEGEL_IMAGE"
helm pull "$SPEGEL_CHART" --version "$SPEGEL_VERSION" --destination "$STATE"

K3D="$TOOLS/k3d"
printf '%s\n' "$CLUSTER" >"$STATE/cluster-owned"
"$K3D" cluster create "$CLUSTER" \
    --servers 1 --agents 2 \
    --image "$NODE_IMAGE" \
    --network "$NETWORK" \
    --registry-config "$DEMO_DIR/config/registries.yaml" \
    --volume "$DEMO_DIR/config/containerd-v3.d:/var/lib/rancher/k3s/agent/etc/containerd/config-v3.toml.d@all" \
    --k3s-arg '--kubelet-arg=eviction-hard=nodefs.available<1Gi,imagefs.available<1Gi,nodefs.inodesFree<1%@all' \
    --k3s-arg '--kubelet-arg=image-gc-high-threshold=99@all' \
    --k3s-arg '--kubelet-arg=image-gc-low-threshold=98@all' \
    --runtime-label 'demo=spegel-p2p@all' \
    --wait --timeout 180s
assert_cluster_owned

NODE_A="k3d-$CLUSTER-agent-0"
NODE_B="k3d-$CLUSTER-agent-1"
NODE_A_NAME="$NODE_A"
NODE_B_NAME="$NODE_B"
for node in "k3d-$CLUSTER-server-0" "$NODE_A" "$NODE_B"; do
    docker exec "$node" sh -ec '
        config=/var/lib/rancher/k3s/agent/etc/containerd/config.toml
        patch=/var/lib/rancher/k3s/agent/etc/containerd/config-v3.toml.d/10-spegel.toml
        grep -Fq "config-v3.toml.d/*.toml" "$config"
        grep -Fq "discard_unpacked_layers = false" "$patch"
        grep -Fq "snapshotter = \"overlayfs\"" "$patch"
        grep -Fq "content_sharing_policy = \"isolated\"" "$patch"
        command -v iptables >/dev/null
        command -v wget >/dev/null
    ' || die "The imported containerd patch or egress-verification tooling is missing on $node."
done
kube wait --for=condition=Ready nodes --all --timeout=180s >/dev/null
[[ "$(kube get nodes --no-headers | wc -l)" -eq 3 ]] ||
    die "Expected exactly one server and two agent nodes."

"$K3D" image import "$SPEGEL_IMAGE" --cluster "$CLUSTER"
helm upgrade --install spegel "$STATE/spegel-$SPEGEL_VERSION.tgz" \
    --namespace spegel --create-namespace \
    --values "$DEMO_DIR/config/spegel-values.yaml" \
    --wait --timeout 180s
kube rollout status daemonset/spegel -n spegel --timeout=180s

kube label node "$NODE_A_NAME" spegel.demo/worker=true --overwrite
kube label node "$NODE_B_NAME" spegel.demo/worker=true --overwrite

printf '\nCONNECTED EVIDENCE: pre-pull Redis only on node A (%s).\n' "$NODE_A_NAME"
docker exec "$NODE_A" ctr --address /run/k3s/containerd/containerd.sock \
    --namespace k8s.io images pull \
    --hosts-dir /var/lib/rancher/k3s/agent/etc/containerd/certs.d "$REDIS_IMAGE"
DISK_PRESSURE="$(kube get nodes -o jsonpath='{range .items[*]}{.metadata.name}{" "}{range .status.conditions[?(@.type=="DiskPressure")]}{.status}{end}{"\n"}{end}')"
printf '%s\n' "$DISK_PRESSURE" | awk '
    NF != 2 || $2 != "False" { bad = 1 }
    END { if (NR != 3) bad = 1; exit bad }
' || die "One or more nodes report DiskPressure; see kubelet eviction and host free-space thresholds."
redis_image_on_node "$NODE_A" ||
    die "Redis did not appear in node A containerd."
if redis_image_on_node "$NODE_B"; then
    die "Redis was unexpectedly present on node B before the offline pull."
fi
printf '\nNode A image record:\n'
docker exec "$NODE_A" ctr --address /run/k3s/containerd/containerd.sock \
    --namespace k8s.io images list | grep -F "$REDIS_IMAGE"
printf 'Node B image record: absent, as required.\n'
printf 'Containerd patch: discard_unpacked_layers=false; snapshotter=overlayfs on all three nodes.\n'
printf 'Registry endpoint: http://registry:%s (separate container, connected to the cluster network).\n' "$REGISTRY_PORT"

advance
banner '=== PHASE AIR-GAPPED: stop the registry and prove peer distribution ==='
docker stop "$REGISTRY" >/dev/null
[[ "$(docker inspect --format '{{.State.Running}}' "$REGISTRY")" == false ]] ||
    die "The central registry is still running."
printf 'CENTRAL REGISTRY: stopped\n'
block_external_egress
assert_external_egress_blocked

printf '\nDeploying three Always-pull Redis replicas, constrained to the two agent nodes...\n'
docker exec -i "k3d-$CLUSTER-server-0" kubectl \
    --kubeconfig /etc/rancher/k3s/k3s.yaml apply -f - \
    <"$DEMO_DIR/manifests/redis-deployment.yaml"
kube rollout status deployment/redis-peer-demo --timeout=180s

POD_ROWS="$(kube get pods -l app=redis-peer-demo \
    -o 'custom-columns=NAME:.metadata.name,NODE:.spec.nodeName,PHASE:.status.phase' --no-headers)"
printf '\nRedis pods:\n%s\n' "$POD_ROWS"
[[ "$(printf '%s\n' "$POD_ROWS" | awk '$3 == "Running" { count++ } END { print count+0 }')" -eq 3 ]] ||
    die "Expected three Running Redis pods."
printf '%s\n' "$POD_ROWS" | awk -v node="$NODE_B_NAME" '$2 == node && $3 == "Running" { found=1 } END { exit !found }' ||
    die "No Redis pod reached Running on node B ($NODE_B_NAME)."
redis_image_on_node "$NODE_B" ||
    die "The Redis image did not arrive in node B containerd."
REDIS_B_POD="$(printf '%s\n' "$POD_ROWS" | awk -v node="$NODE_B_NAME" '$2 == node && $3 == "Running" { print $1; exit }')"
FORWARD_BEFORE="$(docker exec "$NODE_B" iptables -nvxL SPEGEL_AIRGAP |
    awk '$3 == "REJECT" { n += $1 } END { print n+0 }')"
if kube exec "$REDIS_B_POD" -- sh -ec 'wget -T 3 -qO- http://1.1.1.1/ >/dev/null 2>&1'; then
    die "An AIR-GAPPED Redis pod unexpectedly reached an external HTTP endpoint."
fi
FORWARD_AFTER="$(docker exec "$NODE_B" iptables -nvxL SPEGEL_AIRGAP |
    awk '$3 == "REJECT" { n += $1 } END { print n+0 }')"
[[ "$FORWARD_AFTER" -gt "$FORWARD_BEFORE" ]] ||
    die "The Redis pod's external probe did not hit the node's FORWARD egress block."
printf 'POD EGRESS BLOCKED: node B FORWARD reject counter %s -> %s\n' "$FORWARD_BEFORE" "$FORWARD_AFTER"

SPEGEL_PODS="$(kube get pods -n spegel \
    -o 'custom-columns=NAME:.metadata.name,NODE:.spec.nodeName' --no-headers)"
SPEGEL_A_POD="$(printf '%s\n' "$SPEGEL_PODS" | awk -v node="$NODE_A_NAME" '$2 == node { print $1; exit }')"
SPEGEL_B_POD="$(printf '%s\n' "$SPEGEL_PODS" | awk -v node="$NODE_B_NAME" '$2 == node { print $1; exit }')"
[[ -n "$SPEGEL_A_POD" && -n "$SPEGEL_B_POD" ]] ||
    die "Could not identify Spegel pods on both worker nodes."

printf '\nSpegel logs on node A (%s), after node B requested the image:\n' "$NODE_A_NAME"
kube logs -n spegel "$SPEGEL_A_POD" --all-containers=true --prefix --since=5m

printf '\nSpegel metrics on node B (%s), the requesting peer:\n' "$NODE_B_NAME"
METRICS="$(kube get --raw "/api/v1/namespaces/spegel/pods/$SPEGEL_B_POD:9090/proxy/metrics")"
printf '%s\n' "$METRICS" | grep -E '^spegel_(mirror_requests_total|mirror_last_success_timestamp_seconds|resolve_duration_seconds|advertised_keys)' ||
    die "Spegel metrics were not available from the node B pod."
printf '%s\n' "$METRICS" |
    awk '$1 ~ /^spegel_mirror_requests_total/ && $0 ~ /cache="hit"/ && $NF + 0 > 0 { found=1 } END { exit !found }' ||
    die "Node B did not report a successful peer mirror hit."

printf '\nPASS: node B started Redis with the central registry stopped and external egress blocked.\n'
printf 'PASS: Redis is present in node B containerd; Spegel reports a peer mirror hit.\n'
advance
