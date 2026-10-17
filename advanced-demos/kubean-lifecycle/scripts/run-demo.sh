#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
START_SECONDS=$SECONDS
PREPARE_ONLY=false
VM_SMOKE=false

case "${1:-}" in
  '') ;;
  --prepare-only) PREPARE_ONLY=true ;;
  --vm-smoke) VM_SMOKE=true ;;
  *) echo "Usage: $0 [--prepare-only|--vm-smoke]" >&2; exit 2 ;;
esac

finish() {
  local status=$?
  trap - EXIT
  printf 'Demo runtime: %s seconds (exit %s)\n' "$((SECONDS - START_SECONDS))" "$status"
  exit "$status"
}
trap finish EXIT

phase() {
  if [[ -t 1 && -n "${TERM:-}" ]]; then
    clear
  fi
  echo "=== PHASE $* ==="
  sleep "${DEMO_PAUSE_SECONDS:-2}"
}

if [[ "$VM_SMOKE" == true ]]; then
  phase '1: CONNECTED - KVM guest network smoke test (bundle preparation skipped)'
  echo "# UNTESTED: Kubean localrelease assembly is skipped by --vm-smoke."
else
  phase '1: CONNECTED - assemble and verify Kubean localrelease bundles'
  "$ROOT/scripts/prepare-bundle.sh"
fi

if [[ "$PREPARE_ONLY" == true ]]; then
  echo "Connected preparation complete. Transfer the bundle before starting the air-gap phase."
  exit 0
fi

echo "Starting the two target VMs with KVM/libvirt while still connected."
"$ROOT/scripts/kvm.sh" up
"$ROOT/scripts/kvm.sh" check-connected

if [[ -t 1 && -n "${TERM:-}" ]]; then
  clear
fi
echo '=== PHASE 2: AIR-GAPPED - no external network on target VMs ==='
sleep "${DEMO_PAUSE_SECONDS:-2}"

"$ROOT/scripts/kvm.sh" disconnect-nat
"$ROOT/scripts/kvm.sh" check-isolation

echo "VM isolation verified. Continue the Kubean lifecycle operations in README.md."
echo "# UNTESTED: Kubean install, httpd verification, and Kubernetes upgrade are runbooked but not executed here."
echo "No cluster success is claimed by this staging script."
