#!/usr/bin/env bash
# Air-gapped side, from demo-bundle:
# ./scripts/verify-import.sh --trusted-key /trusted/cosign.pub [--tamper]
# cosign verify-blob --offline --insecure-ignore-tlog --key /trusted/cosign.pub \
#   --signature metadata.sig metadata.json
# skopeo copy --preserve-digests --dest-tls-verify=false \
#   dir:images/nginx docker://localhost:5001/nginx:latest
# helm upgrade --install offline-nginx charts/nginx-22.0.11.tgz \
#   --namespace offline-bundle --create-namespace -f values.yaml \
#   --set image.registry=localhost:5001 --set image.digest=sha256:... --wait
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
trusted_key=""
tamper=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        --trusted-key) [[ $# -ge 2 ]] || die "--trusted-key needs a path."; trusted_key="$(realpath "$2")"; shift 2 ;;
        --tamper) tamper=true; shift ;;
        *) die "Usage: $0 --trusted-key /trusted/cosign.pub [--tamper]" ;;
    esac
done
[[ -f "$trusted_key" ]] || die "An independently trusted public key is required."
require_tools
assert_offline
for image in "$ZOT" "$SKOPEO" "$COSIGN"; do
    docker image inspect "$image" >/dev/null ||
        die "Missing pre-staged tool image: $image. Do not download it on the offline side."
done
banner "3 / AIR GAP: receive the archive and verify its signed inventory"
umask 077
work="$(mktemp -d "$DEMO_DIR/.verify.XXXXXXXX")"
trap 'remove_workdir "$work"' EXIT
[[ -f "$DEMO_DIR/bundle.tar.gz" ]] || die "Transport bundle.tar.gz to demo-bundle first."
[[ "$(stat -c %s "$DEMO_DIR/bundle.tar.gz")" -le 1073741824 ]] ||
    die "Compressed bundle exceeds the 1 GiB application-bundle limit."

# Reject links, special files, path traversal and duplicate members BEFORE extract.
# Accept only the bounded, simple archive layout emitted by our build script.
timeout 30s tar -tzf "$DEMO_DIR/bundle.tar.gz" > "$work/names"
timeout 30s tar -tvzf "$DEMO_DIR/bundle.tar.gz" --numeric-owner > "$work/types"
awk 'substr($0,1,1)!="-" && substr($0,1,1)!="d" {exit 1}' "$work/types" ||
    die "Archive contains a link or special file."
awk '$3 !~ /^[0-9]+$/ {exit 1} {total += $3} END {if(total > 1073741824) exit 1}' "$work/types" ||
    die "Archive expands beyond the 1 GiB application-bundle limit."
awk '
    !/^[a-zA-Z0-9_.\/-]+$/ || /^\// || /(^|\/)\.\.?($|\/)/ {exit 1}
    {if (seen[$0]++) exit 1}
    !/^(charts\/|images\/|keys\/|values.yaml$|metadata.json$|metadata.sig$)/ {exit 1}
' "$work/names" || die "Unsafe or unexpected archive member."
mkdir "$work/bundle"
timeout 30s tar -xzf "$DEMO_DIR/bundle.tar.gz" -C "$work/bundle" --no-same-owner --no-same-permissions
payload="$work/bundle"

# This container has no network, private key, signing password or writable bundle.
docker run --rm --network none --user "$(id -u):$(id -g)" --env HOME=/tmp \
    --mount "type=bind,src=$payload,dst=/bundle,readonly" \
    --mount "type=bind,src=$trusted_key,dst=/trusted/cosign.pub,readonly" "$COSIGN" \
    verify-blob --offline --insecure-ignore-tlog --key /trusted/cosign.pub \
    --signature /bundle/metadata.sig /bundle/metadata.json
cmp "$trusted_key" "$payload/keys/cosign.pub" ||
    die "Bundled public key differs from the independently trusted key."
printf 'VERIFIED: publisher signature (no network or transparency-log lookup).\n'

jq -e --arg version "$CHART_VERSION" '
    .schemaVersion == 1 and .platform == "linux/amd64" and
    .image.reference == "docker.io/library/nginx:latest" and
    (.image.digest | test("^sha256:[a-f0-9]{64}$")) and
    .chart.name == "nginx" and .chart.version == $version and
    (.files|type == "array" and length > 0) and
    all(.files[]; (.path|test("^(charts/|images/|keys/|values.yaml$)")) and
        (.path|test("^[a-zA-Z0-9_./-]+$")) and
        (.path|test("(^|/)\\.\\.?($|/)")|not) and
        (.sha256|test("^[a-f0-9]{64}$"))) and
    ([.files[].path]|length == (unique|length))
' "$payload/metadata.json" >/dev/null || die "Invalid signed metadata schema."

if [[ "$tamper" == true ]]; then
    printf 'TAMPER: modifying the transported image manifest, not the original archive.\n'
    printf '\nmalicious-change\n' >> "$payload/images/nginx/manifest.json"
fi
while IFS=$'\t' read -r path expected; do
    [[ -f "$payload/$path" ]] || die "Missing authenticated file: $path"
    actual="$(sha256sum "$payload/$path")"
    if [[ ${actual%% *} != "$expected" ]]; then
        printf 'REJECTED: authenticated SHA-256 mismatch: %s\n' "$path" >&2
        exit 42
    fi
