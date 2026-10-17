#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../config/versions.env
source "$ROOT/config/versions.env"

START_SECONDS=$SECONDS
PREPARE_ONLY=false
VM_SMOKE=false
MANAGER_KUBECONFIG="${MANAGER_KUBECONFIG:-$ROOT/.state/manager.kubeconfig}"
TARGET_KUBECONFIG="$ROOT/.state/target.kubeconfig"
SSH_KEY="$ROOT/.state/ssh/id_ed25519"
PAUSE_SECONDS="${DEMO_PAUSE_SECONDS:-2}"

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
  sleep "$PAUSE_SECONDS"
}

require() {
  local tool
  for tool in "$@"; do
    command -v "$tool" >/dev/null || {
      echo "ERROR: missing prerequisite: $tool" >&2
      exit 1
    }
  done
}

mctl() {
  kubectl --kubeconfig "$MANAGER_KUBECONFIG" "$@"
}

tctl() {
  kubectl --kubeconfig "$TARGET_KUBECONFIG" "$@"
}

wait_clusteroperation() {
  local name="$1"
  local timeout_seconds="$2"
  local elapsed=0
  local status

  while (( elapsed < timeout_seconds )); do
    status="$(mctl get clusteroperation "$name" -o jsonpath='{.status.status}' 2>/dev/null || true)"
    printf '%s status after %ss: %s\n' "$name" "$elapsed" "${status:-Pending}"
    case "$status" in
      Succeeded) return 0 ;;
      Failed)
        mctl get clusteroperation "$name" -o yaml
        return 1
        ;;
    esac
    sleep 10
    elapsed=$((elapsed + 10))
  done

  echo "ERROR: timed out waiting for $name" >&2
  return 1
}

ensure_manager_prereqs() {
  require kubectl docker curl
  [[ -s "$MANAGER_KUBECONFIG" ]] || {
    echo "ERROR: expected management kubeconfig at $MANAGER_KUBECONFIG" >&2
    echo "Set MANAGER_KUBECONFIG or create $ROOT/.state/manager.kubeconfig first." >&2
    exit 1
  }
  [[ -s "$SSH_KEY" ]] || {
    echo "ERROR: missing demo SSH key $SSH_KEY; run the VM phase first." >&2
    exit 1
  }
}

save_target_kubeconfig() {
  umask 077
  mctl -n kubean-system get configmap kubean-lifecycle-kubeconf \
    -o jsonpath='{.data.config}' > "$TARGET_KUBECONFIG"
  chmod 600 "$TARGET_KUBECONFIG"
}

prepare_manager_cluster() {
  mctl -n kubean-system create secret generic kubean-lifecycle-ssh \
    --type=kubernetes.io/ssh-auth \
    --from-file=ssh-privatekey="$SSH_KEY" \
    --dry-run=client -o yaml | mctl apply -f -
  mctl apply -f "$ROOT/config/hosts.yaml"
  mctl apply -f "$ROOT/config/cluster.yaml"
  mctl apply -f "$ROOT/config/manager-egress-policy.yaml"
}

reset_operation() {
  local name="$1"
  mctl -n kubean-system delete job "kubean-$name-job" --ignore-not-found --wait=true >/dev/null 2>&1 || true
  mctl delete clusteroperation "$name" --ignore-not-found --wait=true >/dev/null 2>&1 || true
}

verify_httpd() {
  tctl -n lifecycle-demo rollout status deployment/httpd --timeout=180s
  tctl -n lifecycle-demo get pods -o wide
  curl --fail --silent --show-error --max-time 10 http://192.168.56.12:30080/ | head -8
}

phase '1: CONNECTED - assemble and verify Kubean localrelease bundles'
"$ROOT/scripts/prepare-bundle.sh"

if [[ "$PREPARE_ONLY" == true ]]; then
  echo "Connected preparation complete. Transfer the bundle before starting the air-gap phase."
  exit 0
fi

phase '2: CONNECTED - boot target VMs and prove upstream connectivity'
"$ROOT/scripts/kvm.sh" up
"$ROOT/scripts/kvm.sh" check-connected

