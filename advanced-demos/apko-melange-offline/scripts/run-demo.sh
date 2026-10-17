#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../config/versions.env
source "$ROOT/config/versions.env"
TOOLS="$ROOT/.tools"
ARTIFACTS="$ROOT/artifacts/offline-greeter"
STATE="$ROOT/.state/offline-greeter"
SANDBOX_ROOT=/tmp/work
SLEEP_SECONDS="${DEMO_SLEEP_SECONDS:-2}"
START_SECONDS=$SECONDS

require_command() {
    if ! command -v "$1" >/dev/null 2>&1; then
        printf 'Required command not found: %s\n' "$1" >&2
        exit 1
    fi
}

for command in awk bwrap clear curl docker find grep seq sha256sum sleep tar wc; do
    require_command "$command"
done

pause_for_narration() {
    sleep "$SLEEP_SECONDS"
}

clear_between_phases() {
    if [[ -t 1 ]]; then
        clear
    fi
}

isolated() {
    bwrap --die-with-parent --unshare-net \
        --ro-bind / / \
        --dev-bind /dev /dev \
        --proc /proc \
        --tmpfs /tmp \
        --bind "$ROOT" "$SANDBOX_ROOT" \
        --chdir "$SANDBOX_ROOT" \
        "$@"
}

airgap_check() {
    isolated /bin/sh -ec '
        interfaces="$(awk -F: "NR > 2 { gsub(/[[:space:]]/, \"\", \$1); print \$1 }" /proc/net/dev)"
        test "$interfaces" = "lo"
        if curl --connect-timeout 2 --max-time 3 -fsS http://1.1.1.1/ >/dev/null 2>&1; then
            echo "ERROR: direct-IP internet probe unexpectedly succeeded" >&2
            exit 1
        fi
        printf "Network namespace interfaces: %s; direct-IP egress: blocked\\n" "$interfaces"
    ' | tee "$ARTIFACTS/airgap-network-proof.txt"
}

keyring_args=()
append_alpine_keys() {
    local key
    local found=false
    for key in "$ARTIFACTS"/apk-repo/keys/alpine/*.rsa.pub; do
        [[ -f "$key" ]] || continue
        keyring_args+=(--keyring-append "$SANDBOX_ROOT/${key#"$ROOT"/}")
        found=true
    done
    if [[ "$found" != true ]]; then
        echo 'No Alpine APK trust keys found in artifacts/offline-greeter/apk-repo/keys/alpine.' >&2
        return 1
    fi
}

connected_phase() {
    echo '=== PHASE 1: CONNECTED ==='
    echo 'Fetching checksum-pinned tools, runtime images, and the signed Alpine APK closure.'
    mkdir -p "$ARTIFACTS" "$STATE"
    "$ROOT/scripts/install-tools.sh" | tee "$ARTIFACTS/tools-version.txt"
    docker pull "$ALPINE_IMAGE"
    docker pull "$PAUSE_IMAGE"
    docker pull "$ZOT_IMAGE"
    docker pull "$K3S_IMAGE"

    docker run --rm --volume "$ROOT/artifacts:/artifacts" "$ALPINE_IMAGE" \
        sh -ec 'rm -rf /artifacts/offline-greeter'
    mkdir -p "$ARTIFACTS"
    mkdir -p "$ARTIFACTS/apk-repo/alpine/x86_64" \
        "$ARTIFACTS/apk-repo/keys/alpine"
    docker run --rm \
        --env LOCAL_UID="$(id -u)" \
        --env LOCAL_GID="$(id -g)" \
        --env ALPINE_REPOSITORY="$ALPINE_REPOSITORY" \
        --volume "$ARTIFACTS/apk-repo:/repo" \
        "$ALPINE_IMAGE" sh -ec '
            printf "%s\n" "$ALPINE_REPOSITORY" > /tmp/repositories
            apk update --repositories-file /tmp/repositories
            apk fetch --repositories-file /tmp/repositories --recursive \
                --output /repo/alpine/x86_64 busybox-binsh
            set -- /var/cache/apk/APKINDEX.*.tar.gz
            test "$#" -eq 1
            cp "$1" /repo/alpine/x86_64/APKINDEX.tar.gz
            cp -a /etc/apk/keys/. /repo/keys/alpine/
            chown -R "$LOCAL_UID:$LOCAL_GID" /repo
        '

    if [[ ! -f "$STATE/offline-demo.rsa" ]]; then
        "$TOOLS/melange" keygen "$STATE/offline-demo.rsa"
    fi
    chmod 0600 "$STATE/offline-demo.rsa"
    printf 'Staged Alpine APKs: %s\n' \
        "$(find "$ARTIFACTS/apk-repo/alpine" -maxdepth 2 -name '*.apk' -type f | wc -l)"
    printf 'Alpine trust keys: %s\n' \
        "$(find "$ARTIFACTS/apk-repo/keys/alpine" -maxdepth 1 -name '*.rsa.pub' -type f | wc -l)"
    echo 'The generated signing key is local, ignored by Git, and not part of the package repository.'
}

create_internal_network() {
    if docker network inspect "$DOCKER_NETWORK" >/dev/null 2>&1; then
        internal="$(docker network inspect "$DOCKER_NETWORK" --format '{{.Internal}}')"
        label="$(docker network inspect "$DOCKER_NETWORK" --format '{{.Labels.demo}}')"
        if [[ "$internal" != true || "$label" != apko-melange-offline ]]; then
            echo "Refusing to reuse unowned or non-internal network $DOCKER_NETWORK." >&2
            exit 1
        fi
    else
        docker network create --internal --label demo=apko-melange-offline \
            "$DOCKER_NETWORK" >/dev/null
    fi

    if docker run --rm --network "$DOCKER_NETWORK" "$ALPINE_IMAGE" \
        sh -ec 'wget -T 3 -qO- http://1.1.1.1/'; then
        echo 'ERROR: Docker internal-network container reached an external endpoint.' >&2
        exit 1
    else
        echo 'Expected: external request from the Docker internal network failed.' |
            tee "$ARTIFACTS/docker-network-proof.txt"
    fi
    [[ "$(docker network inspect "$DOCKER_NETWORK" --format '{{.Internal}}')" == true ]]
}

build_package_and_image() {
    mkdir -p "$ARTIFACTS/apk-repo/melange" "$STATE/melange-cache" \
        "$STATE/apk-cache" "$STATE/melange-work" "$STATE/apko-cache"
    append_alpine_keys

    echo 'Building and signing the APK in a private network namespace.'
    isolated "$SANDBOX_ROOT/.tools/melange" build "$SANDBOX_ROOT/config/melange.yaml" \
        --arch x86_64 \
        --runner bubblewrap \
        --signing-key "$SANDBOX_ROOT/.state/offline-greeter/offline-demo.rsa" \
        --out-dir "$SANDBOX_ROOT/artifacts/offline-greeter/apk-repo/melange" \
        --cache-dir "$SANDBOX_ROOT/.state/offline-greeter/melange-cache" \
        --apk-cache-dir "$SANDBOX_ROOT/.state/offline-greeter/apk-cache" \
        --workspace-dir "$SANDBOX_ROOT/.state/offline-greeter/melange-work" \
        "${keyring_args[@]}"

    test -s "$ARTIFACTS/apk-repo/melange/x86_64/APKINDEX.tar.gz" || {
        echo 'Melange did not produce an x86_64 APK index.' >&2
        exit 1
    }
    find "$ARTIFACTS/apk-repo/melange/x86_64" -maxdepth 1 \
        -name 'offline-greeter-*.apk' -print -quit | grep -q . || {
        echo 'Melange did not produce the offline greeter APK.' >&2
        exit 1
    }

    echo 'Assembling the image with apko --offline.'
    isolated "$SANDBOX_ROOT/.tools/apko" build --offline \
        --arch amd64 \
        --cache-dir "$SANDBOX_ROOT/.state/offline-greeter/apko-cache" \
        "${keyring_args[@]}" \
        "$SANDBOX_ROOT/config/apko.yaml" \
        "$IMAGE_TAG" \
        "$SANDBOX_ROOT/artifacts/offline-greeter/offline-image.tar"
    docker load --input "$ARTIFACTS/offline-image.tar"
}

start_zot() {
    if docker container inspect "$ZOT_CONTAINER" >/dev/null 2>&1; then
        label="$(docker container inspect "$ZOT_CONTAINER" --format '{{.Config.Labels.demo}}')"
        if [[ "$label" != apko-melange-offline ]]; then
            echo "Refusing to remove unowned container $ZOT_CONTAINER." >&2
            exit 1
        fi
        docker rm --force "$ZOT_CONTAINER" >/dev/null
    fi
    docker run --detach --name "$ZOT_CONTAINER" \
        --label demo=apko-melange-offline \
        --network "$DOCKER_NETWORK" --network-alias zot \
        --volume "$ROOT/config/zot-config.json:/etc/zot/config.json:ro" \
        "$ZOT_IMAGE" serve /etc/zot/config.json >/dev/null

    for _ in $(seq 1 30); do
        if docker run --rm --network "$DOCKER_NETWORK" "$ALPINE_IMAGE" \
            wget -T 2 -qO- http://zot:5000/v2/ >/dev/null; then
            return
        fi
        sleep 1
    done
    docker logs "$ZOT_CONTAINER" >&2
    echo 'zot did not become ready on the internal Docker network.' >&2
    exit 1
}

start_cluster() {
    if "$TOOLS/k3d" cluster list --no-headers | awk -v name="$CLUSTER_NAME" \
        '$1 == name { found=1 } END { exit !found }'; then
        local existing_node="k3d-${CLUSTER_NAME}-server-0"
        local existing_cluster
        existing_cluster="$(docker inspect "$existing_node" \
            --format '{{index .Config.Labels "k3d.cluster"}}' 2>/dev/null || true)"
        if [[ "$existing_cluster" != "$CLUSTER_NAME" ]]; then
            printf 'Refusing to delete cluster %s without its expected k3d ownership label.\n' \
                "$CLUSTER_NAME" >&2
            exit 1
        fi
        "$TOOLS/k3d" cluster delete "$CLUSTER_NAME"
    fi
    local gateway
    gateway="$(docker network inspect "$DOCKER_NETWORK" \
        --format '{{(index .IPAM.Config 0).Gateway}}')"
    printf '#!/bin/sh\nip route add default via %s\n' "$gateway" \
        > "$STATE/k3d-default-route.sh"
    chmod 0755 "$STATE/k3d-default-route.sh"
    local extra_k3s_args=()
    if [[ "${DEMO_RELAX_DISK_EVICTION:-false}" == true ]]; then
        echo 'WARNING: setting 1% kubelet disk-pressure thresholds for this disposable demo cluster.'
        extra_k3s_args+=(--k3s-arg \
            '--kubelet-arg=eviction-hard=nodefs.available<1%,imagefs.available<1%@server:*')
    fi
    "$TOOLS/k3d" cluster create "$CLUSTER_NAME" \
        --image "$K3S_IMAGE" \
        --network "$DOCKER_NETWORK" \
        --volume "$STATE/k3d-default-route.sh:/bin/k3d-entrypoint-00-default-route.sh@server:*" \
        --registry-config "$ROOT/config/registries.yaml" \
        --k3s-arg '--disable=traefik,servicelb,local-storage@server:*' \
        "${extra_k3s_args[@]}" \
        --wait --timeout 180s
    "$TOOLS/k3d" kubeconfig get "$CLUSTER_NAME" > "$STATE/kubeconfig"

    local node="k3d-${CLUSTER_NAME}-server-0"
    local node_ip
    local node_networks
    node_ip="$(docker inspect "$node" \
        --format '{{(index .NetworkSettings.Networks "apko-melange-offline").IPAddress}}')"
    [[ -n "$node_ip" ]] || {
        echo 'Could not determine k3d server IP on the internal Docker network.' >&2
        exit 1
    }
    "$TOOLS/kubectl" --kubeconfig "$STATE/kubeconfig" \
        config set-cluster "k3d-$CLUSTER_NAME" \
        --server="https://$node_ip:6443" --tls-server-name=0.0.0.0 >/dev/null
    node_networks="$(docker inspect "$node" \
        --format '{{range $name, $network := .NetworkSettings.Networks}}{{$name}} {{end}}')"
    if [[ "${node_networks// /}" != "$DOCKER_NETWORK" ]]; then
        printf 'Unexpected k3d node networks: %s\n' "$node_networks" >&2
        exit 1
    fi
    [[ "$(docker network inspect "$DOCKER_NETWORK" --format '{{.Internal}}')" == true ]]

    kubectl=("$TOOLS/kubectl" --kubeconfig "$STATE/kubeconfig")
    "${kubectl[@]}" wait --for=condition=Ready node --all --timeout=120s
}

push_to_zot() {
    local node="k3d-${CLUSTER_NAME}-server-0"
    local ctr=(ctr --address /run/k3s/containerd/containerd.sock --namespace k8s.io)
    docker save "$IMAGE_TAG" --output "$ARTIFACTS/local-image.tar"
    docker cp "$ARTIFACTS/local-image.tar" "$node:/tmp/local-image.tar"
    docker exec "$node" "${ctr[@]}" images import /tmp/local-image.tar
    docker exec "$node" "${ctr[@]}" images tag \
        "docker.io/library/$IMAGE_TAG" "$REGISTRY_IMAGE"
    docker exec "$node" "${ctr[@]}" images push --plain-http "$REGISTRY_IMAGE"
    docker run --rm --network "$DOCKER_NETWORK" "$ALPINE_IMAGE" sh -ec \
        'wget -qO- http://zot:5000/v2/offline/offline-greeter/tags/list | grep -q "\"demo\""'
    docker exec "$node" "${ctr[@]}" images rm \
        "docker.io/library/$IMAGE_TAG" "$REGISTRY_IMAGE"
    docker exec "$node" rm -f /tmp/local-image.tar
}

preload_pause_image() {
    local node="k3d-${CLUSTER_NAME}-server-0"
    local ctr=(ctr --address /run/k3s/containerd/containerd.sock --namespace k8s.io)
    docker tag "$PAUSE_IMAGE" "$PAUSE_IMAGE_TAG"
    docker save "$PAUSE_IMAGE_TAG" --output "$ARTIFACTS/pause-image.tar"
    docker cp "$ARTIFACTS/pause-image.tar" "$node:/tmp/pause-image.tar"
    docker exec "$node" "${ctr[@]}" images import /tmp/pause-image.tar
    docker exec "$node" "${ctr[@]}" images list |
        grep -F 'docker.io/rancher/mirrored-pause:3.6' >/dev/null
    docker exec "$node" rm -f /tmp/pause-image.tar
}

deploy_and_verify() {
    kubectl=("$TOOLS/kubectl" --kubeconfig "$STATE/kubeconfig")
    "${kubectl[@]}" run offline-greeter \
        --image="$REGISTRY_IMAGE" --image-pull-policy=Always --restart=Never
    "${kubectl[@]}" wait --for=jsonpath='{.status.phase}'=Succeeded \
        pod/offline-greeter --timeout=120s
    "${kubectl[@]}" logs pod/offline-greeter | tee "$ARTIFACTS/pod-output.txt"
    grep -Fx 'hello from an APK built and assembled with no network' \
        "$ARTIFACTS/pod-output.txt"
}

connected_phase
pause_for_narration

clear_between_phases
echo '=== PHASE 2: AIR-GAPPED ==='
echo 'Internet access is removed from the build namespace and Docker internal network.'
airgap_check
create_internal_network
build_package_and_image
start_zot
start_cluster
push_to_zot
preload_pause_image
deploy_and_verify

printf 'Docker network %s: Internal=%s\n' "$DOCKER_NETWORK" \
    "$(docker network inspect "$DOCKER_NETWORK" --format '{{.Internal}}')"
printf '=== COMPLETE: signed APK -> apko image -> zot -> offline k3d pod (%s seconds) ===\n' \
    "$((SECONDS - START_SECONDS))"
