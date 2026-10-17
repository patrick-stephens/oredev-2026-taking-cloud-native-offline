#!/usr/bin/env bash
# CONNECTED only: ./scripts/connected.sh
# Installs local CLIs, stages init/node assets, packages chart/image/Git/files/SBOM.
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"

wait_for_bootstrap() {
    local attempt node_hosts restarted_at="${1:-}"
    for ((attempt=0; attempt<60; attempt++)); do
        if kube --request-timeout=2s get --raw=/readyz; then break; fi
        sleep 1
    done
    [[ "$attempt" -lt 60 ]] || die "Kubernetes API did not become ready."
    kube wait --for=condition=Ready node/"$NODE" --timeout=90s
    kube -n kube-system wait --for=create deployment/coredns --timeout=60s
    kube -n kube-system wait --for=create deployment/local-path-provisioner --timeout=60s
    if [[ -n "$restarted_at" ]]; then
        # Ready node/pod status can be left over from before the restart.
        # Wait for this boot's addon apply before repairing controller-owned data.
        for ((attempt=0; attempt<60; attempt++)); do
            if kube -n kube-system get events \
                --field-selector involvedObject.name=coredns,reason=AppliedManifest -o json |
                jq -e --arg since "$restarted_at" \
                    'any(.items[]; (.lastTimestamp // .eventTime // "") >= $since)' >/dev/null; then
                break
            fi
            sleep 1
        done
        [[ "$attempt" -lt 60 ]] || die "CoreDNS manifest was not applied after the node restart."
    fi
    for ((attempt=0; attempt<18; attempt++)); do
        node_hosts="$(kube -n kube-system get configmap coredns -o jsonpath='{.data.NodeHosts}')"
        if [[ -z "$node_hosts" ]]; then
            # k3s can reapply CoreDNS after restart without its controller-owned
            # NodeHosts key. A node update asks that controller to rebuild it.
            printf 'RECOVERING: asking k3s to reconcile the missing CoreDNS NodeHosts key.\n'
            kube annotate node "$NODE" "offline-demo/reconcile-node-hosts=$(date +%s)-$attempt" --overwrite
            if ! kube -n kube-system wait --for=jsonpath='{.data.NodeHosts}' \
                configmap/coredns --timeout=5s; then
                continue
            fi
        fi
        if kube -n kube-system rollout status deployment/coredns --timeout=5s; then break; fi
    done
    [[ "$attempt" -lt 18 ]] || die "CoreDNS bootstrap failed after bounded reconciliation."
    kube -n kube-system rollout status deployment/local-path-provisioner --timeout=90s
}

phase "PHASE 1: CONNECTED - stage tools, init package and workload package"
bash "$DEMO_DIR/scripts/install-tools.sh"
require_tools
cd "$DEMO_DIR"
umask 077
if docker container inspect "$NODE" >/dev/null 2>&1; then
    assert_owned
    assert_private_keys_unmounted
fi
if ! docker image inspect "$COSIGN" >/dev/null 2>&1; then
    timeout 120s docker pull --platform linux/amd64 "$COSIGN"
fi
mkdir -p "$KEYS"
chmod 700 "$KEYS"
if [[ ! -e "$KEYS/cosign.key" && ! -e "$KEYS/cosign.pub" && ! -e "$KEYS/password" ]]; then
    head -c 32 /dev/urandom | base64 > "$KEYS/password"
    COSIGN_PASSWORD="$(<"$KEYS/password")" docker run --rm --network none \
        --user "$(id -u):$(id -g)" --env COSIGN_PASSWORD --env HOME=/tmp \
        --mount "type=bind,src=$KEYS,dst=/keys" --workdir /keys \
        "$COSIGN" generate-key-pair
fi
[[ -s "$KEYS/cosign.key" && -s "$KEYS/cosign.pub" && -s "$KEYS/password" ]] ||
    die "Incomplete keys/ identity; restore the original keypair/password instead of rotating trust."
COSIGN_PASSWORD="$(<"$KEYS/password")" docker run --rm --network none \
    --user "$(id -u):$(id -g)" --env COSIGN_PASSWORD --env HOME=/tmp \
    --mount "type=bind,src=$KEYS,dst=/keys,readonly" "$COSIGN" \
    public-key --key /keys/cosign.key > "$STATE/derived.pub"
cmp "$STATE/derived.pub" "$KEYS/cosign.pub" || die "Signing keypair does not match."
if [[ ! -s "$ARTIFACTS/$INIT" ]]; then
    curl -fLsS --retry 3 --max-time 180 \
        "https://github.com/zarf-dev/zarf/releases/download/v0.88.0/$INIT" -o "$ARTIFACTS/$INIT"
fi
curl -fLsS --retry 3 --max-time 30 \
    https://github.com/zarf-dev/zarf/releases/download/v0.88.0/checksums.txt \
    -o "$ARTIFACTS/checksums.txt"
