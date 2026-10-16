#!/usr/bin/env bash
# From this demo directory: ./scripts/run-demo.sh
# Leaves the isolated cluster alive for inspection; ./scripts/cleanup.sh removes it.
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
started=$SECONDS
bash "$DEMO_DIR/scripts/connected.sh"
bash "$DEMO_DIR/scripts/air-gapped.sh"
printf '\nTOTAL RUNTIME: %ss; cluster remains egress-blocked for inspection.\n' "$((SECONDS-started))"
printf 'Cleanup: ./scripts/cleanup.sh\n'
