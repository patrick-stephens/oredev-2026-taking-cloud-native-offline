#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
case "${1:-}" in
  ''|--purge) ;;
  *) die 'Usage: cleanup.sh [--purge]' ;;
esac
require docker
docker info >/dev/null
remove_runtime
remove_runtime taking-offline-k0s-airgap taking-offline-k0s-airgap
if [[ "${1:-}" == --purge ]]; then
  # Only these two generated directories belong to this demo.
  rm -rf -- "$ROOT/artifacts" "$ROOT/.state"
  echo 'Removed local bundle and evidence; Docker image cache left untouched.'
fi
echo 'Both demo distributions: containers, anonymous volumes and internal networks removed.'
