#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"

started=$SECONDS
on_exit() {
  local rc=$?
  trap - EXIT
  if (( rc != 0 )); then
    echo "FAILED (exit $rc). No full demo success claimed; runtime and evidence retained." >&2
    if [[ -d "$STATE" ]] &&
      docker container inspect "$REGISTRY_CONTAINER" >/dev/null 2>&1 &&
      [[ "$(docker inspect "$REGISTRY_CONTAINER" \
        --format '{{index .Config.Labels "io.taking-offline.demo"}}')" == multi-arch-bundle ]]; then
      docker logs --tail 100 "$REGISTRY_CONTAINER" > "$STATE/zot-failure.log" 2>&1 || true
      echo "zot log: $STATE/zot-failure.log" >&2
    fi
  fi
  echo "Total runtime: $((SECONDS - started)) seconds (exit $rc)"
  exit "$rc"
}
trap on_exit EXIT

[[ $# == 0 ]] || die 'Usage: scripts/run-demo.sh'
require docker curl jq clear sleep
[[ "$(uname -s)" == Linux ]] || die 'This demo requires a Linux host.'
[[ "$(docker info --format '{{.OSType}}/{{.Architecture}}')" == linux/x86_64 ]] ||
  die 'The pinned zot image and tested setup require an amd64 Linux Docker engine.'
[[ "${DEMO_SLEEP_SECONDS:-2}" =~ ^[0-9]+([.][0-9]+)?$ ]] ||
  die 'DEMO_SLEEP_SECONDS must be a non-negative number.'

"$ROOT/scripts/cleanup.sh"
mkdir -p "$ARTIFACTS" "$STATE"

echo '=== PHASE 1: CONNECTED ==='
sleep "${DEMO_SLEEP_SECONDS:-2}"
echo "Pulling pinned tooling and the Go build stage; BusyBox is intentionally the official moving stable tag."
docker pull "$ZOT_IMAGE"
docker pull "$SKOPEO_IMAGE"
docker pull "$GO_BUILDER_IMAGE"
docker pull "$BUSYBOX_IMAGE"
docker buildx version | tee "$ARTIFACTS/buildx-version.txt"
docker version --format 'Docker Engine={{.Server.Version}} / Client={{.Client.Version}}' |
  tee "$ARTIFACTS/docker-version.txt"
docker run --rm --entrypoint skopeo "$SKOPEO_IMAGE" --version |
  tee "$ARTIFACTS/skopeo-version.txt"

docker network create --label "$LABEL" "$UPLINK_NETWORK" >/dev/null
docker network create --internal --label "$LABEL" "$INTERNAL_NETWORK" >/dev/null
docker volume create --label "$LABEL" "$REGISTRY_VOLUME" >/dev/null
docker run --detach --name "$REGISTRY_CONTAINER" --label "$LABEL" \
  --network "$UPLINK_NETWORK" --publish "127.0.0.1:$HOST_PORT:5000" \
  --volume "$REGISTRY_VOLUME:/var/lib/zot" \
  --volume "$ROOT/config/zot-config.json:/etc/zot/config.json:ro" \
  "$ZOT_IMAGE" serve /etc/zot/config.json >/dev/null
docker network connect "$INTERNAL_NETWORK" "$REGISTRY_CONTAINER"
wait_for_registry

echo 'Inspecting the upstream BusyBox stable manifest list.'
skopeo_exec --command-timeout=90s inspect --raw "docker://$BUSYBOX_IMAGE" \
  > "$ARTIFACTS/upstream-index.json"
raw_index_sha="$(sha256sum "$ARTIFACTS/upstream-index.json")"
printf 'sha256:%s\n' "${raw_index_sha%% *}" > "$ARTIFACTS/busybox-source-digest.txt"
assert_linux_platforms "$ARTIFACTS/upstream-index.json" 'Upstream BusyBox stable'
jq -r '.mediaType // "media type not declared"' "$ARTIFACTS/upstream-index.json" \
  > "$ARTIFACTS/upstream-index-media-type.txt"

echo 'Copying every architecture from Docker Hub to a portable OCI image layout.'
skopeo_exec --command-timeout=180s copy --multi-arch all \
  "docker://$BUSYBOX_IMAGE" oci:/artifacts/busybox-layout:stable
[[ -s "$ARTIFACTS/busybox-layout/index.json" ]] ||
  die 'Skopeo did not create an OCI layout index.'
cp "$ARTIFACTS/busybox-layout/index.json" "$ARTIFACTS/oci-layout-index.json"

echo 'Starting local zot, importing the OCI index, and publishing the ARM64 app.'
skopeo_exec --command-timeout=180s copy --multi-arch all \
  --dest-tls-verify=false oci:/artifacts/busybox-layout:stable \
  docker://localhost:5000/library/busybox:stable
docker buildx build --builder default --platform linux/arm64 --pull=false --load \
  --label "$LABEL" -t "$APP_IMAGE" -f "$ROOT/apps/arm64-static-web/Dockerfile" \
  "$ROOT/apps/arm64-static-web"
[[ "$(docker image inspect "$APP_IMAGE" --format '{{.Os}}/{{.Architecture}}')" == linux/arm64 ]] ||
  die 'Buildx did not load the custom image as linux/arm64.'
docker push "$APP_IMAGE"

echo 'Fetching each BusyBox architecture and the web app from local zot into Docker.'
docker pull --platform linux/amd64 "$BUSYBOX_LOCAL"
docker tag "$BUSYBOX_LOCAL" "$BUSYBOX_AMD64_LOCAL"
docker pull --platform linux/arm64 "$BUSYBOX_LOCAL"
docker tag "$BUSYBOX_LOCAL" "$BUSYBOX_ARM64_LOCAL"
docker pull --platform linux/arm64 "$APP_IMAGE"

skopeo_exec --command-timeout=60s inspect --tls-verify=false --raw \
  docker://localhost:5000/library/busybox:stable > "$ARTIFACTS/connected-zot-index.json"
assert_linux_platforms "$ARTIFACTS/connected-zot-index.json" 'Connected zot BusyBox'

echo 'Checking ARM64 runtime support while still connected.'
if ! docker run --pull=never --rm --network none --platform linux/arm64 \
  "$BUSYBOX_ARM64_LOCAL" uname -m \
  > "$STATE/qemu-probe.log" 2>&1; then
  echo 'No working ARM64 binfmt handler found; trying the pinned QEMU/binfmt installer.'
  printf 'installed\n' > "$STATE/binfmt-installed-by-demo"
  docker pull "$BINFMT_IMAGE"
  if ! docker run --privileged --rm "$BINFMT_IMAGE" --install arm64; then
    echo '# UNTESTED: privileged binfmt registration is unavailable in this Docker environment.' >&2
    die 'Cannot execute the ARM64 proof without QEMU/binfmt support.'
  fi
fi
qemu_probe="$(docker run --pull=never --rm --network none --platform linux/arm64 \
  "$BUSYBOX_ARM64_LOCAL" uname -m)"
[[ "$qemu_probe" == aarch64 || "$qemu_probe" == arm64 ]] ||
  die "ARM64 emulation returned unexpected architecture: $qemu_probe"
echo "ARM64 preflight: $qemu_probe"

echo
sleep "${DEMO_SLEEP_SECONDS:-2}"
if [[ -t 1 && -n "${TERM:-}" ]]; then clear; else printf '\n'; fi
echo '=== PHASE 2: AIR-GAPPED ==='
sleep "${DEMO_SLEEP_SECONDS:-2}"

docker network disconnect "$UPLINK_NETWORK" "$REGISTRY_CONTAINER"
assert_offline_network
echo "zot is attached only to the internal Docker network: $INTERNAL_NETWORK"

if skopeo_exec --command-timeout=8s inspect --raw "docker://$BUSYBOX_IMAGE" \
  > "$STATE/upstream-probe.log" 2>&1; then
  die 'EGRESS LEAK: Skopeo reached Docker Hub after the uplink was disconnected.'
fi
echo 'Expected blocked upstream request (Skopeo output follows):'
sed -n '1,8p' "$STATE/upstream-probe.log"

skopeo_exec --command-timeout=30s inspect --tls-verify=false --raw \
  docker://localhost:5000/library/busybox:stable > "$ARTIFACTS/offline-zot-index.json"
assert_linux_platforms "$ARTIFACTS/offline-zot-index.json" 'Air-gapped zot BusyBox'

amd64_result="$(docker run --pull=never --rm --network none --platform linux/amd64 \
  "$BUSYBOX_AMD64_LOCAL" uname -m)"
[[ "$amd64_result" == x86_64 ]] || die "Expected the amd64 BusyBox runtime; got $amd64_result."
echo "Offline BusyBox linux/amd64: $amd64_result"

arm64_result="$(docker run --pull=never --rm --network none --platform linux/arm64 \
  "$BUSYBOX_ARM64_LOCAL" uname -m)"
[[ "$arm64_result" == aarch64 || "$arm64_result" == arm64 ]] ||
  die "Expected the arm64 BusyBox runtime; got $arm64_result."
echo "Offline BusyBox linux/arm64: $arm64_result"

docker run --pull=never --rm --network none --platform linux/arm64 \
  "$APP_IMAGE" --self-test |
  tee "$ARTIFACTS/arm64-web-self-test.txt"
grep -Fx 'ARM64 static web server self-test: PASS' \
  "$ARTIFACTS/arm64-web-self-test.txt" >/dev/null ||
  die 'The ARM64 web server self-test did not report its expected HTTP response.'

echo 'PASS: both BusyBox architectures are in the offline zot index; amd64 and emulated arm64 run without container networking.'
echo "Evidence: $ARTIFACTS"
echo "The zot container remains on its internal-only network. Run scripts/cleanup.sh when finished."
