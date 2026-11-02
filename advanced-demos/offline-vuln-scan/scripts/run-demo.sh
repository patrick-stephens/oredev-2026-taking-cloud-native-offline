#!/usr/bin/env bash
set -euo pipefail

# shellcheck disable=SC1091
source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)/common.sh"

started_at=$SECONDS
connected_only=0

if [[ $# -gt 1 || ( $# -eq 1 && "$1" != "--connected-only" ) ]]; then
    printf 'Usage: %s [--connected-only]\n' "$0" >&2
    exit 2
fi
if [[ $# -eq 1 ]]; then
    connected_only=1
fi

require_docker
for command_name in curl tar sha256sum jq timeout date du cut tail install grep uname id; do
    require_command "$command_name"
done

host_os="$(uname -s)"
architecture="$(uname -m)"
if [[ "$host_os" == Darwin && "$architecture" == arm64 ]]; then
    host_release_arch="arm64"
    host_trivy_arch="ARM64"
    host_trivy_platform="macOS"
    host_grype_platform="darwin"
elif [[ "$host_os" == Linux && ( "$architecture" == "x86_64" || "$architecture" == "aarch64" ) ]]; then
    host_release_arch="amd64"
    host_trivy_arch="64bit"
    host_trivy_platform="Linux"
    host_grype_platform="linux"
    if [[ "$architecture" == "aarch64" ]]; then
        host_release_arch="arm64"
        host_trivy_arch="ARM64"
    fi
else
    fail "Supported hosts are Linux x86_64/aarch64 and experimental macOS arm64 (found: $host_os/$architecture)."
fi

target_engine="$(docker info --format '{{.OSType}}/{{.Architecture}}')"
case "$target_engine" in
    linux/amd64|linux/x86_64)
        target_release_arch="amd64"
        target_trivy_arch="64bit"
        ;;
    linux/arm64|linux/aarch64)
        target_release_arch="arm64"
        target_trivy_arch="ARM64"
        ;;
    *) fail "Unsupported Docker Engine platform for offline scanner containers: $target_engine." ;;
esac
[[ "$host_os" != Darwin || "$target_release_arch" == arm64 ]] ||
    fail "Experimental macOS ARM64 support requires a native Linux ARM64 Docker Engine."
export DOCKER_DEFAULT_PLATFORM="linux/$target_release_arch"

phase "CONNECTED: download tools, databases, and image"
docker pull "$DEMO_REGISTRY_IMAGE"
docker pull "$DEMO_SKOPEO_IMAGE"
docker pull "$DEMO_RUNTIME_IMAGE"

if managed_container_exists "$DEMO_REGISTRY"; then
    docker rm --force "$DEMO_REGISTRY" >/dev/null
fi

repair_generated_ownership

mkdir -p "$DEMO_DIR/.work" "$DEMO_DIR/artifacts" "$DEMO_DIR/.state"
rm -f -- "$DEMO_DIR/.state/verification.json" "$DEMO_DIR/.state/trivy-offline.json" \
    "$DEMO_DIR/.state/grype-offline.json" "$DEMO_DIR/.state/trivy-update-attempt.log" \
    "$DEMO_DIR/.state/grype-update-attempt.log" "$DEMO_DIR/.state/egress-probe.log" \
    "$DEMO_DIR/.state/policy-decision.log"
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

printf 'Host platform: %s/%s (scanner architecture: %s)\n' "$host_os" "$architecture" "$host_release_arch"
printf 'Offline container platform: %s\n' "$target_engine"
printf 'Pinned scanners: Trivy %s, Grype %s\n' "$DEMO_TRIVY_VERSION" "$DEMO_GRYPE_VERSION"

trivy_asset="trivy_${DEMO_TRIVY_VERSION#v}_Linux-${target_trivy_arch}.tar.gz"
grype_asset="grype_${DEMO_GRYPE_VERSION#v}_linux_${target_release_arch}.tar.gz"
trivy_checksums="$DEMO_DIR/.work/target-trivy-checksums.txt"
grype_checksums="$DEMO_DIR/.work/target-grype-checksums.txt"
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

host_trivy="$DEMO_BUNDLE/bin/trivy"
host_grype="$DEMO_BUNDLE/bin/grype"
if [[ "$host_os" != Linux || "$host_release_arch" != "$target_release_arch" ]]; then
    host_bin_dir="$DEMO_DIR/.work/host-bin"
    mkdir -p "$host_bin_dir"
    host_trivy_asset="trivy_${DEMO_TRIVY_VERSION#v}_${host_trivy_platform}-${host_trivy_arch}.tar.gz"
    host_grype_asset="grype_${DEMO_GRYPE_VERSION#v}_${host_grype_platform}_${host_release_arch}.tar.gz"
    host_trivy_archive="$DEMO_DIR/.work/$host_trivy_asset"
    host_grype_archive="$DEMO_DIR/.work/$host_grype_asset"
    fetch_release \
        "https://github.com/aquasecurity/trivy/releases/download/$DEMO_TRIVY_VERSION/$host_trivy_asset" \
        "$host_trivy_archive"
    fetch_release \
        "https://github.com/aquasecurity/trivy/releases/download/$DEMO_TRIVY_VERSION/trivy_${DEMO_TRIVY_VERSION#v}_checksums.txt" \
        "$DEMO_DIR/.work/host-trivy-checksums.txt"
    verify_release_asset "$DEMO_DIR/.work/host-trivy-checksums.txt" "$host_trivy_archive"
    fetch_release \
        "https://github.com/anchore/grype/releases/download/$DEMO_GRYPE_VERSION/$host_grype_asset" \
        "$host_grype_archive"
    fetch_release \
        "https://github.com/anchore/grype/releases/download/$DEMO_GRYPE_VERSION/grype_${DEMO_GRYPE_VERSION#v}_checksums.txt" \
        "$DEMO_DIR/.work/host-grype-checksums.txt"
    verify_release_asset "$DEMO_DIR/.work/host-grype-checksums.txt" "$host_grype_archive"
    tar -xzf "$host_trivy_archive" -C "$host_bin_dir" trivy
    tar -xzf "$host_grype_archive" -C "$host_bin_dir" grype
    host_trivy="$host_bin_dir/trivy"
    host_grype="$host_bin_dir/grype"
fi

"$host_trivy" --version
"$host_grype" version

printf '\nChecking transported Linux scanner binaries in the offline runtime...\n'
docker run --rm --pull=never --network none \
    -v "$DEMO_BUNDLE/bin:/scanner-bin:ro" "$DEMO_RUNTIME_IMAGE" /scanner-bin/trivy --version
docker run --rm --pull=never --network none \
    -v "$DEMO_BUNDLE/bin:/scanner-bin:ro" "$DEMO_RUNTIME_IMAGE" /scanner-bin/grype version

printf '\nDownloading Trivy vulnerability DB...\n'
"$host_trivy" image --download-db-only \
    --cache-dir "$DEMO_BUNDLE/trivy-cache" --skip-version-check --disable-telemetry
trivy_db_updated="$(
    jq -r '.UpdatedAt // .updatedAt // empty' "$DEMO_BUNDLE/trivy-cache/db/metadata.json"
)"
[[ -n "$trivy_db_updated" ]] ||
    fail "Trivy DB metadata did not contain an UpdatedAt value."