(
    cd "$ARTIFACTS"
    grep " $INIT\$" checksums.txt | sha256sum --check -
)
ZARF_PACKAGE_CREATE_SIGNING_KEY_PASSWORD="$(<"$KEYS/password")" \
    "$TOOLS/zarf" package create "$DEMO_DIR/zarf-config.yaml" --confirm \
    --signing-key "$KEYS/cosign.key" --tlog-upload=false \
    --output "$ARTIFACTS" --cache "$STATE/cache" --no-color
"$TOOLS/zarf" package verify "$ARTIFACTS/$PACKAGE" --key "$KEYS/cosign.pub" --no-color
printf 'SIGNED: package verified with the build-side public key. Enroll this key independently:\n'
sha256sum "$KEYS/cosign.pub"
"$TOOLS/zarf" package inspect sbom "$ARTIFACTS/$PACKAGE" \
    --verify=always --key "$KEYS/cosign.pub" \
    --output "$ARTIFACTS/sbom-connected" --no-color
jq '{name:"ghcr.io/stefanprodan/podinfo:6.15.0",packages:(.artifacts|length)}' \
    "$ARTIFACTS/sbom-connected/podinfo-offline/ghcr.io_stefanprodan_podinfo_6.15.0.json"
"$TOOLS/zarf" tools helm template podinfo podinfo --repo https://stefanprodan.github.io/podinfo \
    --version 6.15.0 --namespace podinfo -f "$DEMO_DIR/config/values.yaml" \
    > "$ARTIFACTS/before-rendered.yaml"

for image in "$NODE_IMAGE" ghcr.io/k3d-io/k3d-tools:5.9.0; do
    if ! platform="$(docker image inspect --format '{{.Os}}/{{.Architecture}}' "$image" 2>/dev/null)"; then
        platform=absent
    fi
    if [[ "$platform" != linux/amd64 ]]; then
        printf 'STAGING: %s for linux/amd64 (cached platform: %s).\n' "$image" "${platform:-absent}"
        timeout 180s docker pull --platform linux/amd64 "$image"
    fi
done
if docker container inspect "$NODE" >/dev/null 2>&1; then
    assert_owned
else
    "$TOOLS/k3d" cluster create "$CLUSTER" --image "$NODE_IMAGE" \
        --servers 1 --agents 0 --no-lb --api-port 127.0.0.1:0 \
        --kubeconfig-update-default=false --kubeconfig-switch-context=false \
        --k3s-arg '--disable=traefik,servicelb,metrics-server@server:0' \
        --k3s-arg '--kubelet-arg=eviction-hard=nodefs.available<2Gi,imagefs.available<2Gi,nodefs.inodesFree<1%,imagefs.inodesFree<1%@server:0' \
        --k3s-arg '--kubelet-arg=image-gc-high-threshold=99@server:0' \
        --k3s-arg '--kubelet-arg=image-gc-low-threshold=98@server:0' \
        --volume "$TOOLS:/work/.tools:ro@server:0" \
        --volume "$DEMO_DIR/config:/work/config:ro@server:0" \
        --volume "$ARTIFACTS:/work/artifacts@server:0" --timeout 120s
    docker inspect --format '{{.Id}}' "$NODE" > "$STATE/node-id"
fi
assert_private_keys_unmounted
"$TOOLS/k3d" kubeconfig get "$CLUSTER" > "$STATE/kubeconfig"
wait_for_bootstrap
kube get node "$NODE" -o json | jq -e \
    '.status.conditions[] | select(.type=="DiskPressure") | .status=="False"' >/dev/null ||
    die "Disk pressure blocks Zarf injection. Free sandbox disk before proceeding."
# The default StorageClass creates helper pods on first PVC use. Their image
# must be pre-staged too; the registry PVC is needed before Zarf's agent exists.
if ! kube get namespace zarf >/dev/null 2>&1; then
    for image in docker.io/rancher/mirrored-library-busybox:1.37.0 docker.io/rancher/mirrored-pause:3.6; do
        if ! docker exec "$NODE" /bin/ctr images ls -q | grep -Fxq "$image"; then
            docker exec "$NODE" /bin/ctr images pull "$image"
        fi
        # An offline node cannot recover these bootstrap images after image GC.
        docker exec "$NODE" /bin/ctr images label "$image" io.cri-containerd.pinned=pinned
    done
    kube apply -f /work/config/before-pod.yaml
    kube -n default describe pod podinfo-before > "$ARTIFACTS/before-describe.txt"
    kube -n default delete pod podinfo-before --wait=true --timeout=60s
    # Close connected-bootstrap HTTP keepalives before declaring the air gap.
    # Cached infrastructure images survive; the application's image is absent.
    docker restart "$NODE" >/dev/null
    restarted_at="$(docker inspect --format '{{.State.StartedAt}}' "$NODE")"
    wait_for_bootstrap "$(date -u -d "$restarted_at" +%Y-%m-%dT%H:%M:%SZ)"
fi
printf 'CONNECTED COMPLETE: both application and init archives are staged locally.\n'
