#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../config/versions.env
source "$ROOT/config/versions.env"
WORK="$ROOT/.work"
FILE_ROOT="$ROOT/.state/files"
FILE_SERVICE_URL="${FILE_SERVICE_URL:-http://192.168.56.1:8080}"
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

stage_release() {
  local version="$1"
  local release="$ROOT/artifacts/kubean/$version"
  local work="$WORK/$version"
  local url path

  [[ -s "$release/files-amd64-$version.tar.gz" ]] || {
    echo "ERROR: missing $version file archive; run prepare-bundle.sh first." >&2
    exit 1
  }
  [[ -s "$release/os-pkgs-$UBUNTU_OS_PACKAGE-$version.tar.gz" ]] || {
    echo "ERROR: missing $version Ubuntu package archive; run prepare-bundle.sh first." >&2
    exit 1
  }

  mkdir -p "$work/files" "$work/images" "$work/os-pkgs"
  tar --strip-components=1 -xzf "$release/files-amd64-$version.tar.gz" -C "$work/files"
  tar --strip-components=1 -xzf "$release/images-amd64-$version.tar.gz" -C "$work/images"
  tar --strip-components=1 -xzf "$release/os-pkgs-$UBUNTU_OS_PACKAGE-$version.tar.gz" -C "$work/os-pkgs"
  (
    cd "$work"
    sha256sum --check "os-pkgs/os-pkgs.sha256sum.txt"
  )

  mkdir -p "$work/files/payload" "$work/os-pkgs/payload"
  tar -xzf "$work/files/offline-files.tar.gz" -C "$work/files/payload"
  tar -xzf "$work/os-pkgs/os-pkgs-amd64.tar.gz" -C "$work/os-pkgs/payload"

  if [[ -d "$work/files/payload/offline-files/files.m.daocloud.io" ]]; then
    cp -a "$work/files/payload/offline-files/files.m.daocloud.io/." \
      "$work/files/payload/offline-files/"
  fi

  mkdir -p "$FILE_ROOT/kubean" "$FILE_ROOT/kubean/ubuntu/$version"
  cp -a "$work/files/payload/offline-files/." "$FILE_ROOT/kubean/"
  chmod 0755 \
    "$FILE_ROOT/kubean/github.com/lework/skopeo-binary/releases/download/v$SKOPEO_IMPORT_VERSION/skopeo-linux-amd64"
  cp -a "$work/os-pkgs/payload/resources/ubuntu/." \
    "$FILE_ROOT/kubean/ubuntu/$version/"
  cp "$FILE_ROOT/kubean/ubuntu/$version/dists/jammy/main/binary-amd64/Packages.gz" \
    "$FILE_ROOT/kubean/ubuntu/$version/Packages.gz"

  while IFS= read -r url; do
    path="${url#*://}"
    [[ -s "$FILE_ROOT/kubean/$path" ]] || {
      echo "ERROR: listed static file is not staged: $version $url" >&2
      exit 1
    }
    curl --fail --silent --show-error --head \
      "$FILE_SERVICE_URL/kubean/$path" >/dev/null
  done < "$release/files-amd64.list"

  curl --fail --silent --show-error --head \
    "$FILE_SERVICE_URL/kubean/ubuntu/$version/Packages.gz" >/dev/null
  printf 'Staged and served %s static files and Ubuntu package index.\n' "$version"
}

require curl sha256sum tar
for version in "$BASE_KUBEAN_VERSION" "$UPGRADE_KUBEAN_VERSION"; do
  stage_release "$version"
done

printf 'Artifact staging runtime: %s seconds\n' "$((SECONDS - START_SECONDS))"
