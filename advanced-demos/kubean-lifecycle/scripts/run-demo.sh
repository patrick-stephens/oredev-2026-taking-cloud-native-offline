#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
ARTIFACTS="$ROOT/artifacts"
STATE="$ROOT/.state"
START_SECONDS=$SECONDS
PREPARE_ONLY=false
VMS_AVAILABLE=true
EXIT_STATUS=0

case "${1:-}" in
  '') ;;
  --prepare-only) PREPARE_ONLY=true ;;
  *) echo "Usage: $0 [--prepare-only]" >&2; exit 2 ;;
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

phase '1: CONNECTED - assemble and verify Kubean localrelease bundles'
"$ROOT/scripts/prepare-bundle.sh"

if [[ "$PREPARE_ONLY" == true ]]; then
  echo "Connected preparation complete. Transfer the bundle before starting the air-gap phase."
  exit 0
fi

if [[ ! -r /dev/vboxdrv || ! -w /dev/vboxdrv ]]; then
  VMS_AVAILABLE=false
  echo "VM preflight: /dev/vboxdrv is not readable and writable by this user."
else
  for tool in VBoxManage vagrant; do
    command -v "$tool" >/dev/null || {
      echo "ERROR: missing prerequisite: $tool" >&2
      exit 1
    }
  done
  echo "Starting the two target VMs while still in the connected phase."
  (cd "$ROOT" && vagrant up --provider virtualbox cp1 worker1)
fi

if [[ -t 1 && -n "${TERM:-}" ]]; then
  clear
fi
echo '=== PHASE 2: AIR-GAPPED - no external network on target VMs ==='
sleep "${DEMO_PAUSE_SECONDS:-2}"

if [[ "$VMS_AVAILABLE" != true ]]; then
  echo "# UNTESTED: VM-backed cluster deployment and upgrade cannot run in this sandbox."
  echo "VirtualBox's kernel device is root-only here; the Kubean install/upgrade runbook is in README.md."
  echo "The connected release bundles were assembled and checksum-verified; no cluster success is claimed."
  EXIT_STATUS=2
  exit "$EXIT_STATUS"
fi

mkdir -p "$STATE"
for node in cp1 worker1; do
  VBoxManage controlvm "kubean-lifecycle-$node" setlinkstate1 off
done

for node in cp1 worker1; do
  route="$(cd "$ROOT" && vagrant ssh "$node" -- 'ip route show default')"
  [[ -z "$route" ]] || {
    echo "ERROR: $node still has a default route after disconnecting its NAT adapter:" >&2
    echo "$route" >&2
    exit 1
  }
  if (cd "$ROOT" && vagrant ssh "$node" -- \
    'timeout 5 bash -c "</dev/tcp/1.1.1.1/443"' >/dev/null 2>&1); then
    echo "ERROR: $node reached an external IP during the air-gapped phase." >&2
    exit 1
  fi
  echo "Expected isolation: $node has no default route and cannot open 1.1.1.1:443."
done

echo "VM isolation verified. Continue the Kubean lifecycle operations in README.md."
echo "# UNTESTED: Kubean install, httpd verification, and Kubernetes upgrade are runbooked but not executed here."
echo "No cluster success is claimed by this staging script."
