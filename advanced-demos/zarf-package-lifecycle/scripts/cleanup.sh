#!/usr/bin/env bash
# ./scripts/cleanup.sh: removes ONLY this demo's k3d cluster and its storage.
# Archives, SBOM evidence and locally installed CLIs remain for reuse.
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
phase "CLEANUP: remove the disposable cluster (and its firewall namespace)"
if docker container inspect "$NODE" >/dev/null 2>&1; then
    assert_owned
    KUBECONFIG="$STATE/kubeconfig" "$TOOLS/k3d" cluster delete "$CLUSTER"
fi
if [[ -f "$STATE/node-id" ]]; then rm -- "$STATE/node-id"; fi
printf 'CLEAN: no host firewall rules or default kubeconfig were changed.\n'
