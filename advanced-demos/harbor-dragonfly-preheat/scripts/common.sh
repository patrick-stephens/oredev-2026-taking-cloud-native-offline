#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
export ROOT
set -a
# shellcheck source=../config/versions.env
source "$ROOT/config/versions.env"
if [[ -f "$ROOT/.state/runtime.env" ]]; then
    # Generated locally; never checked in.
    # shellcheck disable=SC1091
    source "$ROOT/.state/runtime.env"
fi
set +a
NETWORK=offline-preheat-airgap
API=http://harbor:8080/api/v2.0

dc() {
    docker compose -p offline-preheat -f "$ROOT/config/compose.yaml" "$@"
}
hc() {
    docker compose -p offline-preheat-harbor -f "$ROOT/.state/harbor.compose.json" "$@"
}
api() {
    docker run --rm --pull never --network "$NETWORK" --user "$(id -u):$(id -g)" \
        -v "$ROOT/.state/curl.conf:/auth:ro" "$CURL_IMAGE" \
        --noproxy '*' --fail-with-body --silent --show-error --max-time 30 \
        --config /auth -H 'Content-Type: application/json' "$API$1" "${@:2}"
}
inside() {
    docker run --rm --pull never --network "$NETWORK" "$CURL_IMAGE" \
        --noproxy '*' --fail-with-body --silent --show-error --max-time 20 "$@"
}
wait_url() {
    local url=$1
    for _ in $(seq 1 120); do
        if inside "$url" > "$ROOT/.state/health.out" 2> "$ROOT/.state/health.err"; then
            return
        fi
        sleep 2
    done
    cat "$ROOT/.state/health.err" >&2
    echo "Timed out waiting for $url" >&2
    return 1
}
collect_logs() {
    dc logs --no-color > "$ROOT/artifacts/dragonfly.log" 2>&1
    if [[ -s "$ROOT/.state/harbor.compose.json" ]]; then
        hc logs --no-color > "$ROOT/artifacts/harbor.log" 2>&1
    fi
}
