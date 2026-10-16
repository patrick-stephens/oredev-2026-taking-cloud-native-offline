#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=common.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
MODE="${1:?Usage: benchmark.sh direct|p2p}"
[[ "$MODE" == direct || "$MODE" == p2p ]] || { echo "Invalid mode: $MODE" >&2; exit 1; }

pull_one() {
    local i=$1 destination="$ROOT/.state/pulls/$MODE-$1" start elapsed bytes namespace
    mkdir -p "$destination"
    [[ -z "$(ls -A "$destination")" ]] || { echo "Refusing a warm destination: $destination" >&2; return 1; }
    local -a network proxy
    network=(--network "$NETWORK")
    proxy=()
    if [[ "$MODE" == p2p ]]; then
        namespace="$(dc ps -q "peer$i")"
        [[ -n "$namespace" ]]
        network=(--network "container:$namespace")
        proxy=(-e HTTP_PROXY=http://127.0.0.1:65001 -e http_proxy=http://127.0.0.1:65001
            -e HTTPS_PROXY= -e https_proxy= -e NO_PROXY= -e no_proxy=)
    fi
    start="$(date +%s%3N)"
    docker run --rm --pull never "${network[@]}" "${proxy[@]}" \
        -v "$destination:/out" "$SKOPEO_IMAGE" copy --preserve-digests \
        --src-tls-verify=false "docker://harbor:8080/fleet/jenkins:$JENKINS_TAG" dir:/out \
        > "$ROOT/artifacts/$MODE-$i.log" 2>&1
    elapsed=$(( $(date +%s%3N) - start ))
    # Verify every config/layer digest, not just the command's exit status.
    jq -r '(.layers[]?, .config) | .digest | sub("^sha256:";"")' \
        "$ROOT/artifacts/manifest.json" |
        while IFS= read -r digest; do
            printf '%s  %s\n' "$digest" "$destination/$digest"
        done | sha256sum --check > "$ROOT/artifacts/$MODE-$i-digests.txt"
    cmp "$ROOT/artifacts/manifest.json" "$destination/manifest.json"
    bytes="$(jq '[.layers[].size, .config.size] | add' "$ROOT/artifacts/manifest.json")"
    printf '%s,%s,%s,%s\n' "$MODE" "$i" "$elapsed" "$bytes" > "$ROOT/artifacts/$MODE-$i.csv"
}

echo "Starting five concurrent cold $MODE image copies."
pids=()
for i in $(seq 1 5); do
    pull_one "$i" &
    pids+=("$!")
done
failed=0
for pid in "${pids[@]}"; do
    if ! wait "$pid"; then failed=1; fi
done
(( failed == 0 )) || { echo "$MODE copy failed: inspect per-consumer logs." >&2; exit 1; }
for i in $(seq 1 5); do cat "$ROOT/artifacts/$MODE-$i.csv"; done |
    tee -a "$ROOT/artifacts/timings.csv"
