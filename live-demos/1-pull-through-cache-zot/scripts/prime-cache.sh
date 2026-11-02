#!/usr/bin/env bash
# From live-demos/1-pull-through-cache-zot: ./scripts/prime-cache.sh
# The client executes:
# skopeo copy --src-tls-verify=false \
#   docker://localhost:5000/nginx:latest dir:/tmp/nginx-online
# Inspect the API: curl -fsS "$HOST_CACHE_URL/v2/nginx/tags/list" | jq .
# Inspect zot's volume (the tooling container mounts it read-only at /cache):
# docker compose run --rm --no-deps -T --interactive=false --entrypoint /bin/sh skopeo \
#   -c 'find /cache -type f; du -sh /cache'
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"

banner "2 / PRIME: request nginx:latest THROUGH zot"
require_tools
show_commands \
    "curl --noproxy '*' -fsS '$HOST_CACHE_URL/v2/nginx/tags/list' | jq ." \
    "docker compose --project-name offline-cache-demo --file '$DEMO_DIR/compose.yaml' run --rm --no-deps -T --interactive=false --entrypoint /bin/sh skopeo -ec 'find /cache/nginx/blobs -type f; du -sh /cache'" \
    "docker compose --project-name offline-cache-demo --file '$DEMO_DIR/compose.yaml' logs --tail 30 zot"
registry_id >/dev/null
set_registry_mode online

printf 'Client -> localhost:5000/nginx:latest -> Docker Hub library/nginx:latest\n'
# Do not copy TO zot: a cache miss must trigger zot's on-demand upstream sync.
skopeo_run copy --src-tls-verify=false "$CACHE_IMAGE" dir:/tmp/nginx-online

printf '\nCached tags:\n'
curl --noproxy '*' --fail --silent --show-error --max-time 5 \
    "$HOST_CACHE_URL/v2/nginx/tags/list" | jq -e '.tags | select(index("latest"))'
printf '\nLocal OCI storage (zot volume mounted read-only at /cache):\n'
timeout 20s "${COMPOSE[@]}" run --rm --no-deps -T --interactive=false --entrypoint /bin/sh skopeo \
    -ec 'test -s /cache/nginx/index.json
         find /cache/nginx/blobs -type f
         printf "\nBlob storage size:\n"
         du -sh /cache'
printf '\nPRIMED: manifests and layer blobs are stored locally.\n'
record_commands \
    "curl --noproxy '*' -fsS --max-time 5 '$HOST_CACHE_URL/v2/nginx/tags/list' | jq ." \
    "docker compose --project-name offline-cache-demo --file '$DEMO_DIR/compose.yaml' run --rm --no-deps -T --interactive=false --entrypoint /bin/sh skopeo -ec 'printf \"Stored blobs: \"; find /cache/nginx/blobs -type f | wc -l; du -sh /cache'"
printf 'Next: ./scripts/verify-cache.sh\n'