if [[ "$VM_SMOKE" == true ]]; then
  phase '3: AIR-GAPPED - block external egress while preserving the private lab network'
  "$ROOT/scripts/kvm.sh" isolate-egress
  "$ROOT/scripts/kvm.sh" check-isolation
  echo "NOTE: --vm-smoke stops before local services, Kubean install, and upgrade."
  exit 0
fi

phase '3: CONNECTED - load local services and stage/import offline artifacts'
ensure_manager_prereqs
  docker image load --input "$ROOT/artifacts/artifact-services.tar" >/dev/null
  docker compose -f "$ROOT/config/services.compose.yaml" up -d --pull never
"$ROOT/scripts/stage-artifacts.sh"
"$ROOT/scripts/import-images.sh"

phase '4: AIR-GAPPED - keep the private lab network, block external egress'
"$ROOT/scripts/kvm.sh" isolate-egress
"$ROOT/scripts/kvm.sh" check-isolation
"$ROOT/scripts/configure-guest-apt.sh" "$BASE_KUBEAN_VERSION"

phase "5: AIR-GAPPED - install Kubernetes $BASE_KUBERNETES_VERSION from $BASE_KUBEAN_VERSION"
prepare_manager_cluster
mctl apply -f "$ROOT/artifacts/kubean/$BASE_KUBEAN_VERSION/localartifactset.cr.yaml"
mctl apply -f "$ROOT/config/vars-v1.yaml"
reset_operation kubean-lifecycle-install
mctl apply -f "$ROOT/config/install-operation.yaml"
wait_clusteroperation kubean-lifecycle-install 1800
save_target_kubeconfig
tctl get nodes -o wide

phase '6: AIR-GAPPED - verify httpd and prove workload egress is denied'
tctl apply -f "$ROOT/config/httpd.yaml"
tctl delete pod -n lifecycle-demo egress-probe --ignore-not-found=true
tctl run egress-probe -n lifecycle-demo \
  --image=192.168.56.1:5000/library/busybox:1.37.0 \
  --image-pull-policy=IfNotPresent \
  --restart=Never --command -- sleep 1800
tctl wait -n lifecycle-demo --for=condition=Ready pod/egress-probe --timeout=90s
tctl exec -n lifecycle-demo egress-probe -- \
  wget -T 5 -qO- "http://192.168.56.1:8080/kubean/ubuntu/$BASE_KUBEAN_VERSION/Packages.gz" >/dev/null
verify_httpd
tctl apply -f "$ROOT/config/target-egress-policy.yaml"
if tctl exec -n lifecycle-demo egress-probe -- \
  wget -T 5 -qO- "http://192.168.56.1:8080/kubean/ubuntu/$BASE_KUBEAN_VERSION/Packages.gz" >/dev/null 2>&1; then
  echo "ERROR: target NetworkPolicy did not block pod egress to the local artifact service" >&2
  exit 1
fi
echo "Expected result: target NetworkPolicy blocks pod egress to the local artifact service."

phase "7: AIR-GAPPED - upgrade from $BASE_KUBEAN_VERSION/$BASE_KUBERNETES_VERSION to $UPGRADE_KUBEAN_VERSION/$UPGRADE_KUBERNETES_VERSION"
"$ROOT/scripts/configure-guest-apt.sh" "$UPGRADE_KUBEAN_VERSION"
mctl apply -f "$ROOT/artifacts/kubean/$UPGRADE_KUBEAN_VERSION/localartifactset.cr.yaml"
mctl apply -f "$ROOT/config/vars-v2.yaml"
reset_operation kubean-lifecycle-upgrade
mctl apply -f "$ROOT/config/upgrade-operation.yaml"
wait_clusteroperation kubean-lifecycle-upgrade 1800

phase '8: AIR-GAPPED - verify the upgraded cluster and preserved workload'
tctl get nodes -o wide
verify_httpd
"$ROOT/scripts/kvm.sh" check-isolation
tctl delete pod -n lifecycle-demo egress-probe --ignore-not-found=true

echo "Lifecycle verification complete: install, httpd validation, egress policy, and upgrade all succeeded."
