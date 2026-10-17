#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=common.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"

metric() {
    awk -v key="$1" '
        $1 == key {n += $2; found=1}
        END {
            if (!found) {
                print "Missing required metric: " key > "/dev/stderr"
                exit 1
            }
            printf "%.0f\n", n
        }' "$2"
}
[[ -s "$ROOT/artifacts/gateway-blocked.log" ]] || {
    echo "Missing or empty blocked-origin gateway log." >&2
    exit 1
}
origin_bytes="$(awk '/ (GET|HEAD) .*\/blobs\/sha256:/ && $(NF-1) ~ /^2/ {n += $NF} END {print n+0}' \
    "$ROOT/artifacts/gateway-blocked.log")"
[[ "$origin_bytes" == 0 ]] || {
    echo "Source served $origin_bytes blob bytes after cutover!" >&2
    exit 1
}
before="$(metric 'dragonfly_dfdaemon_seed_peer_download_traffic{type="back_to_source"}' "$ROOT/artifacts/seed-before.prom")"
after="$(metric 'dragonfly_dfdaemon_seed_peer_download_traffic{type="back_to_source"}' "$ROOT/artifacts/seed-after.prom")"
expected_bytes="$(jq '[.layers[].size, .config.size] | add' "$ROOT/artifacts/manifest.json")"
expected_requests="$(jq '.layers | length + 1' "$ROOT/artifacts/manifest.json")"
(( before == expected_bytes && after == before )) || {
    echo "Seed origin bytes changed during blocked-source test: $before -> $after" >&2
    exit 1
}
{
    echo 'node,proxy_p2p_requests,upload_bytes'
    for node in seed peer1 peer2 peer3 peer4 peer5; do
        file="$ROOT/artifacts/$node.prom"
        [[ "$node" != seed ]] || file="$ROOT/artifacts/seed-after.prom"
        requests="$(metric dragonfly_dfdaemon_proxy_request_via_dragonfly_total "$file")"
        uploaded="$(metric dragonfly_dfdaemon_upload_response_size_bytes_sum "$file")"
        if [[ "$node" != seed ]]; then
            (( requests == expected_requests )) || {
                echo "$node: expected $expected_requests Dragonfly blob requests, got $requests" >&2
                exit 1
            }
        else
            (( uploaded > 0 )) || { echo "Seed did not upload any bytes!" >&2; exit 1; }
        fi
        printf '%s,%s,%s\n' "$node" "$requests" "$uploaded"
    done
} | tee "$ROOT/artifacts/distribution.csv"
awk -F, 'NR>1 {n[$1]++;sum[$1]+=$3}
    END {for (m in n) printf "%s mean cold copy: %.1f ms (%d consumers)\n",m,sum[m]/n[m],n[m]}' \
    "$ROOT/artifacts/timings.csv" | tee "$ROOT/artifacts/summary.txt"
printf 'Seed origin bytes unchanged: %s; successful origin blob bytes after cutover: %s\n' \
    "$after" "$origin_bytes" | tee -a "$ROOT/artifacts/summary.txt"
