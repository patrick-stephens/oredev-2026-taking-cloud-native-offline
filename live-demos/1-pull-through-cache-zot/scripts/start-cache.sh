#!/usr/bin/env bash
# From live-demos/1-pull-through-cache-zot: ./scripts/start-cache.sh
# Equivalent startup:
# docker compose --profile tools pull
# docker compose up -d zot
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"

banner "1 / START: pull-through registry on 127.0.0.1:$DEMO_HOST_PORT"
require_tools
show_commands \
	"curl --noproxy '*' -fsS '$HOST_CACHE_URL/v2/'" \
	"docker compose --project-name offline-cache-demo --file '$DEMO_DIR/compose.yaml' ps" \
	"docker compose --project-name offline-cache-demo --file '$DEMO_DIR/compose.yaml' logs --tail 20 zot"

# Pull missing tooling now, not after the simulated outage.
timeout 120s "${COMPOSE[@]}" --profile tools pull --policy missing
set_registry_mode online

printf 'Docker target platform: %s\n' "$DEMO_PLATFORM"
printf 'READY: %s/v2/\n' "$HOST_CACHE_URL"
printf 'Persistent storage: Docker volume mounted at /var/lib/zot\n'
printf 'Next: ./scripts/prime-cache.sh\n'
