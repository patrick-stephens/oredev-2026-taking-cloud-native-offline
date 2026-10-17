#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../config/versions.env
source "$ROOT/config/versions.env"
TOOLS="$ROOT/.tools"
ARTIFACTS="$ROOT/artifacts/apko-melange-offline"
STATE="$ROOT/.state/apko-melange-offline"
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

isolated_from() {
    local working_dir="$1"
    shift
    bwrap --die-with-parent --unshare-net \
        --ro-bind / / \
        --dev-bind /dev /dev \
        --proc /proc \
        --tmpfs /tmp \
        --bind "$ROOT" "$SANDBOX_ROOT" \
        --chdir "$working_dir" \
        "$@"
}

isolated() {
    isolated_from "$SANDBOX_ROOT" "$@"
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

record_footprint() {
    local reference="$1"
    local name="$2"
    local bytes
    bytes="$(docker image inspect "$reference" --format '{{.Size}}')"
    printf '%s_image=%s\n%s_bytes=%s\n' "$name" "$reference" "$name" "$bytes"
    awk -v name="$name" -v size="$bytes" \
        'BEGIN { printf "%s_mib=%.2f\n", name, size / 1048576 }'
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
        echo 'No Alpine APK trust keys found in artifacts/apko-melange-offline/apk-repo/keys/alpine.' >&2
        return 1
    fi
}

connected_phase() {
    echo '=== PHASE 1: CONNECTED ==='
    echo 'Fetching checksum-pinned tools, runtime images, and the signed Alpine Go APK closure.'
    mkdir -p "$STATE"
    rm -rf -- "$ARTIFACTS"
    mkdir -p "$ARTIFACTS"
    "$ROOT/scripts/install-tools.sh" | tee "$ARTIFACTS/tools-version.txt"
    docker pull "$ALPINE_IMAGE"
    docker pull "$NGINX_IMAGE"
    docker pull "$PAUSE_IMAGE"
    docker pull "$ZOT_IMAGE"
    docker pull "$K3S_IMAGE"
    docker pull "$K3D_TOOLS_IMAGE"
    docker pull "$K3D_PROXY_IMAGE"
    mkdir -p "$ARTIFACTS/apk-repo/downloaded" \
        "$ARTIFACTS/apk-repo/main/x86_64" \
        "$ARTIFACTS/apk-repo/community/x86_64" \
        "$ARTIFACTS/apk-repo/keys/alpine"
    docker run --rm \
        --env ALPINE_REPOSITORY="$ALPINE_REPOSITORY" \
        --env ALPINE_BASE="${ALPINE_REPOSITORY%/main}" \
        --volume "$ARTIFACTS/apk-repo:/repo" \
        "$ALPINE_IMAGE" sh -ec '
            printf "%s\n" \
                "$ALPINE_REPOSITORY" \
                "$ALPINE_BASE/community" \
                > /tmp/repositories
            apk update --repositories-file /tmp/repositories
            apk fetch --repositories-file /tmp/repositories --recursive \
                --output /repo/downloaded go busybox-binsh busybox musl
            for repository in main community; do
                mkdir -p "/repo/$repository/x86_64"
                wget -q -O "/repo/$repository/x86_64/APKINDEX.tar.gz" \
                    "$ALPINE_BASE/$repository/x86_64/APKINDEX.tar.gz"
                cp -a /repo/downloaded/. "/repo/$repository/x86_64/"
            done
            cp -a /etc/apk/keys/. /repo/keys/alpine/
            chmod -R a+rwX /repo
            for package in /repo/downloaded/*.apk; do
                basename "$package"
            done | sort > /repo/apk-package-closure.txt
            for package in /repo/downloaded/go-*.apk; do
                basename "$package"
            done > /repo/go-package-version.txt
        '

    [[ -s "$ARTIFACTS/apk-repo/go-package-version.txt" ]] || {
        echo 'The requested Go compiler package was not staged.' >&2
        exit 1
    }
    record_footprint "$NGINX_IMAGE" nginx > "$ARTIFACTS/footprint.txt"
    if [[ ! -f "$STATE/offline-demo.rsa" ]]; then
        "$TOOLS/melange" keygen "$STATE/offline-demo.rsa"
    fi
    chmod 0600 "$STATE/offline-demo.rsa"
    printf 'APK dependency closure (%s packages):\n' \
        "$(wc -l < "$ARTIFACTS/apk-repo/apk-package-closure.txt")"
    cat "$ARTIFACTS/apk-repo/go-package-version.txt"
    cat "$ARTIFACTS/apk-repo/apk-package-closure.txt"
    echo 'Connected acquisition complete; the ephemeral signing key remains local.'
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

    local gateway
    gateway="$(docker network inspect "$DOCKER_NETWORK" \
        --format '{{(index .IPAM.Config 0).Gateway}}')"
    if docker run --rm --cap-add NET_ADMIN --network "$DOCKER_NETWORK" "$ALPINE_IMAGE" \
        sh -ec 'ip route add default via "$1"; wget -T 3 -qO- http://1.1.1.1/' _ "$gateway"; then
        echo 'ERROR: Docker internal-network container reached an external endpoint.' >&2
        exit 1
    else
        echo 'Expected: external request failed even with a default route to the internal bridge.' |
            tee "$ARTIFACTS/docker-network-proof.txt"
    fi
    [[ "$(docker network inspect "$DOCKER_NETWORK" --format '{{.Internal}}')" == true ]]
}

build_package_and_image() {
    mkdir -p "$ARTIFACTS/apk-repo/melange" "$STATE/melange-cache" \
        "$STATE/apk-cache" "$STATE/melange-work" "$STATE/apko-cache"
    append_alpine_keys

    echo 'Building and signing the Go APK in a private network namespace.'
    isolated "$SANDBOX_ROOT/.tools/melange" build "$SANDBOX_ROOT/config/melange.yaml" \
        --arch x86_64 \
        --runner bubblewrap \
        --signing-key "$SANDBOX_ROOT/.state/apko-melange-offline/offline-demo.rsa" \
        --out-dir "$SANDBOX_ROOT/artifacts/apko-melange-offline/apk-repo/melange" \
        --source-dir "$SANDBOX_ROOT/apps/hello" \
        --cache-dir "$SANDBOX_ROOT/.state/apko-melange-offline/melange-cache" \
        --apk-cache-dir "$SANDBOX_ROOT/.state/apko-melange-offline/apk-cache" \
        --workspace-dir "$SANDBOX_ROOT/.state/apko-melange-offline/melange-work" \
        "${keyring_args[@]}"

    test -s "$ARTIFACTS/apk-repo/melange/x86_64/APKINDEX.tar.gz" || {
        echo 'Melange did not produce an x86_64 APK index.' >&2
        exit 1
    }
    find "$ARTIFACTS/apk-repo/melange/x86_64" -maxdepth 1 \
        -name 'offline-go-server-*.apk' -print -quit | grep -q . || {
        echo 'Melange did not produce the offline Go server APK.' >&2
        exit 1
    }

    echo 'Assembling the minimal runtime image with apko --offline.'
    mkdir -p "$STATE/apko-work"
    isolated_from "$SANDBOX_ROOT/.state/apko-melange-offline/apko-work" \
        "$SANDBOX_ROOT/.tools/apko" build --offline \
        --arch amd64 \
        --cache-dir "$SANDBOX_ROOT/.state/apko-melange-offline/apko-cache" \
        "${keyring_args[@]}" \
        "$SANDBOX_ROOT/config/apko.yaml" \
        "$APKO_TAG" \
        "$SANDBOX_ROOT/artifacts/apko-melange-offline/offline-image.tar"
    docker load --input "$ARTIFACTS/offline-image.tar"
    {
        record_footprint "$NGINX_IMAGE" nginx
        record_footprint "$IMAGE_TAG" apko
    } | tee "$ARTIFACTS/footprint.txt"
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
    mkdir -p "$STATE/zot"
    docker run --detach --name "$ZOT_CONTAINER" \
        --label demo=apko-melange-offline \
        --network "$DOCKER_NETWORK" --network-alias zot \
        --volume "$STATE/zot:/var/lib/zot" \
        --volume "$ROOT/config/zot-config.json:/etc/zot/config.json:ro" \
        "$ZOT_IMAGE" serve /etc/zot/config.json >/dev/null

    ZOT_IP="$(docker inspect "$ZOT_CONTAINER" \
        --format '{{(index .NetworkSettings.Networks "apko-melange-offline").IPAddress}}')"
    [[ -n "$ZOT_IP" ]] || {
        echo 'Could not determine zot address on the internal Docker network.' >&2
        exit 1
    }
    for _ in $(seq 1 30); do
        if curl --fail --silent "http://$ZOT_IP:5000/v2/" >/dev/null; then
            return
        fi
        sleep 1
    done
    docker logs "$ZOT_CONTAINER" >&2
    echo "zot did not become ready at its internal address $ZOT_IP:5000." >&2
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
        echo 'WARNING: setting 0.1% kubelet disk-pressure thresholds for this disposable demo cluster.'
        extra_k3s_args+=(--k3s-arg \
            '--kubelet-arg=eviction-hard=nodefs.available<0.1%,imagefs.available<0.1%@server:*')
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
    if docker exec "$node" wget -T 3 -qO- http://1.1.1.1/ >/dev/null; then
        echo 'ERROR: the k3d server reached an external endpoint.' >&2
        exit 1
    else
        echo 'Expected: k3d server has a default route but external egress is blocked.' |
            tee -a "$ARTIFACTS/docker-network-proof.txt"
    fi
}

push_to_zot() {
    local node="k3d-${CLUSTER_NAME}-server-0"
    local registry_image="zot:5000/${IMAGE_TAG#*/}"
    local ctr=(ctr --address /run/k3s/containerd/containerd.sock --namespace k8s.io)
    docker save "$IMAGE_TAG" --output "$ARTIFACTS/local-image.tar"
    docker cp "$ARTIFACTS/local-image.tar" "$node:/tmp/local-image.tar"
    docker exec "$node" "${ctr[@]}" images import /tmp/local-image.tar
    docker exec "$node" "${ctr[@]}" images tag "$IMAGE_TAG" "$registry_image"
    docker exec "$node" "${ctr[@]}" images push --plain-http "$registry_image"
    curl --fail --silent \
        "http://$ZOT_IP:5000/v2/offline/offline-go-server/tags/list" |
        grep -Fq "\"${IMAGE_TAG##*:}\"" || {
            echo 'The image tag is missing from zot after the internal push.' >&2
            exit 1
        }
    docker exec "$node" "${ctr[@]}" images rm "$IMAGE_TAG" "$registry_image"
    docker exec "$node" rm -f /tmp/local-image.tar
}

