#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../config/versions.env
source "$ROOT/config/versions.env"
TOOLS="$ROOT/.tools"
ARTIFACTS="$ROOT/artifacts"
STATE="$ROOT/.state"
SANDBOX_ROOT=/tmp/work
SLEEP_SECONDS="${DEMO_SLEEP_SECONDS:-2}"
START_SECONDS=$SECONDS
PORT_FORWARD_PID=''

require_command() {
    command -v "$1" >/dev/null 2>&1 || {
        printf 'Required command not found: %s\n' "$1" >&2
        exit 1
    }
}

for command in awk bwrap clear curl docker find grep jq sha256sum sleep tar wc; do
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
        test "$interfaces" = lo
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
    [[ "$found" == true ]] || {
        echo 'No Alpine APK trust keys found in artifacts/apk-repo/keys/alpine.' >&2
        return 1
    }
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

connected_phase() {
    echo '=== PHASE 1: CONNECTED ==='
    echo 'Fetching checksum-pinned tools, runtime inputs, and the signed Alpine Go APK closure.'
    mkdir -p "$ARTIFACTS" "$STATE"
    "$ROOT/scripts/install-tools.sh" | tee "$ARTIFACTS/tools-version.txt"
    docker pull "$ALPINE_IMAGE"
    docker pull "$NGINX_IMAGE"
    docker pull "$ZOT_IMAGE"
    docker pull "$K3S_IMAGE"
    docker pull "$PAUSE_IMAGE"
    if [[ -d "$ARTIFACTS/apk-repo" ]]; then
        docker run --rm \
            --volume "$ARTIFACTS:/artifacts" \
            "$ALPINE_IMAGE" sh -ec '
                rm -rf /artifacts/apk-repo /artifacts/offline-image.tar \
                    /artifacts/footprint.txt \
                    /artifacts/airgap-network-proof.txt /artifacts/docker-network-proof.txt \
                    /artifacts/k3d-node-networks.json /artifacts/port-forward.log \
                    /artifacts/pod-output.txt
            '
    fi

    record_footprint "$NGINX_IMAGE" nginx | tee "$ARTIFACTS/footprint.txt"

    mkdir -p "$ARTIFACTS/apk-repo/downloaded" \
        "$ARTIFACTS/apk-repo/main/x86_64" \
        "$ARTIFACTS/apk-repo/community/x86_64" \
        "$ARTIFACTS/apk-repo/keys/alpine"
    docker run --rm \
        --volume "$ARTIFACTS/apk-repo:/repo" \
        "$ALPINE_IMAGE" sh -ec '
            printf "%s\n" \
                "https://dl-cdn.alpinelinux.org/alpine/v3.22/main" \
                "https://dl-cdn.alpinelinux.org/alpine/v3.22/community" \
                > /tmp/repositories
            apk update --repositories-file /tmp/repositories
            apk fetch --repositories-file /tmp/repositories --recursive \
                --output /repo/downloaded go busybox-binsh busybox musl
            for repository in main community; do
                mkdir -p "/repo/$repository/x86_64"
                wget -q -O "/repo/$repository/x86_64/APKINDEX.tar.gz" \
                    "https://dl-cdn.alpinelinux.org/alpine/v3.22/$repository/x86_64/APKINDEX.tar.gz"
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
        [[ "$internal" == true && "$label" == apko-melange-offline ]] || {
            echo "Refusing to reuse unowned/non-internal network $DOCKER_NETWORK." >&2
            exit 1
        }
    else
        docker network create --internal --label demo=apko-melange-offline \
            "$DOCKER_NETWORK" >/dev/null
    fi

    local gateway
    gateway="$(docker network inspect "$DOCKER_NETWORK" \
        --format '{{(index .IPAM.Config 0).Gateway}}')"
    echo 'External reachability probe from the Docker internal network (failure expected).'
    if docker run --rm --cap-add NET_ADMIN --network "$DOCKER_NETWORK" "$ALPINE_IMAGE" \
        sh -ec 'ip route add default via "$1"; wget -T 3 -qO- http://1.1.1.1/' _ "$gateway"; then
        echo 'ERROR: internal-network container reached an external endpoint.' >&2
        exit 1
    else
        echo 'Expected: external request failed even with a default route to the internal bridge.' |
            tee "$ARTIFACTS/docker-network-proof.txt"
    fi
}