printf 'Trivy DB published/updated at: %s\n' "$trivy_db_updated"

printf '\nDownloading Grype vulnerability DB...\n'
GRYPE_DB_CACHE_DIR="$DEMO_BUNDLE/grype-db" \
    GRYPE_DB_AUTO_UPDATE=true "$host_grype" db update
grype_db_status="$(
    GRYPE_DB_CACHE_DIR="$DEMO_BUNDLE/grype-db" \
        GRYPE_DB_AUTO_UPDATE=false "$host_grype" db status -o json
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

    "$host_trivy" image --cache-dir "$DEMO_BUNDLE/trivy-cache" \
        --skip-db-update --skip-version-check --disable-telemetry \
        --config '' --ignorefile '' --offline-scan --skip-java-db-update \
        --scanners vuln --image-src docker --format json --output "$trivy_report" "$candidate"
    trivy_count="$(jq '[.Results[]?.Vulnerabilities[]?] | length' "$trivy_report")"

    GRYPE_DB_CACHE_DIR="$DEMO_BUNDLE/grype-db" GRYPE_DB_AUTO_UPDATE=false \
        "$host_grype" -c "$DEMO_BUNDLE/grype.yaml" "docker:$candidate" -o json >"$grype_report"
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
printf 'Selected image: %s\n' "$selected_image"
image_digest="$(docker image inspect --format '{{index .RepoDigests 0}}' "$selected_image")"

printf '\nExporting %s to an OCI layout with Skopeo...\n' "$selected_image"
docker save --output "$DEMO_DIR/.work/candidate-image.tar" "$selected_image"
docker run --rm --user "$(id -u):$(id -g)" \
    --volume "$DEMO_DIR/.work/candidate-image.tar:/candidate-image.tar:ro" \
    --volume "$DEMO_BUNDLE/oci:/oci" \
    "$DEMO_SKOPEO_IMAGE" \
    copy --all "docker-archive:/candidate-image.tar" "oci:/oci/image:offline-vuln-scan"

