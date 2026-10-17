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
ARGOCD_VERSION="3.1.9"
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
        if curl --noproxy '*' --fail --silent --show-error --max-time 3 "$url" >/dev/null 2>&1; then
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

verify_state() {
    local replicas=$1 message=$2 commit=$3
    local engine=${4:-flux}
    local revision="main@sha1:$commit"
    local actual
    if [[ "$engine" == argocd ]]; then
        kubectl -n argocd get application podinfo -o json |
            jq -e --arg commit "$commit" '
                .status.sync.revision == $commit and .status.sync.status == "Synced" and
                .status.health.status == "Healthy" and .status.operationState.phase == "Succeeded" and
                .status.operationState.syncResult.revision == $commit
            ' >/dev/null || die "Argo CD has not synced the expected Git commit."
    else
        actual="$(kubectl -n flux-system get gitrepository flux-system -o jsonpath='{.status.artifact.revision}')"
        [[ "$actual" == "$revision" ]] || die "Git source revision is $actual, expected $revision"
        actual="$(kubectl -n flux-system get kustomization flux-system -o jsonpath='{.status.lastAppliedRevision}')"
        [[ "$actual" == "$revision" ]] || die "Applied revision is $actual, expected $revision"

        kubectl -n podinfo get helmrelease podinfo -o json |
            jq -e --argjson replicas "$replicas" --arg message "$message" '
                .metadata.generation as $generation |
                .spec.values.replicaCount == $replicas and
                .spec.values.ui.message == $message and
                .status.observedGeneration == $generation and
                any(.status.conditions[]; .type == "Ready" and .status == "True" and
                    .observedGeneration == $generation)
            ' >/dev/null || die "HelmRelease has not released the expected replicas/message at its current generation."
    fi
    kubectl -n podinfo rollout status deployment/podinfo --timeout=3m
    kubectl -n podinfo get deployment podinfo -o json |
        jq -e --argjson replicas "$replicas" '
            .spec.replicas == $replicas and
            .status.observedGeneration == .metadata.generation and
            .status.updatedReplicas == $replicas and
            .status.readyReplicas == $replicas and
            .status.availableReplicas == $replicas
        ' >/dev/null || die "Deployment does not have exactly $replicas updated, ready and available replicas."
    kubectl get --raw /api/v1/namespaces/podinfo/services/http:podinfo:9898/proxy/ |
        jq -e --arg message "$message" '
            .version == "6.15.0" and .message == $message and (.logo | startswith("data:"))
        ' >/dev/null || die "The running Podinfo app returned an unexpected version, message or external logo."
    printf 'PASS: revision %s, %s ready replicas, live message "%s" and embedded logo.\n' \
        "$commit" "$replicas" "$message"
}

verify_isolation() {
    local registry_ip=$1 external_iface=$2 external_ip=$3
    local engine=${4:-flux}
    local container network
    [[ "$(docker network inspect --format '{{.Internal}}' "$NETWORK_NAME")" == "true" ]] ||
        die "The service network is no longer internal."
    for container in "$REGISTRY_CONTAINER" "$GITEA_CONTAINER"; do
        network="$(docker inspect --format '{{json .NetworkSettings.Networks}}' "$container")"
        jq -e --arg network "$NETWORK_NAME" 'keys == [$network]' <<<"$network" >/dev/null ||
            die "$container has an unexpected network attachment."
    done
    for network in iptables ip6tables; do
        docker exec "$CLUSTER_NODE" "$network" -C OUTPUT -o "$external_iface" -j REJECT ||
            die "$network OUTPUT egress block is missing on $external_iface."
        docker exec "$CLUSTER_NODE" "$network" -C FORWARD -o "$external_iface" -j REJECT ||
            die "$network FORWARD egress block is missing on $external_iface."
    done
    local namespace=flux-system workloads=4
    if [[ "$engine" == argocd ]]; then
        namespace=argocd
        workloads=7
    fi
    kubectl -n "$namespace" get deployment,statefulset -o json |
        jq -e --arg registry "$registry_ip:5000/" --argjson workloads "$workloads" '
            (.items | length) == $workloads and
            all(.items[].spec.template.spec |
                (.containers + (.initContainers // []))[]; .image | startswith($registry))
        ' >/dev/null || die "$engine controllers are not all using the local registry."

    for container in "$CLUSTER_NODE" "$GITEA_CONTAINER" "$REGISTRY_CONTAINER"; do
        docker run --pull=never --rm --network "container:$container" "$CURL_IMAGE" \
            --noproxy '*' --fail --silent --show-error --max-time 5 \
            "http://$registry_ip:5000/v2/" >/dev/null ||
            die "$container cannot reach the local registry; its egress result would be inconclusive."
        if docker run --pull=never --rm --network "container:$container" "$CURL_IMAGE" \
            --noproxy '*' --fail --silent --show-error --max-time 5 \
            --resolve "example.com:443:$external_ip" https://example.com/; then
            die "$container can still reach external HTTPS."
        else
            local exit_code=$?
            [[ "$exit_code" == 7 || "$exit_code" == 28 ]] ||
                die "$container external probe failed for an unexpected reason (curl exit $exit_code)."
        fi
        printf 'PASS: %s reaches the local registry but external IPv4 HTTPS is blocked.\n' "$container"
    done

    # shellcheck disable=SC2016 # Positional parameters belong to the probe container.
    kubectl run external-egress-probe --image="$CURL_IMAGE" --image-pull-policy=Never \
        --restart=Never --command -- sh -ec '
            curl --noproxy "*" --fail --silent --show-error --max-time 5 "$1/v2/" >/dev/null
            if curl --noproxy "*" --fail --silent --show-error --max-time 5 \
                --resolve "example.com:443:$2" https://example.com/; then
                echo "ERROR: external IPv4 HTTPS worked" >&2
                exit 1
            else
                code=$?
                [ "$code" = 7 ] || [ "$code" = 28 ] || exit "$code"
            fi
            if curl --noproxy "*" --fail --silent --show-error --max-time 5 \
                "https://[2606:4700:4700::1111]/"; then
                echo "ERROR: external IPv6 HTTPS worked" >&2
                exit 1
            else
                code=$?
                [ "$code" = 7 ] || [ "$code" = 28 ] || exit "$code"
            fi
            echo "PASS: the Kubernetes pod reaches the registry; external IPv4/IPv6 HTTPS is blocked."
        ' sh "http://$registry_ip:5000" "$external_ip" >/dev/null
    kubectl wait --for=jsonpath='{.status.phase}'=Succeeded pod/external-egress-probe --timeout=90s ||
        { kubectl logs external-egress-probe; die "The pod-level isolation verification failed."; }
    kubectl logs external-egress-probe
    kubectl delete pod external-egress-probe --wait=true >/dev/null
}
