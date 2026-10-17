#!/usr/bin/env bash
# From live-demos/1-pull-through-cache-zot: ./scripts/verify-cache.sh
# Freeze mutable tags before the outage, preserving the same cache volume:
# ZOT_CONFIG=./zot-offline-config.json docker compose up -d zot
# Only the demo namespace loses egress:
# docker network disconnect offline-cache-demo_uplink "$(docker compose ps -q zot)"
# Offline client commands:
# skopeo --command-timeout 8s inspect --raw docker://docker.io/library/nginx:latest
# skopeo copy --src-tls-verify=false \
#   docker://localhost:5000/nginx:latest dir:/tmp/nginx-offline
# Restore proxy mode (also automatic on exit):
# ZOT_CONFIG=./zot-config.json docker compose up -d zot
# Recovery after an uncatchable interruption: ./scripts/start-cache.sh
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
HUB_IMAGE="docker://docker.io/library/nginx:latest"

banner "3 / OFFLINE: cut internet for BOTH zot and its pull client"
require_tools
id="$(registry_id)"
network="$(uplink_name "$id")"
ensure_online "$id" "$network"
cache_ready
if ! curl --noproxy '*' --fail --silent --show-error --max-time 5 \
    http://localhost:5000/v2/nginx/tags/list |
    jq -e '.tags | index("latest") != null' >/dev/null; then
    die "nginx:latest is not cached. Run ./scripts/prime-cache.sh first."
fi

# A successful online Hub request rules out auth/rate-limit errors as our proof.
printf 'Checking Docker Hub access before the outage...\n'
skopeo_run inspect --raw "$HUB_IMAGE" >/dev/null
online_manifest="$(skopeo_run inspect --raw --tls-verify=false "$CACHE_IMAGE")"
expected="$(printf '%s' "$online_manifest" | sha256sum | cut -d ' ' -f 1)"

restore() {
    local status=$?
    trap - EXIT
    printf '\nRestoring proxy mode and the demo uplink...\n'
    if ! set_registry_mode online; then
        printf 'ERROR: restoration failed; run ./scripts/start-cache.sh to recover.\n' >&2
        exit 1
    fi
    exit "$status"
}
trap restore EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
printf '\nSwitching to CACHE-ONLY mode: no upstream tag refresh; same stored blobs.\n'
set_registry_mode offline
id="$(registry_id)"
network="$(uplink_name "$id")"
docker network disconnect "$network" "$id"

# Fail if any external-facing network remains attached.
attached_networks="$(docker inspect "$id" | jq -r '.[0].NetworkSettings.Networks | keys[]')"
[[ -n "$attached_networks" ]] || die "The internal cache network is missing."
while IFS= read -r attached; do
    [[ "$(docker network inspect --format '{{.Internal}}' "$attached")" == true ]] ||
        die "Unexpected external-facing network remains: $attached"
done <<<"$attached_networks"
printf 'ISOLATED: only the internal Docker network remains; the host is unaffected.\n'

printf '\nDirect Docker Hub pull must fail (maximum 8 seconds of registry work):\n'
if failure="$(timeout 20s "${COMPOSE[@]}" run --rm --no-deps -T --interactive=false skopeo \
    --command-timeout 8s inspect --raw "$HUB_IMAGE" 2>&1)"; then
    die "Docker Hub unexpectedly remained reachable."
else
    status=$?
    printf '%s\n' "$failure"
    [[ "$status" != 124 ]] || die "The client failed to start/finish within the outer timeout."
    # Do not mistake an auth, image, or Compose error for an offline network.
    grep -Eiq 'network is unreachable|no route to host|i/o timeout|context deadline exceeded|lookup .* (timeout|refused)|connection refused|Temporary failure in name resolution' \
        <<<"$failure" || die "Hub failed, but not with a recognized network error."
fi
printf 'EXPECTED FAILURE: direct Docker Hub access is unavailable.\n'

if [[ -t 0 && -t 1 && ${DEMO_AUTO_ADVANCE:-0} != 1 ]]; then
    read -r -p 'Press Enter to clear the screen and pull from the offline cache... ' ||
        die "Input ended before the cache check."
fi
banner "4 / CACHE HIT: pull ALL nginx layers with no internet"
start=$SECONDS
# A fresh, disposable skopeo container cannot reuse the online client's files.
skopeo_run copy --src-tls-verify=false "$CACHE_IMAGE" dir:/tmp/nginx-offline
elapsed=$((SECONDS - start))
offline_manifest="$(skopeo_run inspect --raw --tls-verify=false "$CACHE_IMAGE")"
actual="$(printf '%s' "$offline_manifest" | sha256sum | cut -d ' ' -f 1)"
[[ "$actual" == "$expected" ]] || die "The offline manifest differs from the primed manifest."
[[ "$elapsed" -lt 15 ]] || die "Offline copy took ${elapsed}s; expected a local cache hit under 15s."
printf '\nPASS: a fresh client copied every layer from localhost:5000 in %ss (<15s).\n' "$elapsed"
printf 'PASS: online/offline manifest SHA-256 matches: %s\n' "$actual"
printf 'PASS: registry API remained reachable inside the isolated client namespace.\n'
printf 'Next: ./scripts/stop-cache.sh\n'