build_package_and_image() {
    mkdir -p "$ARTIFACTS/apk-repo/melange" "$STATE/melange-cache" \
        "$STATE/apk-cache" "$STATE/melange-work" "$STATE/apko-cache"
    append_alpine_keys

    echo 'Building and signing the Go APK in a private network namespace.'
    isolated "$SANDBOX_ROOT/.tools/melange" build "$SANDBOX_ROOT/config/melange.yaml" \
        --arch x86_64 \
        --runner bubblewrap \
        --signing-key "$SANDBOX_ROOT/.state/offline-demo.rsa" \
        --out-dir "$SANDBOX_ROOT/artifacts/apk-repo/melange" \
        --source-dir "$SANDBOX_ROOT/apps/hello" \
        --cache-dir "$SANDBOX_ROOT/.state/melange-cache" \
        --apk-cache-dir "$SANDBOX_ROOT/.state/apk-cache" \
        --workspace-dir "$SANDBOX_ROOT/.state/melange-work" \
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
    isolated "$SANDBOX_ROOT/.tools/apko" build --offline \
        --arch amd64 \
        --cache-dir "$SANDBOX_ROOT/.state/apko-cache" \
        "${keyring_args[@]}" \
        "$SANDBOX_ROOT/config/apko.yaml" \
        "$APKO_TAG" \
        "$SANDBOX_ROOT/artifacts/offline-image.tar"

    docker load --input "$ARTIFACTS/offline-image.tar"
    {
        record_footprint "$NGINX_IMAGE" nginx
        record_footprint "$IMAGE_TAG" apko
    } | tee "$ARTIFACTS/footprint.txt"
}

start_zot() {
    if docker container inspect "$ZOT_CONTAINER" >/dev/null 2>&1; then
        label="$(docker inspect "$ZOT_CONTAINER" --format '{{.Config.Labels.demo}}')"
        [[ "$label" == apko-melange-offline ]] || {
            echo "Refusing to remove unowned container $ZOT_CONTAINER." >&2
            exit 1
        }
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
    if "$TOOLS/k3d" cluster list -o json | jq -e \
        --arg n "$CLUSTER_NAME" 'any(.[]; .name == $n)' >/dev/null; then
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
        echo 'WARNING: using a 1% kubelet disk-pressure threshold for this low-disk demo sandbox.'
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

    local node_ip
    node_ip="$(docker inspect "k3d-${CLUSTER_NAME}-server-0" \
        --format '{{(index .NetworkSettings.Networks "apko-melange-offline").IPAddress}}')"
    [[ -n "$node_ip" ]] || {
        echo 'Could not determine the k3d server address on the internal Docker network.' >&2
        exit 1
    }
    kubectl=("$TOOLS/kubectl" --kubeconfig "$STATE/kubeconfig")
    "${kubectl[@]}" config set-cluster "k3d-$CLUSTER_NAME" \
        --server="https://$node_ip:6443" --tls-server-name=0.0.0.0 >/dev/null
    "${kubectl[@]}" wait --for=condition=Ready node --all --timeout=120s
    docker inspect "k3d-${CLUSTER_NAME}-server-0" \
        --format '{{json .NetworkSettings.Networks}}' > "$ARTIFACTS/k3d-node-networks.json"
    jq -e --arg n "$DOCKER_NETWORK" 'keys == [$n]' \
        "$ARTIFACTS/k3d-node-networks.json" >/dev/null || {
        echo 'The k3d node is attached to an unexpected network.' >&2
        cat "$ARTIFACTS/k3d-node-networks.json" >&2
        exit 1
    }
    [[ "$(docker network inspect "$DOCKER_NETWORK" --format '{{.Internal}}')" == true ]]

    if docker exec "k3d-${CLUSTER_NAME}-server-0" \
        wget -T 3 -qO- http://1.1.1.1/ >/dev/null; then
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
    "$TOOLS/k3d" image import "$PAUSE_IMAGE" --cluster "$CLUSTER_NAME"
    "$TOOLS/k3d" image import "$IMAGE_TAG" --cluster "$CLUSTER_NAME"
    docker exec "$node" ctr --namespace k8s.io images tag "$IMAGE_TAG" "$registry_image"
    docker exec "$node" ctr --namespace k8s.io images push --plain-http "$registry_image"
    curl --fail --silent "http://$ZOT_IP:5000/v2/offline/offline-go-server/tags/list" |
        jq -e --arg tag "${IMAGE_TAG##*:}" '.tags | index($tag) != null' >/dev/null || {
            echo 'The image tag is missing from the local zot registry after push.' >&2
            exit 1
        }
}

cluster_proof() {
    "${kubectl[@]}" create namespace offline-demo --dry-run=client -o yaml |
        "${kubectl[@]}" apply -f -
    "${kubectl[@]}" apply -f "$ROOT/manifests/hello.yaml"
    "${kubectl[@]}" -n offline-demo rollout status \
        deployment/offline-go-server --timeout=120s

    "${kubectl[@]}" -n offline-demo port-forward \
        deployment/offline-go-server 18080:8080 >"$ARTIFACTS/port-forward.log" 2>&1 &
    PORT_FORWARD_PID=$!
    trap 'if [[ -n "$PORT_FORWARD_PID" ]]; then kill "$PORT_FORWARD_PID" 2>/dev/null || true; fi' EXIT
    response=''
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

require_command kubectl
[[ "$(docker info --format '{{.OSType}}/{{.Architecture}}')" == linux/x86_64 ]] || {
    echo 'This demo is pinned to a Linux amd64 Docker engine.' >&2
    exit 1
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
cluster_proof

printf '=== COMPLETE: signed Go APK -> apko image -> local zot -> offline k3d HTTP check (%s seconds) ===\n' \
    "$((SECONDS - START_SECONDS))"
