#!/usr/bin/env bash
set -euo pipefail

download_profile_tools() {
  local archive base
  if [[ $PROFILE == cosign ]]; then
    base="https://github.com/sigstore/cosign/releases/download/v$COSIGN_VERSION"
    if [[ ! -f "$STATE/bin/cosign" ]]; then
      curl --noproxy '*' -fSL "$base/cosign-linux-amd64" -o "$STATE/bin/cosign"
    fi
    echo "$COSIGN_SHA256  $STATE/bin/cosign" | sha256sum -c -
    chmod +x "$STATE/bin/cosign"
    cosign version >"$STATE/evidence/cosign-version.txt"
  fi
  if [[ $PROFILE != notation ]]; then
    archive="oras_${ORAS_VERSION}_linux_amd64.tar.gz"
    if [[ ! -f "$STATE/$archive" ]]; then
      curl --noproxy '*' -fSL "https://github.com/oras-project/oras/releases/download/v$ORAS_VERSION/$archive" -o "$STATE/$archive"
    fi
    echo "$ORAS_SHA256  $STATE/$archive" | sha256sum -c -
    tar -xzf "$STATE/$archive" -C "$STATE/bin" oras
    "$STATE/bin/oras" version >"$STATE/evidence/oras-version.txt"
  fi
  if [[ $PROFILE == sbom ]]; then
    archive="syft_${SYFT_VERSION}_linux_amd64.tar.gz"
    if [[ ! -f "$STATE/$archive" ]]; then
      curl --noproxy '*' -fSL "https://github.com/anchore/syft/releases/download/v$SYFT_VERSION/$archive" -o "$STATE/$archive"
    fi
    echo "$SYFT_SHA256  $STATE/$archive" | sha256sum -c -
    tar -xzf "$STATE/$archive" -C "$STATE/bin" syft
    "$STATE/bin/syft" version >"$STATE/evidence/syft-version.txt"
  fi
}

prepare_notation() {
  rm -f "$STATE/xdg/notation/localkeys/offline-demo.crt" \
    "$STATE/xdg/notation/localkeys/offline-demo.key" \
    "$STATE/xdg/notation/signingkeys.json" \
    "$STATE/xdg/notation/truststore/x509/ca/offline-demo/offline-demo.crt"
  notation cert generate-test --default offline-demo
  cp "$STATE/xdg/notation/localkeys/offline-demo.crt" "$BUNDLE/truststore/x509/ca/offline-demo/root.crt"
  cp "$ROOT/config/trustPolicy.json" "$BUNDLE/trustPolicy.json"
  jq '{notation:{trustPolicies:[.trustPolicies[] |
    {name,level:.signatureVerification.level,registryScopes,trustedIdentities,trustStores:[]}]}}' \
    "$BUNDLE/trustPolicy.json" >"$STATE/trust-values.json"
  notation policy import --force "$BUNDLE/trustPolicy.json"
  printf '%s' "$PASSWORD" | notation login --insecure-registry --username presenter --password-stdin "$ENDPOINT"
}

prepare_cosign() {
  export COSIGN_PASSWORD=''
  export COSIGN_EXPERIMENTAL=1
  rm -f "$STATE/cosign.key" "$STATE/cosign.pub"
  cosign generate-key-pair --output-key-prefix "$STATE/cosign"
  cp "$STATE/cosign.pub" "$BUNDLE/cosign.pub"
  jq -n --arg repository "$REPOSITORY" --rawfile key "$BUNDLE/cosign.pub" \
    '{notation:{enabled:false},cosign:{enabled:true,scopes:[($repository+"@sha256:*")],tLogVerify:false},
      cosignKeys:[$key]}' >"$STATE/trust-values.json"
}

sign_image() {
  if [[ $PROFILE == cosign ]]; then
    cosign sign --yes --key "$STATE/cosign.key" --tlog-upload=false \
      --allow-http-registry --registry-referrers-mode=oci-1-1 "$1"
  else
    notation sign --insecure-registry "$1"
  fi
}

verify_image() {
  if [[ $PROFILE == cosign ]]; then
    cosign verify --key "$BUNDLE/cosign.pub" --offline --insecure-ignore-tlog \
      --allow-http-registry --experimental-oci11 "$1"
  else
    notation verify --insecure-registry "$1"
  fi
}

prepare_sboms() {
  SYFT_CHECK_FOR_APP_UPDATE=false "$STATE/bin/syft" scan "docker-archive:$STATE/original.tar" \
    -o "spdx-json=$STATE/httpbin.spdx.json"
  jq -e '.spdxVersion == "SPDX-2.3" and (.packages | length > 0)' "$STATE/httpbin.spdx.json" >/dev/null \
    || fail "Syft did not produce a nonempty SPDX 2.3 inventory"
  for tag in missing-sbom wrong-subject-sbom untrusted-sbom unsigned-sbom unsigned-with-sbom; do
    registry_copy "$tag" "$tag"
    if [[ $tag != unsigned-with-sbom ]]; then sign_image "$REPOSITORY:$tag"; fi
  done
  # Notation keys are host-only. This second identity is deliberately NOT trusted.
  rm -f "$STATE/xdg/notation/localkeys/untrusted-sbom.crt" \
    "$STATE/xdg/notation/localkeys/untrusted-sbom.key" \
    "$STATE/xdg/notation/truststore/x509/ca/untrusted-sbom/untrusted-sbom.crt"
  notation cert generate-test untrusted-sbom
  for tag in signed tampered wrong-subject-sbom untrusted-sbom unsigned-sbom unsigned-with-sbom; do
    local target=$tag
    if [[ $tag == wrong-subject-sbom ]]; then target=tampered; fi
    (cd "$STATE" && oras attach --plain-http --distribution-spec v1.1-referrers-api \
      --artifact-type application/spdx+json --format json \
      --export-manifest "$STATE/evidence/$tag-sbom-manifest.json" \
      "$REPOSITORY:$target" "httpbin.spdx.json:application/spdx+json") \
      >"$STATE/evidence/$tag-sbom-descriptor.json"
    local digest
    digest="$(jq -r '.digest' "$STATE/evidence/$tag-sbom-descriptor.json")"
    [[ $digest == sha256:* ]] || fail "Missing SBOM artifact digest for $tag"
    case "$tag" in
      unsigned-sbom) ;;
      untrusted-sbom) notation sign --insecure-registry --key untrusted-sbom "$REPOSITORY@$digest" ;;
      *) sign_image "$REPOSITORY@$digest" ;;
    esac
  done
}

record_referrers() {
  local digest=$1 label=$2
  curl --noproxy '*' -fsS -u "presenter:$PASSWORD" \
    "http://$ENDPOINT/v2/demo/httpbin/referrers/$digest" >"$STATE/evidence/$label-referrers.json"
}