{
    printf 'tested_at=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    printf 'image=%s\n' "$selected_image"
    printf 'image_digest=%s\n' "$image_digest"
    printf 'trivy_version=%s\n' "$DEMO_TRIVY_VERSION"
    printf 'grype_version=%s\n' "$DEMO_GRYPE_VERSION"
    printf 'host_platform=%s/%s\n' "$host_os" "$host_release_arch"
    printf 'offline_platform=linux/%s\n' "$target_release_arch"
    printf 'trivy_db_updated_at=%s\n' "$trivy_db_updated"
    printf 'grype_db_schema=%s\n' "$grype_schema"
    printf 'grype_db_path=%s\n' "${grype_db_path#"$DEMO_BUNDLE"}"
    printf 'connected_trivy_cve_count=%s\n' "$selected_trivy_count"
    printf 'connected_grype_cve_count=%s\n' "$selected_grype_count"
} > "$DEMO_BUNDLE/metadata.txt"
GRYPE_DB_CACHE_DIR="$DEMO_BUNDLE/grype-db" "$host_grype" db status -o json \
    >"$DEMO_BUNDLE/grype-db-status.json"
(cd "$DEMO_BUNDLE" && sha256sum bin/trivy bin/grype trivy-cache/db/* \
    grype-db/6/* oci/image/index.json grype.yaml metadata.txt grype-db-status.json >SHA256SUMS)

tar -czf "$DEMO_ARCHIVE" -C "$DEMO_DIR" .bundle
sha256sum "$DEMO_ARCHIVE" >"$DEMO_ARCHIVE.sha256"
mkdir -p "$DEMO_STAGE"
tar -xzf "$DEMO_ARCHIVE" -C "$DEMO_STAGE"
rm -rf -- "$DEMO_BUNDLE" "$DEMO_DIR/.work"
bundle="$DEMO_STAGE/.bundle"
(cd "$bundle" && sha256sum --check SHA256SUMS)
printf '\nTransport archive: %s (%s)\n' "$DEMO_ARCHIVE" "$(du -h "$DEMO_ARCHIVE" | cut -f1)"
cat "$bundle/metadata.txt"

show_commands \
    "cat '$bundle/metadata.txt'" \
    "du -sh '$bundle' '$DEMO_ARCHIVE'" \
    "sha256sum --check '$DEMO_ARCHIVE.sha256'"

if [[ "$connected_only" == 1 ]]; then
    printf '\nCONNECTED PASS: scanners, databases, candidate image and transport archive are ready.\n'
    exit 0
fi

presenter_pause
phase "AIR-GAPPED: internal registry, scanners, and update failures"
ensure_internal_network
[[ "$(docker network inspect --format '{{ .Internal }}' "$DEMO_NETWORK")" == "true" ]] ||
    fail "Docker did not create an internal network."

mkdir -p "$DEMO_DIR/.state/registry-data"
docker run --detach --pull=never --user "$(id -u):$(id -g)" \
    --name "$DEMO_REGISTRY" \
    --label "$DEMO_NETWORK_LABEL" \
    --network "$DEMO_NETWORK" \
    --network-alias registry \
    -v "$DEMO_DIR/.state/registry-data:/var/lib/registry" \
    "$DEMO_REGISTRY_IMAGE" >/dev/null

printf 'Internal network: %s (Internal=true)\n' "$DEMO_NETWORK"
show_commands \
    "docker network inspect '$DEMO_NETWORK'" \
    "docker container inspect '$DEMO_REGISTRY'" \
    "docker exec '$DEMO_REGISTRY' wget -qO- http://127.0.0.1:5000/v2/"
offline_run "$DEMO_RUNTIME_IMAGE" sh -ec '
    for attempt in 1 2 3 4 5; do
        if wget -q -O /dev/null http://registry:5000/v2/; then exit 0; fi
        sleep 1
    done
    echo "Registry did not become ready" >&2
    exit 1
'
expect_network_failure "Direct-IP egress probe" "$DEMO_DIR/.state/egress-probe.log" \
    offline_run "$DEMO_RUNTIME_IMAGE" wget -T 3 -t 1 -O /dev/null http://1.1.1.1/
printf 'Importing OCI layout into the isolated registry...\n'
offline_run \
    -v "$bundle:/bundle:ro" \
    "$DEMO_SKOPEO_IMAGE" \
    copy --all "oci:/bundle/oci/image:offline-vuln-scan" \
    --dest-tls-verify=false "docker://registry:5000/demo/scan-target:offline"

image_ref="registry:5000/demo/scan-target:offline"
trivy_offline_report="$DEMO_DIR/.state/trivy-offline.json"
grype_offline_report="$DEMO_DIR/.state/grype-offline.json"

printf '\nTrivy offline scan (DB update explicitly skipped)...\n'
offline_run \
    -v "$bundle:/bundle" \
    "$DEMO_RUNTIME_IMAGE" /bundle/bin/trivy image \
    --cache-dir /bundle/trivy-cache --skip-db-update --skip-version-check \
    --config '' --ignorefile '' --offline-scan --skip-java-db-update \
    --disable-telemetry --scanners vuln --image-src remote --insecure \
    --format json --output /bundle/trivy-offline.json "$image_ref"
cp "$bundle/trivy-offline.json" "$trivy_offline_report"
trivy_offline_count="$(jq '[.Results[]?.Vulnerabilities[]?] | length' "$trivy_offline_report")"
(( trivy_offline_count > 0 )) ||
    fail "Trivy offline scan returned no CVEs; offline success is not proven."

printf '\nGrype offline scan (DB auto-update disabled)...\n'
offline_run \
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
[[ "$trivy_offline_count" == "$selected_trivy_count" && "$grype_offline_count" == "$selected_grype_count" ]] ||
    fail "Offline finding counts differ from connected validation."

trivy_cves="$(jq '[.Results[]?.Vulnerabilities[]?.VulnerabilityID | select(startswith("CVE-"))] | unique | length' "$trivy_offline_report")"
grype_cves="$(jq '[.matches[].vulnerability.id | select(startswith("CVE-"))] | unique | length' "$grype_offline_report")"
printf 'Distinct CVE IDs: Trivy=%s; Grype=%s\n' "$trivy_cves" "$grype_cves"

if jq -e '[.Results[]?.Vulnerabilities[]? | select(.Severity == "HIGH" or .Severity == "CRITICAL")] | length == 0' \
    "$trivy_offline_report" >"$DEMO_DIR/.state/policy-decision.log"; then
    fail "Expected the vulnerable image to fail the HIGH/CRITICAL policy."
else
    policy_rc=$?
    [[ "$policy_rc" == 1 ]] || fail "Policy evaluation failed with unexpected exit $policy_rc."
    printf 'Policy decision: DENY (HIGH/CRITICAL findings; exit 1)\n'
fi

printf '\nForcing Trivy DB update from inside the internal network (failure expected)...\n'
expect_network_failure "Trivy forced update" "$DEMO_DIR/.state/trivy-update-attempt.log" \
    offline_run \
    -v "$bundle:/bundle" \
    "$DEMO_RUNTIME_IMAGE" /bundle/bin/trivy image --download-db-only \
    --cache-dir /tmp/trivy-update-probe --skip-version-check --disable-telemetry \
    --timeout 12s

printf '\nForcing Grype DB update from inside the internal network (failure expected)...\n'
expect_network_failure "Grype forced update" "$DEMO_DIR/.state/grype-update-attempt.log" \
    offline_run \
    -e GRYPE_DB_CACHE_DIR=/tmp/grype-update-probe \
    -e GRYPE_DB_AUTO_UPDATE=true \
    -e GRYPE_DB_UPDATE_AVAILABLE_TIMEOUT=8s \
    -e GRYPE_DB_UPDATE_DOWNLOAD_TIMEOUT=8s \
    -v "$bundle:/bundle" \
    "$DEMO_RUNTIME_IMAGE" /bundle/bin/grype -c /bundle/grype.yaml db update

printf '\nRegistry stays up only on the internal network; no host-published port is needed.\n'
elapsed="$((SECONDS - started_at))"
jq -n --arg tested_at "$(date -u +%FT%TZ)" --arg image "$selected_image" --arg digest "$image_digest" \
    --argjson runtime_seconds "$elapsed" --argjson trivy_findings "$trivy_offline_count" \
    --argjson grype_matches "$grype_offline_count" --argjson trivy_distinct_cves "$trivy_cves" \
    --argjson grype_distinct_cves "$grype_cves" \
    '{tested_at:$tested_at,image:$image,digest:$digest,runtime_seconds:$runtime_seconds,
      trivy_findings:$trivy_findings,grype_matches:$grype_matches,
      trivy_distinct_cves:$trivy_distinct_cves,grype_distinct_cves:$grype_distinct_cves,
      policy:"DENY",direct_ip_egress:"blocked",trivy_update_exit:1,grype_update_exit:1}' \
    >"$DEMO_DIR/.state/verification.json"
show_commands \
        "jq . '$DEMO_DIR/.state/verification.json'" \
        "jq . '$trivy_offline_report'" \
        "jq . '$grype_offline_report'" \
        "cat '$DEMO_DIR/.state/policy-decision.log'" \
        "cat '$DEMO_DIR/.state/egress-probe.log'" \
        "cat '$DEMO_DIR/.state/trivy-update-attempt.log'" \
        "cat '$DEMO_DIR/.state/grype-update-attempt.log'"
printf 'Total elapsed: %ss\n' "$elapsed"
printf 'Run scripts/cleanup.sh to remove the registry and network.\n'
presenter_pause