preload_pause_image() {
    "$TOOLS/k3d" image import "$PAUSE_IMAGE_TAG" --cluster "$CLUSTER_NAME"
}

deploy_and_verify() {
    "${kubectl[@]}" create namespace offline-demo --dry-run=client -o yaml |
        "${kubectl[@]}" apply -f -
    "${kubectl[@]}" apply -f "$ROOT/manifests/hello.yaml"
    "${kubectl[@]}" -n offline-demo rollout status \
        deployment/offline-go-server --timeout=120s

    "${kubectl[@]}" -n offline-demo port-forward \
        deployment/offline-go-server 18080:8080 >"$ARTIFACTS/port-forward.log" 2>&1 &
    PORT_FORWARD_PID=$!
    trap 'if [[ -n "$PORT_FORWARD_PID" ]]; then kill "$PORT_FORWARD_PID" 2>/dev/null || true; fi' EXIT
    local response=''
    for _ in $(seq 1 30); do
        if response="$(curl --fail --silent http://127.0.0.1:18080/ 2>/dev/null)"; then
            break
        fi
        sleep 1
    done
    [[ "$response" == *'"message":"hello from a static Go binary in an apko image"'* ]] || {
        echo "Unexpected Go server response: ${response:-<no response>}" >&2
        cat "$ARTIFACTS/port-forward.log" >&2
        exit 1
    }
    printf '%s\n' "$response" | tee "$ARTIFACTS/pod-output.txt"
    kill "$PORT_FORWARD_PID" 2>/dev/null || true
    PORT_FORWARD_PID=''
    trap - EXIT
}

connected_phase
pause_for_narration

clear_between_phases
echo '=== PHASE 2: AIR-GAPPED ==='
echo 'Melange and apko have no network interface; zot and k3d use an internal-only Docker network.'
airgap_check
create_internal_network
build_package_and_image
start_zot
start_cluster
push_to_zot
preload_pause_image
deploy_and_verify

{
    record_footprint "$NGINX_IMAGE" nginx
    record_footprint "$IMAGE_TAG" apko
} | tee "$ARTIFACTS/footprint.txt"
printf '=== COMPLETE: signed Go APK -> apko image -> local zot -> offline k3d HTTP check (%s seconds) ===\n' \
    "$((SECONDS - START_SECONDS))"
