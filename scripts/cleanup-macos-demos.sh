#!/usr/bin/env bash
set -euo pipefail

[[ "$(uname -s)" == Darwin ]] || exit 0

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
docker info >/dev/null

printf 'Cleaning resources owned by the three supported macOS demos.\n'
bash "$ROOT/live-demos/1-pull-through-cache-zot/scripts/stop-cache.sh"

if [[ -s "$ROOT/live-demos/2-offline-bundle-cosign/.state/node-id" ]]; then
    bash "$ROOT/live-demos/2-offline-bundle-cosign/scripts/cleanup.sh"
fi

if [[ -s "$ROOT/advanced-demos/zarf-package-lifecycle/.state/node-id" ]]; then
    bash "$ROOT/advanced-demos/zarf-package-lifecycle/scripts/cleanup.sh"
fi