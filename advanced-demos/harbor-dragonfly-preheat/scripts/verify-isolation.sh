#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=common.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
[[ "$(docker network inspect -f '{{.Internal}}' "$NETWORK")" == true ]]
mapfile -t ids < <({ dc ps --all -q; hc ps --all -q; } | sort -u)
(( ${#ids[@]} > 0 ))
for id in "${ids[@]}"; do
    docker inspect "$id" | jq -e --arg network "$NETWORK" '
      .[0] | (.State.Running == true) and (.HostConfig.Privileged == false) and
      ((.NetworkSettings.Networks | keys) == [$network])' > /dev/null
    name="$(docker inspect -f '{{.Name}}' "$id")"
    # Literal addresses avoid a DNS test escaping via the daemon's resolver.
    for url in http://1.1.1.1 https://1.1.1.1; do
        rc=0
        docker run --rm --pull never --network "container:$id" "$CURL_IMAGE" \
            --noproxy '*' --silent --show-error --connect-timeout 2 --max-time 3 \
            "$url" > "$ROOT/.state/egress.out" 2> "$ROOT/.state/egress.err" || rc=$?
        case "$rc" in
            7|28) printf '%s %s blocked (curl=%s)\n' "$name" "$url" "$rc" ;;
            *) echo "Isolation check failed for $name ($url, curl=$rc)" >&2
               cat "$ROOT/.state/egress.err" >&2; exit 1 ;;
        esac
    done
done | tee -a "$ROOT/artifacts/isolation.txt"
echo "Verified internal-only attachment and denied external TCP in ${#ids[@]} namespaces."
