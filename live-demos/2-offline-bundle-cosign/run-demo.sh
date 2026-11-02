#!/usr/bin/env bash
# From live-demos/2-offline-bundle-cosign: ./run-demo.sh [--tamper]
# --tamper proves rejection first, then deploys the original signed bundle.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
source "$ROOT/scripts/common.sh"
[[ $# -le 1 && (${1:-} == "" || ${1:-} == --tamper) ]] ||
    die "Usage: ./run-demo.sh [--tamper]"

cleanup_macos_demos() {
    bash "$ROOT/../../scripts/cleanup-macos-demos.sh"
}

if [[ "$(uname -s)" == Darwin ]]; then
    cleanup_macos_demos
fi

cleanup() {
    local status=$? elapsed
    trap - EXIT
    if [[ "$(uname -s)" == Darwin ]]; then
        cleanup_macos_demos || status=1
    else
        "$DEMO_DIR/scripts/cleanup.sh" || status=1
    fi
    if [[ "$status" == 0 ]]; then
        elapsed=$((SECONDS - started))
        printf '\nTOTAL: %ss including cleanup.\n' "$elapsed"
        [[ "$elapsed" -lt 360 ]] || die "Demo exceeded the six-minute budget; preload tools and retry."
    fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

started=$SECONDS
"$DEMO_DIR/scripts/build-bundle.sh"
advance
"$DEMO_DIR/scripts/prepare-target.sh"
advance
if [[ ${1:-} == --tamper ]]; then
    if "$DEMO_DIR/scripts/verify-import.sh" --trusted-key "$COSIGN_PUB" --tamper; then
        die "Tampered image unexpectedly passed verification."
    else
        [[ $? == 42 ]] || die "Negative test failed for a reason other than detected tampering."
        printf '\nPASS: tampered image rejected before import or deployment.\n'
        advance
    fi
fi
"$DEMO_DIR/scripts/verify-import.sh" --trusted-key "$COSIGN_PUB"
advance
