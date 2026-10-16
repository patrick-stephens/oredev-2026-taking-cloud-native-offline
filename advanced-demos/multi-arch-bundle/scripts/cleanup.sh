#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"

require docker
docker info >/dev/null

if docker container inspect "$REGISTRY_CONTAINER" >/dev/null 2>&1; then
  [[ "$(docker inspect "$REGISTRY_CONTAINER" \
    --format '{{index .Config.Labels "io.taking-offline.demo"}}')" == multi-arch-bundle ]] ||
    die "Refusing to remove unowned container $REGISTRY_CONTAINER."
  docker rm -f "$REGISTRY_CONTAINER"
fi

for network in "$UPLINK_NETWORK" "$INTERNAL_NETWORK"; do
  if docker network inspect "$network" >/dev/null 2>&1; then
    [[ "$(docker network inspect "$network" \
      --format '{{index .Labels "io.taking-offline.demo"}}')" == multi-arch-bundle ]] ||
      die "Refusing to remove unowned network $network."
    docker network rm "$network"
  fi
done

if docker volume inspect "$REGISTRY_VOLUME" >/dev/null 2>&1; then
  [[ "$(docker volume inspect "$REGISTRY_VOLUME" \
    --format '{{index .Labels "io.taking-offline.demo"}}')" == multi-arch-bundle ]] ||
    die "Refusing to remove unowned volume $REGISTRY_VOLUME."
  docker volume rm "$REGISTRY_VOLUME"
fi

if [[ -f "$STATE/binfmt-installed-by-demo" ]]; then
  docker image inspect "$BINFMT_IMAGE" >/dev/null 2>&1 ||
    die "Cannot unregister the demo-installed QEMU handler: $BINFMT_IMAGE is not cached."
  docker run --pull=never --privileged --rm --network none \
    "$BINFMT_IMAGE" --uninstall qemu-aarch64
fi

for image in "$BUSYBOX_AMD64_LOCAL" "$BUSYBOX_ARM64_LOCAL" "$BUSYBOX_LOCAL" "$APP_IMAGE"; do
  if docker image inspect "$image" >/dev/null 2>&1; then
    docker image rm -f "$image"
  fi
done

rm -rf -- "$ARTIFACTS" "$STATE"
echo "Removed this demo's zot runtime, registry volume, evidence, local tags and any QEMU handler it installed."
echo "Pinned tool and base images are left in Docker's cache."
