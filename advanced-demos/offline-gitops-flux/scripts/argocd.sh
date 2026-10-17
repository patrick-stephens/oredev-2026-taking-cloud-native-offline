#!/usr/bin/env bash
set -euo pipefail

stage_argocd() {
    curl --fail --location --silent --show-error --retry 3 --max-time 180 \
        "https://raw.githubusercontent.com/argoproj/argo-cd/v${ARGOCD_VERSION}/manifests/install.yaml" \
        -o "$STATE_DIR/argocd-upstream.yaml"
    printf 'Staging pinned official Redis from Docker Hub instead of the public ECR mirror.\n'
    sed -i 's|image: public.ecr.aws/docker/library/redis:7.2.11-alpine$|image: docker.io/library/redis:7.2.11-alpine|' \
        "$STATE_DIR/argocd-upstream.yaml"
    sed -nE 's/^[[:space:]]*image: ([^[:space:]]+).*$/\1/p' \
        "$STATE_DIR/argocd-upstream.yaml" | sort -u >"$STATE_DIR/argocd-images.txt"
    [[ "$(wc -l <"$STATE_DIR/argocd-images.txt")" -eq 3 ]] ||
        die "Argo CD's pinned installation must contain the expected Argo CD, Dex and Redis images."
    local image local_image
    while IFS= read -r image; do
        [[ "$image" == *:* && "$image" != *:latest ]] ||
            die "Argo CD installation contains an unpinned image: $image"
        docker pull "$image"
        local_image="127.0.0.1:5001/${image#*/}"
        docker tag "$image" "$local_image"
        docker push "$local_image"
    done <"$STATE_DIR/argocd-images.txt"
}

install_argocd() {
    local registry_ip=$1 ssh_url=$2 ssh_key=$3
    local image replacement workload workloads
    cp "$STATE_DIR/argocd-upstream.yaml" "$STATE_DIR/argocd-install.yaml"
    while IFS= read -r image; do
        replacement="$registry_ip:5000/${image#*/}"
        sed -i "s|image: $image$|image: $replacement|" "$STATE_DIR/argocd-install.yaml"
    done <"$STATE_DIR/argocd-images.txt"
    kubectl create namespace argocd
    kubectl apply --server-side -n argocd -f "$STATE_DIR/argocd-install.yaml"
    kubectl -n argocd create secret generic offline-git \
        --from-literal=type=git --from-literal="url=$ssh_url" \
        --from-file="sshPrivateKey=$ssh_key"
    kubectl -n argocd label secret offline-git argocd.argoproj.io/secret-type=repository
    kubectl -n argocd create configmap argocd-ssh-known-hosts-cm \
        --from-file="ssh_known_hosts=$STATE_DIR/home/.ssh/known_hosts" \
        --dry-run=client -o yaml | kubectl apply -n argocd -f -
    workloads="$(kubectl -n argocd get deployment,statefulset -o name)"
    [[ -n "$workloads" ]] || die "Argo CD installation created no controller workloads."
    while IFS= read -r workload; do
        kubectl -n argocd rollout status "$workload" --timeout=5m
    done <<<"$workloads"
    sed "s|__GIT_URL__|$ssh_url|" "$DEMO_DIR/config/argocd/application.yaml" \
        >"$STATE_DIR/argocd-application.yaml"
    kubectl apply -f "$STATE_DIR/argocd-application.yaml"
}

reconcile_argocd() {
    local commit=$1 attempt
    kubectl -n argocd annotate application podinfo argocd.argoproj.io/refresh=hard --overwrite
    for attempt in {1..150}; do
        if kubectl -n argocd get application podinfo -o json |
            jq -e --arg commit "$commit" '
                .status.sync.revision == $commit and .status.sync.status == "Synced" and
                .status.health.status == "Healthy" and
                .status.operationState.phase == "Succeeded" and
                .status.operationState.syncResult.revision == $commit
            ' >/dev/null; then
            return 0
        fi
        sleep 2
    done
    kubectl -n argocd get application podinfo -o yaml
    die "Argo CD did not sync and become Healthy at Git commit $commit after $attempt attempts."
}
