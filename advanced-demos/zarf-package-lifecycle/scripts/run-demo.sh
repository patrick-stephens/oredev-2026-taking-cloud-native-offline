#!/usr/bin/env bash
# From this demo directory: ./scripts/run-demo.sh
# Leaves the isolated cluster alive for inspection; ./scripts/cleanup.sh removes it.
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"

cleanup_macos_demos() {
	bash "$DEMO_DIR/../../scripts/cleanup-macos-demos.sh"
}

cleanup() {
	local status=$?
	trap - EXIT
	cleanup_macos_demos || status=1
	exit "$status"
}

if [[ "$(uname -s)" == Darwin ]]; then
	cleanup_macos_demos
	trap cleanup EXIT
	trap 'exit 130' INT
	trap 'exit 143' TERM
fi

started=$SECONDS
bash "$DEMO_DIR/scripts/connected.sh"
bash "$DEMO_DIR/scripts/air-gapped.sh" --trusted-key "$KEYS/cosign.pub"
if [[ "$(uname -s)" == Darwin ]]; then
	printf '\nTOTAL RUNTIME: %ss; demo-owned resources are cleaned on exit.\n' "$((SECONDS-started))"
else
	printf '\nTOTAL RUNTIME: %ss; cluster remains egress-blocked for inspection.\n' "$((SECONDS-started))"
	printf 'Cleanup: ./scripts/cleanup.sh\n'
fi
