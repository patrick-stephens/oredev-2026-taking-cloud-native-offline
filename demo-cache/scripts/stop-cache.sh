#!/usr/bin/env bash
# From demo-cache: ./scripts/stop-cache.sh
# Equivalent: docker compose --profile tools down --remove-orphans
# For an explicitly destructive cold reset: ./scripts/stop-cache.sh --purge
# Equivalent: docker compose --profile tools down --remove-orphans --volumes
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"

[[ $# -le 1 ]] || die "Usage: $0 [--purge]"
[[ $# == 0 || $1 == --purge ]] || die "Usage: $0 [--purge]"
banner "5 / STOP: clean up the demo"
require_tools
args=(--remove-orphans)
if [[ ${1:-} == --purge ]]; then
    args+=(--volumes)
fi
"${COMPOSE[@]}" --profile tools down "${args[@]}"
if [[ ${1:-} == --purge ]]; then
    printf 'STOPPED: demo containers, networks and cached image volume removed.\n'
else
    printf 'STOPPED: containers/networks removed; cached images retained for the next run.\n'
fi
