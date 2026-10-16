#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
# shellcheck source=common.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
[[ $# == 0 || ( $# == 1 && "$1" == --purge-state ) ]] ||
  die "Usage: $0 [--purge-state]"
check_docker
mkdir -p "$ROOT/.state"
exec 9>"$ROOT/.state/demo.lock"
flock -n 9 || die "The demo is currently running."
cleanup_resources
if [[ "${1:-}" == --purge-state ]]; then
  rm -rf -- "$ROOT/.state"
  echo 'Removed this demo resources, bundle and evidence.'
else
  echo 'Removed this demo containers, networks and registry volumes; retained .state evidence.'
fi
