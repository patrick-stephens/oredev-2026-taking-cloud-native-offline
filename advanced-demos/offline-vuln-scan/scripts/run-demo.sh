#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC1091
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"

started_at=$SECONDS

require_docker
for command_name in curl tar sha256sum jq timeout date du cut tail install stat; do
    require_command "$command_name"
done

architecture="$(uname -m)"
[[ "$architecture" == "x86_64" || "$architecture" == "aarch64" ]] ||
    fail "Only Linux x86_64 and aarch64 hosts are supported (found: $architecture)."
release_arch="amd64"
[[ "$architecture" == "aarch64" ]] && release_arch="arm64"

if managed_container_exists "$DEMO_REGISTRY"; then
    docker rm --force "$DEMO_REGISTRY" >/dev/null
fi

if [[ -d "$DEMO_BUNDLE/oci" ]]; then
    docker run --rm --user 0:0 -v "$DEMO_BUNDLE/oci:/oci" \
        "$DEMO_RUNTIME_IMAGE" chown -R "$(id -u):$(id -g)" /oci
fi

mkdir -p "$DEMO_DIR/.work" "$DEMO_DIR/artifacts" "$DEMO_DIR/.state"
rm -rf -- "$DEMO_BUNDLE" "$DEMO_STAGE"
rm -f -- "$DEMO_ARCHIVE"
mkdir -p "$DEMO_BUNDLE/bin" "$DEMO_BUNDLE/trivy-cache" \
    "$DEMO_BUNDLE/grype-db" "$DEMO_BUNDLE/oci" "$DEMO_STAGE"

fetch_release() {
    local url="$1" output="$2"
    curl --fail --location --silent --show-error --retry 3 --max-time 300 \
        "$url" --output "$output"
}

verify_release_asset() {
    local checksums="$1" asset="$2"
    (cd -- "$(dirname -- "$asset")" &&
        grep -E "^[[:xdigit:]]{64}[[:space:]]+\\*?$(basename -- "$asset")$" "$checksums" |
        sha256sum --check --status -) ||
        fail "Could not verify checksum for $(basename -- "$asset")."
}

phase "CONNECTED: download tools, databases, and image"
printf 'Host architecture: %s (%s)\n' "$architecture" "$release_arch"
printf 'Pinned scanners: Trivy %s, Grype %s\n' "$DEMO_TRIVY_VERSION" "$DEMO_GRYPE_VERSION"

trivy_asset="trivy_${DEMO_TRIVY_VERSION#v}_Linux-64bit.tar.gz"
grype_asset="grype_${DEMO_GRYPE_VERSION#v}_linux_${release_arch}.tar.gz"
trivy_checksums="$DEMO_DIR/.work/trivy-checksums.txt"
grype_checksums="$DEMO_DIR/.work/grype-checksums.txt"
trivy_archive="$DEMO_DIR/.work/$trivy_asset"
grype_archive="$DEMO_DIR/.work/$grype_asset"

fetch_release \
    "https://github.com/aquasecurity/trivy/releases/download/$DEMO_TRIVY_VERSION/$trivy_asset" \
    "$trivy_archive"
fetch_release \
    "https://github.com/aquasecurity/trivy/releases/download/$DEMO_TRIVY_VERSION/trivy_${DEMO_TRIVY_VERSION#v}_checksums.txt" \
    "$trivy_checksums"
verify_release_asset "$trivy_checksums" "$trivy_archive"
tar -xzf "$trivy_archive" -C "$DEMO_BUNDLE/bin" trivy

fetch_release \
    "https://github.com/anchore/grype/releases/download/$DEMO_GRYPE_VERSION/$grype_asset" \
    "$grype_archive"
fetch_release \
    "https://github.com/anchore/grype/releases/download/$DEMO_GRYPE_VERSION/grype_${DEMO_GRYPE_VERSION#v}_checksums.txt" \
    "$grype_checksums"
verify_release_asset "$grype_checksums" "$grype_archive"
tar -xzf "$grype_archive" -C "$DEMO_BUNDLE/bin" grype
install -m 0644 "$DEMO_DIR/config/grype.yaml" "$DEMO_BUNDLE/grype.yaml"

docker pull "$DEMO_REGISTRY_IMAGE"
docker pull "$DEMO_SKOPEO_IMAGE"
docker pull "$DEMO_RUNTIME_IMAGE"

"$DEMO_BUNDLE/bin/trivy" --version
"$DEMO_BUNDLE/bin/grype" version

printf '\nDownloading Trivy vulnerability DB...\n'
"$DEMO_BUNDLE/bin/trivy" image --download-db-only \
    --cache-dir "$DEMO_BUNDLE/trivy-cache" --skip-version-check --disable-telemetry
trivy_db_updated="$(
    jq -r '.UpdatedAt // .updatedAt // empty' "$DEMO_BUNDLE/trivy-cache/db/metadata.json"
)"
[[ -n "$trivy_db_updated" ]] ||
    fail "Trivy DB metadata did not contain an UpdatedAt value."
