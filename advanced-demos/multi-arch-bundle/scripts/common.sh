#!/usr/bin/env bash
# shellcheck disable=SC2034
set -euo pipefail

# Shared values are consumed by run-demo.sh and cleanup.sh.
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
ARTIFACTS="$ROOT/artifacts"
STATE="$ROOT/.state"
# shellcheck disable=SC1091
source "$ROOT/config/versions.env"

LABEL='io.taking-offline.demo=multi-arch-bundle'
REGISTRY_CONTAINER='multi-arch-bundle-zot'
UPLINK_NETWORK='multi-arch-bundle-uplink'
INTERNAL_NETWORK='multi-arch-bundle-internal'
REGISTRY_VOLUME='multi-arch-bundle-zot-data'
HOST_PORT='5055'
LOCAL_REGISTRY="localhost:$HOST_PORT"
BUSYBOX_LOCAL="$LOCAL_REGISTRY/library/busybox:stable"
BUSYBOX_AMD64_LOCAL="$LOCAL_REGISTRY/multi-arch-bundle/busybox:amd64"
BUSYBOX_ARM64_LOCAL="$LOCAL_REGISTRY/multi-arch-bundle/busybox:arm64"
APP_IMAGE="$LOCAL_REGISTRY/multi-arch-bundle/arm64-web:demo"

die() {
  echo "ERROR: $*" >&2
  exit 1
}

require() {
  local tool
  for tool in "$@"; do
    command -v "$tool" >/dev/null || die "Missing prerequisite: $tool"
  done
}

skopeo_exec() {
  docker run --pull=never --rm --network "container:$REGISTRY_CONTAINER" \
    --user "$(id -u):$(id -g)" \
    --volume "$ARTIFACTS:/artifacts" --entrypoint skopeo "$SKOPEO_IMAGE" "$@"
}

wait_for_registry() {
  local attempt
  for ((attempt = 1; attempt <= 60; attempt += 1)); do
    [[ "$(docker inspect "$REGISTRY_CONTAINER" --format '{{.State.Running}}')" == true ]] ||
      {
        docker logs --tail 80 "$REGISTRY_CONTAINER" >&2 || true
        die 'zot exited before its API became ready.'
      }
    if curl --fail --silent --show-error "http://127.0.0.1:$HOST_PORT/v2/" >/dev/null 2>&1; then
      echo "READY: local zot on 127.0.0.1:$HOST_PORT"
      return
    fi
    sleep 1
  done
  docker logs --tail 80 "$REGISTRY_CONTAINER" >&2 || true
  die 'zot did not become ready within 60 seconds.'
}

assert_offline_network() {
  local networks
  [[ "$(docker network inspect "$INTERNAL_NETWORK" --format '{{.Internal}}')" == true ]] ||
    die 'The demo network is not internal.'
  networks="$(docker inspect "$REGISTRY_CONTAINER" --format '{{json .NetworkSettings.Networks}}')"
  jq -e --arg network "$INTERNAL_NETWORK" \
    'keys == [$network]' <<<"$networks" >/dev/null ||
    die "zot is not isolated to $INTERNAL_NETWORK: $networks"
}

assert_linux_platforms() {
  local index_file="$1" label="$2" arch
  [[ -s "$index_file" ]] || die "$label index is empty: $index_file"
  for arch in amd64 arm64; do
    jq -e --arg arch "$arch" \
      'any(.manifests[]?; .platform.os == "linux" and .platform.architecture == $arch)' \
      "$index_file" >/dev/null ||
      die "$label manifest index is missing linux/$arch."
  done
  echo "$label linux/amd64 and linux/arm64 descriptors:"
  jq -r '.manifests[]?
    | select(.platform.os == "linux" and
      (.platform.architecture == "amd64" or .platform.architecture == "arm64"))
    | "  linux/\(.platform.architecture) \(.digest)"' "$index_file"
}
