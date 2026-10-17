#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../config/versions.env
source "$ROOT/config/versions.env"
REGISTRY_ADDR="${REGISTRY_ADDR:-192.168.56.1:5000}"
TOOL_IMAGE="${PODMAN_IMPORT_IMAGE:-quay.io/podman/stable:v$PODMAN_IMPORT_VERSION}"
SKOPEO_BINARY="$ROOT/.state/files/kubean/github.com/lework/skopeo-binary/releases/download/v$SKOPEO_IMPORT_VERSION/skopeo-linux-amd64"
START_SECONDS=$SECONDS

command -v docker >/dev/null || {
  echo "ERROR: missing prerequisite: docker" >&2
  exit 1
}
command -v curl >/dev/null || {
  echo "ERROR: missing prerequisite: curl" >&2
  exit 1
}
docker image inspect "$TOOL_IMAGE" >/dev/null 2>&1 || {
  echo "ERROR: import toolbox image $TOOL_IMAGE is not cached; pull it during CONNECTED." >&2
  exit 1
}

for version in "$BASE_KUBEAN_VERSION" "$UPGRADE_KUBEAN_VERSION"; do
  [[ -s "$ROOT/.work/$version/images/offline-images.tar.gz" ]] || {
    echo "ERROR: missing extracted image archive for $version; run stage-artifacts.sh first." >&2
    exit 1
  }
  [[ -s "$ROOT/.work/$version/images/import_images.sh" ]] || {
    echo "ERROR: missing upstream import_images.sh for $version." >&2
    exit 1
  }
done
[[ -s "$ROOT/artifacts/httpd-offline.tar" && -s "$ROOT/artifacts/busybox-offline.tar" ]] || {
  echo "ERROR: missing workload/probe image archives; run prepare-bundle.sh first." >&2
  exit 1
}
[[ -x "$SKOPEO_BINARY" ]] || {
  echo "ERROR: missing bundled Skopeo $SKOPEO_IMPORT_VERSION; run stage-artifacts.sh first." >&2
  exit 1
}

docker run --rm --privileged --network host \
  -e EXPECTED_PODMAN_VERSION="$PODMAN_IMPORT_VERSION" \
  -e EXPECTED_SKOPEO_VERSION="$SKOPEO_IMPORT_VERSION" \
  -e REGISTRY_ADDR="$REGISTRY_ADDR" \
  -e BASE_KUBEAN_VERSION="$BASE_KUBEAN_VERSION" \
  -e UPGRADE_KUBEAN_VERSION="$UPGRADE_KUBEAN_VERSION" \
  -v "$ROOT/.work/$BASE_KUBEAN_VERSION/images:/input/$BASE_KUBEAN_VERSION:ro" \
  -v "$ROOT/.work/$UPGRADE_KUBEAN_VERSION/images:/input/$UPGRADE_KUBEAN_VERSION:ro" \
  -v "$ROOT/artifacts/httpd-offline.tar:/input/httpd-offline.tar:ro" \
  -v "$ROOT/artifacts/busybox-offline.tar:/input/busybox-offline.tar:ro" \
  -v "$SKOPEO_BINARY:/usr/local/bin/skopeo:ro" \
  "$TOOL_IMAGE" sh -ec '
    test "$(podman --version | awk "{print \$3}")" = "$EXPECTED_PODMAN_VERSION"
    test "$(skopeo --version | awk "{print \$3}")" = "$EXPECTED_SKOPEO_VERSION"
    printf "Image importer tools: Podman %s, Skopeo %s\n" "$EXPECTED_PODMAN_VERSION" "$EXPECTED_SKOPEO_VERSION"

    for version in "$BASE_KUBEAN_VERSION" "$UPGRADE_KUBEAN_VERSION"; do
      work="/work/$version"
      mkdir -p "$work"
      cp "/input/$version/import_images.sh" "$work/import_images.sh"
      ln -s "/input/$version/offline-images.tar.gz" "$work/offline-images.tar.gz"
      (
        cd "$work"
        TARGET_ARCH=amd64 REGISTRY_SCHEME=http REGISTRY_ADDR="$REGISTRY_ADDR" \
          bash ./import_images.sh
        if [ -s copy_image_failed.list ]; then
          cat copy_image_failed.list >&2
          exit 1
        fi
      )
    done

    skopeo --insecure-policy copy --dest-tls-verify=false \
      docker-archive:/input/httpd-offline.tar \
      "docker://$REGISTRY_ADDR/library/httpd:2.4"
    skopeo --insecure-policy copy --dest-tls-verify=false \
      docker-archive:/input/busybox-offline.tar \
      "docker://$REGISTRY_ADDR/library/busybox:1.37.0"
  '

for version in "$BASE_KUBEAN_VERSION" "$UPGRADE_KUBEAN_VERSION"; do
  while IFS= read -r image; do
    name="${image%:*}"
    tag="${image##*:}"
    curl --fail --silent --show-error \
      -H 'Accept: application/vnd.oci.image.index.v1+json, application/vnd.docker.distribution.manifest.list.v2+json, application/vnd.docker.distribution.manifest.v2+json' \
      "http://$REGISTRY_ADDR/v2/$name/manifests/$tag" -o /dev/null
  done < "$ROOT/artifacts/kubean/$version/images-amd64.list"
done
curl --fail --silent --show-error \
  "http://$REGISTRY_ADDR/v2/library/httpd/manifests/2.4" -o /dev/null
curl --fail --silent --show-error \
  "http://$REGISTRY_ADDR/v2/library/busybox/manifests/1.37.0" -o /dev/null

printf 'Imported and verified Kubean images and demo images in %s seconds.\n' \
  "$((SECONDS - START_SECONDS))"
