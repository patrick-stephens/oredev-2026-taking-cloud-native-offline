#!/usr/bin/env bash
# CONNECTED only: ./scripts/connected.sh
# Installs local CLIs, stages init/node assets, packages chart/image/Git/files/SBOM.
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
phase "PHASE 1: CONNECTED - stage tools, init package and workload package"
bash "$DEMO_DIR/scripts/install-tools.sh"
require_tools
cd "$DEMO_DIR"
umask 077
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
"$TOOLS/zarf" package create "$DEMO_DIR/zarf-config.yaml" --confirm \
    --output "$ARTIFACTS" --cache "$STATE/cache" --no-color
"$TOOLS/zarf" package inspect sbom "$ARTIFACTS/$PACKAGE" \
    --output "$ARTIFACTS/sbom-connected" --no-color
jq '{name:"ghcr.io/stefanprodan/podinfo:6.15.0",packages:(.artifacts|length)}' \
    "$ARTIFACTS/sbom-connected/podinfo-offline/ghcr.io_stefanprodan_podinfo_6.15.0.json"
"$TOOLS/zarf" tools helm template podinfo podinfo --repo https://stefanprodan.github.io/podinfo \
    --version 6.15.0 --namespace podinfo -f "$DEMO_DIR/config/values.yaml" \
    > "$ARTIFACTS/before-rendered.yaml"

for image in "$NODE_IMAGE" ghcr.io/k3d-io/k3d-tools:5.9.0; do
    if ! docker image inspect "$image" >/dev/null 2>&1; then timeout 180s docker pull "$image"; fi
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
        --volume "$DEMO_DIR:/work@server:0" --timeout 120s
    docker inspect --format '{{.Id}}' "$NODE" > "$STATE/node-id"
fi
"$TOOLS/k3d" kubeconfig get "$CLUSTER" > "$STATE/kubeconfig"
kube wait --for=condition=Ready node/"$NODE" --timeout=90s
kube -n kube-system wait --for=create deployment/coredns --timeout=60s
kube -n kube-system wait --for=create deployment/local-path-provisioner --timeout=60s
kube -n kube-system rollout status deployment/coredns --timeout=90s
kube -n kube-system rollout status deployment/local-path-provisioner --timeout=90s
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
    for ((attempt=0; attempt<60; attempt++)); do
        if kube get node "$NODE" >/dev/null 2>&1; then break; fi
        sleep 1
    done
    kube wait --for=condition=Ready node/"$NODE" --timeout=90s
    kube -n kube-system rollout status deployment/coredns --timeout=90s
    kube -n kube-system rollout status deployment/local-path-provisioner --timeout=90s
fi
printf 'CONNECTED COMPLETE: both application and init archives are staged locally.\n'
