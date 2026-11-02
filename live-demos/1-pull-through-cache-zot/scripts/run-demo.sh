#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)"
DEMO_DIR="$ROOT/live-demos/1-pull-through-cache-zot"
source "$DEMO_DIR/scripts/common.sh"

cleanup() {
    local status=$?
    trap - EXIT
    if [[ "$(uname -s)" == Darwin ]]; then
        bash "$ROOT/scripts/cleanup-macos-demos.sh" || status=1
    else
        bash "$DEMO_DIR/scripts/stop-cache.sh" || status=1
    fi
    exit "$status"
}

if [[ "$(uname -s)" == Darwin ]]; then
    bash "$ROOT/scripts/cleanup-macos-demos.sh"
fi
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

bash "$DEMO_DIR/scripts/start-cache.sh"
bash "$DEMO_DIR/scripts/prime-cache.sh"
bash "$DEMO_DIR/scripts/verify-cache.sh"