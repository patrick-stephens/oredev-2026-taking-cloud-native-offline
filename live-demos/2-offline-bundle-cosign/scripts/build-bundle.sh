#!/usr/bin/env bash
# Connected side, from live-demos/2-offline-bundle-cosign: ./scripts/build-bundle.sh
# Equivalent image operation (containerized Skopeo below):
# skopeo copy --override-os linux --override-arch amd64 \
#   docker://docker.io/library/postgres:18.6-alpine3.23 dir:images/postgres
# helm lint chart --set auth.existingSecret=offline-postgresql-auth
# helm package chart --destination charts
# cosign sign-blob --tlog-upload=false --key .state/signing/cosign.key \
#   --output-signature metadata.sig metadata.json
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
banner "1 / CONNECTED: package our chart, pull PostgreSQL, sign the complete inventory"
require_tools
ensure_image "$SKOPEO"
ensure_image "$COSIGN"
umask 077
work="$(mktemp -d "$DEMO_DIR/.build.XXXXXXXX")"
trap 'remove_workdir "$work"' EXIT
mkdir -p "$SIGNING_DIR" "$work/charts" "$work/images/postgres" "$work/keys"
chmod 700 "$SIGNING_DIR"

if [[ ! -e "$COSIGN_KEY" && ! -e "$COSIGN_PUB" ]]; then
    if [[ ! -s "$COSIGN_PASSWORD_FILE" ]]; then
        head -c 32 /dev/urandom | base64 > "$COSIGN_PASSWORD_FILE"
    fi
    COSIGN_PASSWORD="$(<"$COSIGN_PASSWORD_FILE")"
    export COSIGN_PASSWORD
    signing_tool "$work" generate-key-pair
fi
[[ -s "$COSIGN_KEY" && -s "$COSIGN_PUB" &&
    -s "$COSIGN_PASSWORD_FILE" ]] || die "Incomplete signing keypair or password in $SIGNING_DIR."
COSIGN_PASSWORD="$(<"$COSIGN_PASSWORD_FILE")"
export COSIGN_PASSWORD
signing_tool "$work" public-key --key /keys/cosign.key > "$work/derived.pub"
cmp "$work/derived.pub" "$COSIGN_PUB" ||
    die "The private and public signing keys do not match."
cp "$COSIGN_PUB" "$work/keys/cosign.pub"

helm lint "$DEMO_DIR/chart" -f "$DEMO_DIR/values.yaml" --strict
helm package "$DEMO_DIR/chart" --destination "$work/charts"
[[ -s "$work/charts/offline-postgresql-$CHART_VERSION.tgz" ]] ||
    die "Packaged chart version differs from the demo's pinned version."
timeout 100s docker run --rm --user "$(id -u):$(id -g)" \
    --mount "type=bind,src=$work,dst=/bundle" "$SKOPEO" \
    --command-timeout 90s copy --override-os linux --override-arch amd64 \
    "docker://$POSTGRES_IMAGE" dir:/bundle/images/postgres
cp "$DEMO_DIR/values.yaml" "$work/values.yaml"

# Authenticate every chart dependency, image layer, config, manifest and values.
# The signature covers this inventory, not just the image's small manifest.
(
    cd "$work"
    find charts images keys values.yaml -type f -print0 | sort -z |
        while IFS= read -r -d '' file; do
            digest="$(sha256sum "$file")"
            jq -n --arg path "$file" --arg sha256 "${digest%% *}" \
                '{path:$path,sha256:$sha256}'
        done | jq -s . > files.json
    digest="$(sha256sum images/postgres/manifest.json)"
    jq -n --arg digest "sha256:${digest%% *}" --arg version "$CHART_VERSION" \
        --arg image "$POSTGRES_IMAGE" \
        --slurpfile files files.json \
        '{schemaVersion:1,platform:"linux/amd64",
          image:{reference:$image,digest:$digest},
          chart:{name:"offline-postgresql",version:$version},files:$files[0]}' > metadata.json
)
signing_tool "$work" sign-blob --yes --tlog-upload=false --key /keys/cosign.key \
    --output-signature /bundle/metadata.sig /bundle/metadata.json
tar -C "$work" -czf "$work/bundle.tar.gz" \
    charts images keys values.yaml metadata.json metadata.sig
mv "$work/bundle.tar.gz" "$DEMO_DIR/bundle.tar.gz"
printf '\nBUNDLE: %s/bundle.tar.gz\n' "$DEMO_DIR"
printf 'TRUST OUT OF BAND: copy %s separately to the target.\n' "$COSIGN_PUB"
sha256sum "$COSIGN_PUB"
jq '{image,chart,authenticatedFiles:(.files|length)}' "$work/metadata.json"
