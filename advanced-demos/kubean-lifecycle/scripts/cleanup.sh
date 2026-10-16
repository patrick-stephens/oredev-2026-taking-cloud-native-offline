#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

if [[ -f "$ROOT/Vagrantfile" ]] && command -v vagrant >/dev/null 2>&1; then
  (cd "$ROOT" && vagrant destroy -f)
fi

if command -v docker >/dev/null 2>&1; then
  docker compose -f "$ROOT/config/services.compose.yaml" down --remove-orphans
fi

rm -f -- "$ROOT/.env"
rm -rf -- "$ROOT/.state" "$ROOT/.work" "$ROOT/artifacts"
printf 'Removed this demo’s VMs, local service data, and generated bundles.\n'
printf 'Shared Docker images and any external Kubean management cluster were left untouched.\n'
