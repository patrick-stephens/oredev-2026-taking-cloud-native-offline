#!/usr/bin/env bash
# From demo-bundle: ./scripts/cleanup.sh
# Removes only this demo's Kubernetes cluster, labeled registry storage/network.
# Preserves bundle.tar.gz and ignored keys/ for transport and repeat runs.
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
banner "6 / CLEANUP: remove the disposable air-gapped target"
if docker container inspect "$NODE" >/dev/null 2>&1; then
    assert_target_owned
fi
if docker container inspect "$REGISTRY" >/dev/null 2>&1; then
    [[ "$(docker inspect "$REGISTRY" --format '{{index .Config.Labels "offline-bundle-demo"}}')" == true ]] ||
        die "Refusing to delete an unowned registry."
    docker rm -f "$REGISTRY" >/dev/null
fi
kind delete cluster --name "$CLUSTER" --kubeconfig "$STATE/kubeconfig"
if [[ -f "$STATE/node-id" ]]; then rm -- "$STATE/node-id"; fi
if docker volume inspect offline-bundle-registry >/dev/null 2>&1; then
    [[ "$(docker volume inspect offline-bundle-registry --format '{{index .Labels "offline-bundle-demo"}}')" == true ]] ||
        die "Refusing to delete an unowned registry volume."
    docker volume rm offline-bundle-registry >/dev/null
fi
if docker network inspect "$NETWORK" >/dev/null 2>&1; then
    [[ "$(docker network inspect "$NETWORK" --format '{{index .Labels "offline-bundle-demo"}}')" == true ]] ||
        die "Refusing to delete an unowned network."
    docker network rm "$NETWORK" >/dev/null
fi
printf 'CLEAN: target removed; bundle and signing keys retained locally and gitignored.\n'