printf 'Trivy DB published/updated at: %s\n' "$trivy_db_updated"

printf '\nDownloading Grype vulnerability DB...\n'
GRYPE_DB_CACHE_DIR="$DEMO_BUNDLE/grype-db" \
    GRYPE_DB_AUTO_UPDATE=true "$DEMO_BUNDLE/bin/grype" db update
grype_db_status="$(
    GRYPE_DB_CACHE_DIR="$DEMO_BUNDLE/grype-db" \
        GRYPE_DB_AUTO_UPDATE=false "$DEMO_BUNDLE/bin/grype" db status -o json
)"
grype_schema="$(jq -r '.schemaVersion' <<<"$grype_db_status")"
grype_db_path="$(jq -r '.path' <<<"$grype_db_status")"
[[ -n "$grype_schema" && "$grype_schema" != "null" && -f "$grype_db_path" ]] ||
    fail "Grype DB status did not identify a usable database and schema."
printf 'Grype schema: %s\nGrype DB: %s\n' "$grype_schema" "$grype_db_path"

image_candidates=(node:16-alpine python:3.9-slim nginx:1.21-alpine)
selected_image=""
selected_trivy_count=0
selected_grype_count=0

printf '\nSelecting a candidate with findings from both scanners...\n'
for candidate in "${image_candidates[@]}"; do
    printf '\nCandidate: %s\n' "$candidate"
    docker pull "$candidate"
    candidate_id="${candidate//[^[:alnum:]]/_}"
    trivy_report="$DEMO_DIR/.work/trivy-$candidate_id.json"
    grype_report="$DEMO_DIR/.work/grype-$candidate_id.json"

    "$DEMO_BUNDLE/bin/trivy" image --cache-dir "$DEMO_BUNDLE/trivy-cache" \
        --skip-db-update --skip-version-check --disable-telemetry \
        --scanners vuln --format json --output "$trivy_report" "$candidate"
    trivy_count="$(jq '[.Results[]?.Vulnerabilities[]?] | length' "$trivy_report")"

    GRYPE_DB_CACHE_DIR="$DEMO_BUNDLE/grype-db" GRYPE_DB_AUTO_UPDATE=false \
        "$DEMO_BUNDLE/bin/grype" "$candidate" -o json >"$grype_report"
    grype_count="$(jq '.matches | length' "$grype_report")"
    printf 'Connected validation counts: Trivy=%s, Grype=%s\n' "$trivy_count" "$grype_count"

    if (( trivy_count > 0 && grype_count > 0 )); then
        selected_image="$candidate"
        selected_trivy_count="$trivy_count"
        selected_grype_count="$grype_count"
        break
    fi
done
[[ -n "$selected_image" ]] ||
    fail "No candidate had findings in both scanners; refusing to report a successful demo."

printf '\nExporting %s to an OCI layout with Skopeo...\n' "$selected_image"
docker run --rm \
    --user "$(id -u):$(stat -c '%g' /var/run/docker.sock)" \
    -v /var/run/docker.sock:/var/run/docker.sock \
    -v "$DEMO_BUNDLE/oci:/oci" \
    "$DEMO_SKOPEO_IMAGE" \
    copy --all "docker-daemon:$selected_image" "oci:/oci/image:offline-vuln-scan"

{
    printf 'tested_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'image=%s\n' "$selected_image"
    printf 'trivy_version=%s\n' "$DEMO_TRIVY_VERSION"
    printf 'grype_version=%s\n' "$DEMO_GRYPE_VERSION"
    printf 'trivy_db_updated_at=%s\n' "$trivy_db_updated"
    printf 'grype_db_schema=%s\n' "$grype_schema"
    printf 'grype_db_path=%s\n' "${grype_db_path#"$DEMO_BUNDLE"}"
    printf 'connected_trivy_cve_count=%s\n' "$selected_trivy_count"
    printf 'connected_grype_cve_count=%s\n' "$selected_grype_count"
} > "$DEMO_BUNDLE/metadata.txt"

tar -czf "$DEMO_ARCHIVE" -C "$DEMO_DIR" .bundle
mkdir -p "$DEMO_STAGE"
tar -xzf "$DEMO_ARCHIVE" -C "$DEMO_STAGE"
rm -rf -- "$DEMO_BUNDLE" "$DEMO_DIR/.work"
bundle="$DEMO_STAGE/.bundle"
printf '\nTransport archive: %s (%s)\n' "$DEMO_ARCHIVE" "$(du -h "$DEMO_ARCHIVE" | cut -f1)"
cat "$bundle/metadata.txt"

presenter_pause
phase "AIR-GAPPED: internal registry, scanners, and update failures"
ensure_internal_network
[[ "$(docker network inspect --format '{{ .Internal }}' "$DEMO_NETWORK")" == "true" ]] ||
    fail "Docker did not create an internal network."

