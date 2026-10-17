#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../config/versions.env
source "$ROOT/config/versions.env"
MANAGER_KUBECONFIG="${MANAGER_KUBECONFIG:-$ROOT/.state/manager.kubeconfig}"

if [[ "${1:-}" != --yes || $# != 1 ]]; then
  echo "Usage: $0 --yes" >&2
  echo "Destructive: removes the two demo VMs, their disks, local artifacts, and the demo's manager resources." >&2
  echo "The management cluster and unrelated resources are retained. Preserve logs before confirming." >&2
  exit 2
fi

for tool in virsh docker flock; do
  command -v "$tool" >/dev/null || { echo "ERROR: missing prerequisite: $tool" >&2; exit 1; }
done
mkdir -p "$ROOT/.state"
exec 9>"$ROOT/.state/run.lock"
flock -n 9 || { echo "ERROR: an orchestrator is using this state; stop it before cleanup." >&2; exit 1; }

if [[ -s "$MANAGER_KUBECONFIG" ]]; then
  for tool in kubectl jq; do
    command -v "$tool" >/dev/null || { echo "ERROR: missing prerequisite: $tool" >&2; exit 1; }
  done
  active="$(kubectl --kubeconfig "$MANAGER_KUBECONFIG" get clusteroperations -o json |
    jq '[.items[] | select(.spec.cluster == "kubean-lifecycle") |
      select(.status.status != "Succeeded" and .status.status != "Failed")] | length')"
  [[ "$active" == 0 ]] || { echo "ERROR: a demo operation is still active; inspect it before cleanup." >&2; exit 1; }
  kubectl --kubeconfig "$MANAGER_KUBECONFIG" delete cluster kubean-lifecycle --ignore-not-found --wait=true
  kubectl --kubeconfig "$MANAGER_KUBECONFIG" -n kubean-system delete configmap \
    kubean-lifecycle-hosts kubean-lifecycle-vars kubean-lifecycle-kubeconf --ignore-not-found
  kubectl --kubeconfig "$MANAGER_KUBECONFIG" -n kubean-system delete secret kubean-lifecycle-ssh --ignore-not-found
else
  echo "WARNING: manager kubeconfig unavailable; remove stale kubean-lifecycle resources on the manager before rebuilding." >&2
fi

"$ROOT/scripts/kvm.sh" destroy
docker compose -f "$ROOT/config/services.compose.yaml" down --remove-orphans
rm -f -- "$ROOT/.env"
generated=()
mounts=()
for directory in .state .work artifacts; do
  if [[ -d "$ROOT/$directory" ]]; then
    [[ ! -L "$ROOT/$directory" ]] || { echo "ERROR: refusing generated-directory symlink: $directory" >&2; exit 1; }
    generated+=("$ROOT/$directory")
    mounts+=(--mount "type=bind,src=$ROOT/$directory,dst=/cleanup/$directory")
  fi
done
if (( ${#generated[@]} )); then
  if find "${generated[@]}" ! -writable -print -quit | grep -q .; then
    docker image inspect "$FILES_IMAGE" >/dev/null
    docker run --rm --pull=never --network none --user 0:0 \
      "${mounts[@]}" --entrypoint sh "$FILES_IMAGE" -ec \
      'find /cleanup -mindepth 2 -delete'
  fi
  rm -rf -- "${generated[@]}"
fi
printf 'Removed this demo VMs, local service data, and generated bundles.\n'
printf 'Shared Docker images, the management cluster, and unrelated manager resources were retained.\n'
