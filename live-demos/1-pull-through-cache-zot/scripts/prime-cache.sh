#!/usr/bin/env bash
# From live-demos/1-pull-through-cache-zot: ./scripts/prime-cache.sh
# The client executes:
# skopeo copy --src-tls-verify=false \
#   docker://localhost:5000/nginx:latest dir:/tmp/nginx-online
# Inspect the API: curl -fsS http://localhost:5000/v2/nginx/tags/list | jq .
# Inspect zot's volume (the tooling container mounts it read-only at /cache):
# docker compose run --rm --no-deps -T --entrypoint /bin/sh skopeo \
#   -c 'find /cache -type f; du -sh /cache'
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"

banner "2 / PRIME: request nginx:latest THROUGH zot"
require_tools
registry_id >/dev/null
set_registry_mode online

printf 'Client -> localhost:5000/nginx:latest -> Docker Hub library/nginx:latest\n'
# Do not copy TO zot: a cache miss must trigger zot's on-demand upstream sync.
skopeo_run copy --src-tls-verify=false "$CACHE_IMAGE" dir:/tmp/nginx-online

printf '\nCached tags:\n'
curl --noproxy '*' --fail --silent --show-error --max-time 5 \
    http://localhost:5000/v2/nginx/tags/list | jq -e '.tags | select(index("latest"))'
printf '\nLocal OCI storage (zot volume mounted read-only at /cache):\n'
timeout 20s "${COMPOSE[@]}" run --rm --no-deps -T --entrypoint /bin/sh skopeo \
    -ec 'test -s /cache/nginx/index.json
         find /cache/nginx/blobs -type f
         printf "\nBlob storage size:\n"
         du -sh /cache'
printf '\nPRIMED: manifests and layer blobs are stored locally.\n'
printf 'Next: ./scripts/verify-cache.sh\n'