done < <(jq -r '.files[] | [.path,.sha256] | @tsv' "$payload/metadata.json")
(
    cd "$payload"
    find charts images keys values.yaml -type f | sort
) > "$work/actual-files"
jq -r '.files[].path' "$payload/metadata.json" | sort > "$work/signed-files"
cmp "$work/actual-files" "$work/signed-files" ||
    die "Payload has unsigned, missing or duplicate files."
digest="$(jq -r '.image.digest' "$payload/metadata.json")"
actual="$(sha256sum "$payload/images/nginx/manifest.json")"
[[ "$digest" == "sha256:${actual%% *}" ]] || die "Image digest does not match the authenticated manifest."
printf 'VERIFIED: all chart, values, public-key and image files match the signed inventory.\n'

advance
banner "4 / IMPORT: start a local-only zot and load the verified image"
if ! docker volume inspect offline-bundle-registry >/dev/null 2>&1; then
    docker volume create --label offline-bundle-demo=true offline-bundle-registry >/dev/null
fi
[[ "$(docker volume inspect offline-bundle-registry --format '{{index .Labels "offline-bundle-demo"}}')" == true ]] ||
    die "Refusing to reuse an unowned registry volume."
if docker container inspect "$REGISTRY" >/dev/null 2>&1; then
    [[ "$(docker inspect "$REGISTRY" --format '{{index .Config.Labels "offline-bundle-demo"}}')" == true ]] ||
        die "Refusing to replace an unowned registry container."
    docker rm -f "$REGISTRY" >/dev/null
fi
docker run -d --name "$REGISTRY" --label offline-bundle-demo=true \
    --network "container:$NODE" \
    --mount "type=bind,src=$DEMO_DIR/registry/config.yml,dst=/etc/zot/config.yml,readonly" \
    --mount type=volume,src=offline-bundle-registry,dst=/var/lib/zot \
    "$ZOT" serve /etc/zot/config.yml >/dev/null
ready=false
for ((attempt=0; attempt<30; attempt++)); do
    if docker exec "$NODE" curl --noproxy '*' -fsS --max-time 1 http://localhost:5001/v2/ >/dev/null 2>&1; then
        ready=true; break
    fi
    sleep 1
done
if [[ "$ready" != true ]]; then
    docker logs --tail 30 "$REGISTRY" >&2
    die "Local registry did not become ready."
fi
assert_offline
printf 'Proving a direct Docker Hub request is impossible from the target...\n'
if failure="$(timeout 20s docker run --rm --network "container:$NODE" "$SKOPEO" \
    --command-timeout 8s inspect --raw docker://docker.io/nginx:latest 2>&1)"; then
    die "Target unexpectedly reached Docker Hub."
else
    status=$?
    printf '%s\n' "$failure"
    [[ "$status" != 124 ]] || die "Client timed out outside the registry operation."
    grep -Eiq 'network is unreachable|no route to host|i/o timeout|context deadline exceeded|Temporary failure in name resolution' \
        <<< "$failure" || die "Direct access failed for a non-network reason."
fi
timeout 90s docker run --rm --network "container:$NODE" \
    --mount "type=bind,src=$payload,dst=/bundle,readonly" "$SKOPEO" \
    --command-timeout 80s copy --preserve-digests --dest-tls-verify=false \
    dir:/bundle/images/nginx docker://localhost:5001/nginx:latest
imported="$(docker run --rm --network "container:$NODE" "$SKOPEO" \
    --command-timeout 10s inspect --raw --tls-verify=false docker://localhost:5001/nginx:latest | sha256sum)"
[[ "sha256:${imported%% *}" == "$digest" ]] || die "Registry manifest digest differs after import."
printf 'IMPORTED: localhost:5001/nginx:latest (%s)\n' "$digest"

advance
banner "5 / DEPLOY: local Helm chart, verified digest, no external pulls"
docker exec "$NODE" mkdir -p /offline-bundle
docker cp "$payload/charts/nginx-$CHART_VERSION.tgz" "$NODE:/offline-bundle/nginx.tgz"
docker cp "$payload/values.yaml" "$NODE:/offline-bundle/values.yaml"
if ! docker exec "$NODE" offline-demo-helm upgrade --install offline-nginx /offline-bundle/nginx.tgz \
    --kubeconfig /etc/kubernetes/admin.conf \
    --namespace offline-bundle --create-namespace -f /offline-bundle/values.yaml \
    --set image.registry=localhost:5001 --set "image.digest=$digest" --wait --timeout 90s; then
    kube -n offline-bundle get pods -o wide >&2
    kube -n offline-bundle get events --sort-by=.lastTimestamp >&2
    die "Helm deployment failed."
fi
kube -n offline-bundle get pods -o wide
kube -n offline-bundle get deployment offline-nginx -o json |
    jq -e --arg image "localhost:5001/nginx@$digest" \
        '.spec.template.spec.containers[0].image == $image and .status.availableReplicas == 1' >/dev/null
response="$(kube -n offline-bundle exec deployment/offline-nginx -- curl -fsS --max-time 5 http://127.0.0.1:8080/)"
grep -Fq 'Welcome to nginx!' <<< "$response" || die "nginx did not return its expected welcome page."
assert_offline
printf '\nPASS: signature, every payload hash and imported image digest verified offline.\n'
printf 'PASS: Helm deployed the official nginx image by authenticated digest; pod is Ready.\n'
printf 'PASS: HTTP returned Welcome to nginx!; target still has no default route.\n'
