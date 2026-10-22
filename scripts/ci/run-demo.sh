#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)"
DEMO_ID="${1:-}"
provisioned=false

usage() {
    printf 'Usage: %s {live-1|live-2|adv-01|...|adv-11}\n' "$0" >&2
    printf 'adv-12 is excluded because it requires an external Kubean manager cluster.\n' >&2
    exit 2
}

case "$DEMO_ID" in
    live-1|live-2|adv-01|adv-02|adv-03|adv-04|adv-05|adv-06|adv-07|adv-08|adv-09|adv-10|adv-11) ;;
    *) usage ;;
esac

cleanup_demo() {
    case "$DEMO_ID" in
        live-1) "$ROOT/live-demos/1-pull-through-cache-zot/scripts/stop-cache.sh" ;;
        live-2) "$ROOT/live-demos/2-offline-bundle-cosign/scripts/cleanup.sh" ;;
        adv-01) "$ROOT/advanced-demos/zarf-package-lifecycle/scripts/cleanup.sh" ;;
        adv-02) "$ROOT/advanced-demos/spegel-p2p/scripts/cleanup.sh" ;;
        adv-03) "$ROOT/advanced-demos/oras-oci-referrers/scripts/cleanup.sh" ;;
        adv-04) "$ROOT/advanced-demos/ratify-notation-policy/scripts/cleanup.sh" ;;
        adv-05) "$ROOT/advanced-demos/offline-vuln-scan/scripts/cleanup.sh" ;;
        adv-06) "$ROOT/advanced-demos/k3s-airgap/scripts/cleanup.sh" ;;
        adv-07) "$ROOT/advanced-demos/offline-gitops-flux/scripts/cleanup.sh" ;;
        adv-08) "$ROOT/advanced-demos/dependency-mirrors/scripts/cleanup.sh" ;;
        adv-09) "$ROOT/advanced-demos/multi-arch-bundle/scripts/cleanup.sh" ;;
        adv-10) "$ROOT/advanced-demos/apko-melange-offline/scripts/cleanup.sh" ;;
        adv-11) "$ROOT/advanced-demos/harbor-dragonfly-preheat/scripts/cleanup.sh" --reset ;;
    esac
}

on_exit() {
    local run_status=$? cleanup_status=0
    trap - EXIT
    if [[ "$provisioned" == true ]]; then
        set +e
        cleanup_demo
        cleanup_status=$?
        set -e
        if (( cleanup_status != 0 )); then
            printf 'Demo cleanup failed with exit code %s.\n' "$cleanup_status" >&2
            (( run_status != 0 )) || run_status=$cleanup_status
        fi
    fi
    exit "$run_status"
}
trap on_exit EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

printf 'Provisioning prerequisites for %s.\n' "$DEMO_ID"
"$ROOT/scripts/provision-host.sh" --only "$DEMO_ID"
provisioned=true

export DEMO_AUTO_ADVANCE=1
export DEMO_PAUSE_SECONDS=0
export DEMO_SLEEP_SECONDS=0

case "$DEMO_ID" in
    live-1)
        (
            cd "$ROOT/live-demos/1-pull-through-cache-zot"
            ./scripts/start-cache.sh
            ./scripts/prime-cache.sh
            ./scripts/verify-cache.sh
        )
        ;;
    live-2)
        "$ROOT/live-demos/2-offline-bundle-cosign/run-demo.sh" --tamper
        ;;
    adv-01)
        "$ROOT/advanced-demos/zarf-package-lifecycle/scripts/run-demo.sh"
        ;;
    adv-02)
        "$ROOT/advanced-demos/spegel-p2p/scripts/run-demo.sh"
        ;;
    adv-03)
        "$ROOT/advanced-demos/oras-oci-referrers/scripts/run-demo.sh"
        ;;
    adv-04)
        "$ROOT/advanced-demos/ratify-notation-policy/scripts/run-demo.sh" --all
        ;;
    adv-05)
        "$ROOT/advanced-demos/offline-vuln-scan/scripts/run-demo.sh"
        ;;
    adv-06)
        "$ROOT/advanced-demos/k3s-airgap/scripts/run-demo.sh"
        "$ROOT/advanced-demos/k3s-airgap/scripts/run-demo.sh" --k0s
        ;;
    adv-07)
        "$ROOT/advanced-demos/offline-gitops-flux/scripts/run-demo.sh"
        "$ROOT/advanced-demos/offline-gitops-flux/scripts/run-demo.sh" --argocd
        ;;
    adv-08)
        "$ROOT/advanced-demos/dependency-mirrors/scripts/run-demo.sh"
        ;;
    adv-09)
        "$ROOT/advanced-demos/multi-arch-bundle/scripts/run-demo.sh"
        ;;
    adv-10)
        "$ROOT/advanced-demos/apko-melange-offline/scripts/run-demo.sh"
        ;;
    adv-11)
        "$ROOT/advanced-demos/harbor-dragonfly-preheat/scripts/run-demo.sh"
        ;;
esac
