#!/usr/bin/env bash
# From live-demos/1-pull-through-cache-zot: ./scripts/start-cache.sh
# Equivalent startup:
# docker compose --profile tools pull
# docker compose up -d zot
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"

banner "1 / START: pull-through registry on localhost:5000"
require_tools
[[ "$(docker info --format '{{.OSType}}/{{.Architecture}}')" == "linux/x86_64" ]] ||
    die "This demo pins the linux/amd64 zot image; use an amd64 Linux Docker engine."

# Pull missing tooling now, not after the simulated outage.
timeout 120s "${COMPOSE[@]}" --profile tools pull --policy missing
set_registry_mode online

printf 'READY: http://localhost:5000/v2/\n'
printf 'Persistent storage: Docker volume mounted at /var/lib/zot\n'
printf 'Next: ./scripts/prime-cache.sh\n'