mkdir -p "$DEMO_DIR/.state/registry-data"
docker run --detach \
    --name "$DEMO_REGISTRY" \
    --label "$DEMO_NETWORK_LABEL" \
    --network "$DEMO_NETWORK" \
    --network-alias registry \
    -v "$DEMO_DIR/.state/registry-data:/var/lib/registry" \
    "$DEMO_REGISTRY_IMAGE" >/dev/null

printf 'Internal network: %s (Internal=true)\n' "$DEMO_NETWORK"
printf 'Importing OCI layout into the isolated registry...\n'
docker run --rm --network "$DEMO_NETWORK" \
    -v "$bundle:/bundle:ro" \
    "$DEMO_SKOPEO_IMAGE" \
    copy --all "oci:/bundle/oci/image:offline-vuln-scan" \
    --dest-tls-verify=false "docker://registry:5000/demo/scan-target:offline"

image_ref="registry:5000/demo/scan-target:offline"
trivy_offline_report="$DEMO_DIR/.state/trivy-offline.json"
grype_offline_report="$DEMO_DIR/.state/grype-offline.json"

printf '\nTrivy offline scan (DB update explicitly skipped)...\n'
docker run --rm --network "$DEMO_NETWORK" \
    -v "$bundle:/bundle" \
    "$DEMO_RUNTIME_IMAGE" /bundle/bin/trivy image \
    --cache-dir /bundle/trivy-cache --skip-db-update --skip-version-check \
    --disable-telemetry --scanners vuln --image-src remote --insecure \
    --format json --output /bundle/trivy-offline.json "$image_ref"
cp "$bundle/trivy-offline.json" "$trivy_offline_report"
trivy_offline_count="$(jq '[.Results[]?.Vulnerabilities[]?] | length' "$trivy_offline_report")"
(( trivy_offline_count > 0 )) ||
    fail "Trivy offline scan returned no CVEs; offline success is not proven."

printf '\nGrype offline scan (DB auto-update disabled)...\n'
docker run --rm --network "$DEMO_NETWORK" \
    -e GRYPE_DB_CACHE_DIR=/bundle/grype-db \
    -e GRYPE_DB_AUTO_UPDATE=false \
    -e GRYPE_REGISTRY_INSECURE_USE_HTTP=true \
    -v "$bundle:/bundle" \
    "$DEMO_RUNTIME_IMAGE" /bundle/bin/grype \
    -c /bundle/grype.yaml "registry:$image_ref" -o json \
    > "$grype_offline_report"
grype_offline_count="$(jq '.matches | length' "$grype_offline_report")"
(( grype_offline_count > 0 )) ||
    fail "Grype offline scan returned no CVEs; offline success is not proven."
printf 'Offline findings: Trivy=%s; Grype=%s\n' "$trivy_offline_count" "$grype_offline_count"

printf '\nForcing Trivy DB update from inside the internal network (failure expected)...\n'
if timeout 45s docker run --rm --network "$DEMO_NETWORK" \
    -v "$bundle:/bundle" \
    "$DEMO_RUNTIME_IMAGE" /bundle/bin/trivy image --download-db-only \
    --cache-dir /tmp/trivy-update-probe --skip-version-check --disable-telemetry \
    --timeout 12s >"$DEMO_DIR/.state/trivy-update-attempt.log" 2>&1; then
    cat "$DEMO_DIR/.state/trivy-update-attempt.log"
    fail "Trivy unexpectedly updated its DB on the internal-only network."
else
    trivy_update_rc=$?
    printf 'Expected failure (exit %s):\n' "$trivy_update_rc"
    tail -n 8 "$DEMO_DIR/.state/trivy-update-attempt.log"
fi

printf '\nForcing Grype DB update from inside the internal network (failure expected)...\n'
if timeout 45s docker run --rm --network "$DEMO_NETWORK" \
    -e GRYPE_DB_CACHE_DIR=/bundle/grype-db \
    -e GRYPE_DB_AUTO_UPDATE=true \
    -e GRYPE_DB_UPDATE_AVAILABLE_TIMEOUT=8s \
    -e GRYPE_DB_UPDATE_DOWNLOAD_TIMEOUT=8s \
    -v "$bundle:/bundle" \
    "$DEMO_RUNTIME_IMAGE" /bundle/bin/grype -c /bundle/grype.yaml db update \
    >"$DEMO_DIR/.state/grype-update-attempt.log" 2>&1; then
    cat "$DEMO_DIR/.state/grype-update-attempt.log"
    fail "Grype unexpectedly updated its DB on the internal-only network."
else
    grype_update_rc=$?
    printf 'Expected failure (exit %s):\n' "$grype_update_rc"
    tail -n 8 "$DEMO_DIR/.state/grype-update-attempt.log"
fi

printf '\nRegistry stays up only on the internal network; no host-published port is needed.\n'
printf 'Total elapsed: %ss\n' "$((SECONDS - started_at))"
printf 'Run scripts/cleanup.sh to remove the registry and network.\n'
presenter_pause
