#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../config/versions.env
source "$ROOT/config/versions.env"
ARTIFACTS="$ROOT/artifacts"
RELEASES="$ARTIFACTS/kubean"
START_SECONDS=$SECONDS

require() {
  local tool
  for tool in "$@"; do
    command -v "$tool" >/dev/null || {
      echo "ERROR: missing prerequisite: $tool" >&2
      exit 1
    }
  done
}

download_release_asset() {
  local version="$1"
  local asset="$2"
  local directory="$RELEASES/$version"
  local expected temporary

  expected="$(awk -v asset="$asset" '$2 == asset { print $1; exit }' "$directory/sha256sum.txt")"
  [[ "$expected" =~ ^[[:xdigit:]]{64}$ ]] || {
    echo "ERROR: $asset has no SHA-256 entry in $version/sha256sum.txt" >&2
    exit 1
  }

  temporary="$directory/$asset.partial"
  curl --fail --location --retry 3 --silent --show-error \
    "https://github.com/kubean-io/kubean/releases/download/$version/$asset" \
    --output "$temporary"
  printf '%s  %s\n' "$expected" "$temporary" | sha256sum --check --status || {
    rm -f -- "$temporary"
    echo "ERROR: checksum verification failed: $version/$asset" >&2
    exit 1
  }
  mv -- "$temporary" "$directory/$asset"
}

prepare_kubean_release() {
  local version="$1"
  local directory="$RELEASES/$version"
  local assets
  local expected_kubernetes_version

  mkdir -p "$directory"
  curl --fail --location --retry 3 --silent --show-error \
    "https://github.com/kubean-io/kubean/releases/download/$version/sha256sum.txt" \
    --output "$directory/sha256sum.txt"
  curl --fail --location --retry 3 --silent --show-error \
    "https://raw.githubusercontent.com/kubean-io/kubean/$version/version.yml" \
    --output "$directory/version.yml"

  assets=(
    "localartifactset.cr.yaml"
    "files-amd64.list"
    "files-amd64-$version.tar.gz"
    "images-amd64.list"
    "images-amd64-$version.tar.gz"
    "os-pkgs-$UBUNTU_OS_PACKAGE-$version.tar.gz"
  )
  for asset in "${assets[@]}"; do
    download_release_asset "$version" "$asset"
  done

  if [[ "$version" == "$BASE_KUBEAN_VERSION" ]]; then
    expected_kubernetes_version="$BASE_KUBERNETES_VERSION"
  else
    expected_kubernetes_version="$UPGRADE_KUBERNETES_VERSION"
  fi
  grep -Fx "kubernetes_version: ${expected_kubernetes_version}" "$directory/version.yml" >/dev/null || {
    echo "ERROR: $version default Kubernetes version differs from the configured version." >&2
    exit 1
  }
}

require curl awk sha256sum tar docker find sort xargs
mkdir -p "$RELEASES"

echo "Assembling Kubean release bundles: $BASE_KUBEAN_VERSION and $UPGRADE_KUBEAN_VERSION"
prepare_kubean_release "$BASE_KUBEAN_VERSION"
prepare_kubean_release "$UPGRADE_KUBEAN_VERSION"

echo "Pulling the current stable Apache httpd 2.4 image and pinned local artifact services."
docker pull "$HTTPD_IMAGE"
docker pull "$REGISTRY_IMAGE"
docker pull "$FILES_IMAGE"
docker image save --output "$ARTIFACTS/httpd-offline.tar" "$HTTPD_IMAGE"
docker image save --output "$ARTIFACTS/artifact-services.tar" \
  "$REGISTRY_IMAGE" "$FILES_IMAGE"
docker image inspect "$HTTPD_IMAGE" --format '{{index .RepoDigests 0}}' \
  > "$ARTIFACTS/httpd-image-ref.txt"
grep -Eq '^docker\.io/library/httpd@sha256:[[:xdigit:]]{64}$' \
  "$ARTIFACTS/httpd-image-ref.txt" || {
    echo "ERROR: Docker did not report a digest for $HTTPD_IMAGE" >&2
    exit 1
  }

(
  cd "$ARTIFACTS"
  find kubean -type f -print0
  printf '%s\0' httpd-offline.tar artifact-services.tar httpd-image-ref.txt
) | sort -z | xargs -0 sha256sum > "$ARTIFACTS/SHA256SUMS"

temporary="$ARTIFACTS/kubean-lifecycle-bundles.tar.gz.partial"
tar -czf "$temporary" -C "$ARTIFACTS" \
  kubean httpd-offline.tar artifact-services.tar httpd-image-ref.txt SHA256SUMS
mv -- "$temporary" "$ARTIFACTS/kubean-lifecycle-bundles.tar.gz"

printf 'Bundle: %s\n' "$ARTIFACTS/kubean-lifecycle-bundles.tar.gz"
printf 'Bundle size: %s\n' "$(du -h "$ARTIFACTS/kubean-lifecycle-bundles.tar.gz" | awk '{print $1}')"
printf 'httpd resolved image: %s' "$(cat "$ARTIFACTS/httpd-image-ref.txt")"
printf 'Connected preparation runtime: %s seconds\n' "$((SECONDS - START_SECONDS))"
