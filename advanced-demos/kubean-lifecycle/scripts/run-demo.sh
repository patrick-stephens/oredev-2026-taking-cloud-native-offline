#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../config/versions.env
source "$ROOT/config/versions.env"
START_SECONDS=$SECONDS
MODE=connected
RECONCILE_UPGRADE=false
MANAGER_KUBECONFIG="${MANAGER_KUBECONFIG:-$ROOT/.state/manager.kubeconfig}"
TARGET_KUBECONFIG="$ROOT/.state/target.kubeconfig"
PAUSE_SECONDS="${DEMO_PAUSE_SECONDS:-2}"
PROBE_NAMESPACE=lifecycle-egress-check
OPERATION=
NODE_STATE=empty

fail() { echo "ERROR: $*" >&2; exit 1; }
usage() {
  echo "Usage: $0 [--prepare-only|--vm-smoke|--offline|--verify-only] [--reconcile-upgrade]"
}
while (( $# )); do
  case "$1" in
    --prepare-only|--vm-smoke|--offline|--verify-only)
      [[ "$MODE" == connected ]] || { usage >&2; exit 2; }
      MODE="${1#--}"
      ;;
    --reconcile-upgrade) RECONCILE_UPGRADE=true ;;
    --help) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done
if [[ "$RECONCILE_UPGRADE" == true && "$MODE" != connected && "$MODE" != offline ]]; then
  fail "--reconcile-upgrade requires the connected or --offline lifecycle mode"
fi

finish() {
  local status=$?
  trap - EXIT
  if (( status != 0 )); then
    echo "Stopped without cleaning VMs or operation evidence. Fix the error and resume with --offline." >&2
    if [[ -n "$OPERATION" ]]; then
      echo "Inspect: kubectl --kubeconfig '$MANAGER_KUBECONFIG' get clusteroperation '$OPERATION' -o yaml" >&2
    fi
  fi
  printf 'Demo runtime: %s seconds (exit %s)\n' "$((SECONDS - START_SECONDS))" "$status"
  exit "$status"
}
trap finish EXIT

phase() {
  if [[ -t 1 && -n "${TERM:-}" ]]; then clear; fi
  echo "=== PHASE $* ==="
  sleep "$PAUSE_SECONDS"
}
require() {
  local tool
  for tool in "$@"; do command -v "$tool" >/dev/null || fail "missing prerequisite: $tool"; done
}
mctl() { kubectl --kubeconfig "$MANAGER_KUBECONFIG" "$@"; }
tctl() { kubectl --kubeconfig "$TARGET_KUBECONFIG" "$@"; }
guest() {
  local address="$1"
  shift
  ssh -i "$ROOT/.state/ssh/id_ed25519" -o BatchMode=yes -o ConnectTimeout=5 \
    -o StrictHostKeyChecking=accept-new \
    -o "UserKnownHostsFile=$ROOT/.state/ssh/known_hosts" "vagrant@$address" "$@"
}

manager_preflight() {
  [[ -s "$MANAGER_KUBECONFIG" ]] || fail "set MANAGER_KUBECONFIG to a pre-provisioned Kubean management cluster"
  mctl get crd clusters.kubean.io clusteroperations.kubean.io >/dev/null
  mctl -n kubean-system rollout status deployment/kubean --timeout=90s
  mctl -n kubean-system rollout status deployment/kubean-admission --timeout=90s
  [[ "$(mctl get clusteroperations -o json | jq '[.items[] |
    select(.spec.cluster == "kubean-lifecycle") |
    select(.status.status != "Succeeded" and .status.status != "Failed")] | length')" == 0 ]] ||
    fail "a lifecycle operation is still active; inspect it before starting another"
}

target_state() {
  local config nodes names versions rc
  config="$(mctl -n kubean-system get configmap kubean-lifecycle-kubeconf \
    --ignore-not-found -o jsonpath='{.data.config}')"
  if [[ -n "$config" ]]; then
    (umask 077; printf '%s\n' "$config" > "$TARGET_KUBECONFIG")
  else
    if guest 192.168.56.11 sudo test -s /etc/kubernetes/admin.conf; then
      (umask 077; guest 192.168.56.11 sudo cat /etc/kubernetes/admin.conf |
        kubectl config view --kubeconfig=/dev/stdin --raw -o json |
        jq '.clusters[].cluster.server = "https://192.168.56.11:6443"' > "$TARGET_KUBECONFIG")
    else
      rc=$?
      [[ "$rc" == 1 ]] || fail "cannot inspect cp1 (SSH exit $rc); refusing to assume it is empty"
      NODE_STATE=empty
      return
    fi
  fi
  chmod 600 "$TARGET_KUBECONFIG"
  nodes="$(tctl get nodes -o json)"
  names="$(jq -c '[.items[].metadata.name] | sort' <<< "$nodes")"
  [[ "$names" == '["cp1","worker1"]' ]] || fail "unexpected target inventory $names; refusing install/downgrade"
  versions="$(jq -r '.items[].status.nodeInfo.kubeletVersion' <<< "$nodes" | sort -u)"
  case "$versions" in
    "v$BASE_KUBERNETES_VERSION") NODE_STATE=base ;;
    "v$UPGRADE_KUBERNETES_VERSION") NODE_STATE=upgraded ;;
    "v$BASE_KUBERNETES_VERSION"$'\n'"v$UPGRADE_KUBERNETES_VERSION") NODE_STATE=mixed ;;
    *) fail "unsupported target versions: $versions; refusing install/downgrade" ;;
  esac
  echo "Existing target state: $NODE_STATE (never reinstall the base version over an upgraded node)."
}

run_operation() {
  local manifest="$1" status end=$((SECONDS + 1800))
  OPERATION="$(mctl create --dry-run=client -f "$manifest" -o json |
    jq '.metadata.generateName = (.metadata.name + "-") | del(.metadata.name)' |
    mctl create -f - -o jsonpath='{.metadata.name}')"
  while (( SECONDS < end )); do
    status="$(mctl get clusteroperation "$OPERATION" -o jsonpath='{.status.status}')"
    printf '%s: %s\n' "$OPERATION" "${status:-Pending}"
    case "$status" in
      Succeeded) return ;;
      Failed)
        mctl -n kubean-system logs "job/kubean-$OPERATION-job" --tail=100
        fail "$OPERATION failed"
        ;;
    esac
    sleep 10
  done
  fail "timed out waiting for $OPERATION; it was not deleted or automatically retried"
}

verify_nodes() {
  local expected="$1" nodes
  nodes="$(tctl get nodes -o json)"
  jq -e --arg version "v$expected" '
    (.items | length) == 2 and all(.items[];
      .status.nodeInfo.kubeletVersion == $version and
      any(.status.conditions[]; .type == "Ready" and .status == "True"))
  ' <<< "$nodes" >/dev/null || fail "expected exactly two Ready nodes at v$expected"
  tctl get nodes -o wide
}

verify_httpd() {
  local response
  tctl -n lifecycle-demo rollout status deployment/httpd --timeout=180s
  [[ "$(tctl -n lifecycle-demo get deployment httpd -o json |
    jq '.status.availableReplicas')" == 2 ]] || fail "httpd does not have two available replicas"
  response="$(curl --fail --silent --show-error --max-time 10 http://192.168.56.12:30080/)"
  grep -Fq 'It works!' <<< "$response" || fail "NodePort did not return the expected Apache page"
  echo 'httpd: 2/2 available; private NodePort returns It works!'
}

probe_blocked() {
  local kubeconfig="$1" namespace="$2" url="$3" result
  # shellcheck disable=SC2016
  result="$(kubectl --kubeconfig "$kubeconfig" exec -n "$namespace" egress-probe -- \
    sh -c 'if wget -T 5 -qO /dev/null "$1"; then echo EGRESS_ALLOWED; else echo EGRESS_BLOCKED; fi' sh "$url")"
  [[ "$result" == EGRESS_BLOCKED ]] || fail "unexpected egress result from $namespace: $result"
}

verify_target_policy() {
  local url="http://192.168.56.1:8080/kubean/ubuntu/$UPGRADE_KUBEAN_VERSION/Packages.gz"
  tctl create namespace "$PROBE_NAMESPACE" --dry-run=client -o yaml | tctl apply -f -
  tctl -n "$PROBE_NAMESPACE" delete networkpolicy deny-egress --ignore-not-found
  tctl -n "$PROBE_NAMESPACE" delete pod egress-probe --ignore-not-found --wait=true
  tctl -n "$PROBE_NAMESPACE" run egress-probe \
    --image=192.168.56.1:5000/library/busybox:1.37.0 \
    --image-pull-policy=IfNotPresent --restart=Never --command -- sleep 3600
  tctl -n "$PROBE_NAMESPACE" wait --for=condition=Ready pod/egress-probe --timeout=90s
  tctl -n "$PROBE_NAMESPACE" exec egress-probe -- wget -T 5 -qO /dev/null "$url"
  probe_blocked "$TARGET_KUBECONFIG" "$PROBE_NAMESPACE" http://1.1.1.1/
  tctl create --dry-run=client -f "$ROOT/config/target-egress-policy.yaml" -o json |
    jq --arg ns "$PROBE_NAMESPACE" '.metadata.namespace = $ns' | tctl apply -f -
  sleep 2
  probe_blocked "$TARGET_KUBECONFIG" "$PROBE_NAMESPACE" "$url"
  tctl apply -f "$ROOT/config/target-egress-policy.yaml"
  echo 'Target egress: local HTTP reachable before policy, blocked after policy; public HTTP blocked.'
  tctl -n "$PROBE_NAMESPACE" delete pod egress-probe --wait=true
}

manager_policy() {
  local addresses
  addresses="$(mctl get endpointslice -n default -l kubernetes.io/service-name=kubernetes -o json |
    jq '[.items[].endpoints[].addresses[]] | unique')"
  jq -e 'length > 0 and all(.[]; test("^(10\\.|192\\.168\\.|172\\.(1[6-9]|2[0-9]|3[01])\\.)"))' \
    <<< "$addresses" >/dev/null || fail "manager API must resolve to private IPv4 endpoints: $addresses"
  mctl create --dry-run=client -f "$ROOT/config/manager-egress-policy.yaml" -o json |
    jq --argjson addresses "$addresses" '
      .spec.egress[0].to = [.spec.egress[0].to[] | select(.ipBlock.cidr != "172.18.0.2/32")] +
      [$addresses[] | {ipBlock: {cidr: (. + "/32")}}]' | mctl apply -f -
  mctl -n kubean-system delete pod egress-probe --ignore-not-found --wait=true
  mctl -n kubean-system run egress-probe --image="$BUSYBOX_IMAGE" \
    --image-pull-policy=Never --restart=Never --command -- sleep 3600
  mctl -n kubean-system wait --for=condition=Ready pod/egress-probe --timeout=90s
  # shellcheck disable=SC2016
  mctl -n kubean-system exec egress-probe -- sh -ec \
    'for host in 192.168.56.11 192.168.56.12; do nc -z -w 5 "$host" 22; done
     wget -T 5 -qO /dev/null http://192.168.56.1:5000/v2/
     wget -T 5 -qO /dev/null http://192.168.56.1:8080/kubean/ubuntu/v0.34.2/Packages.gz'
  probe_blocked "$MANAGER_KUBECONFIG" kubean-system http://1.1.1.1/
  mctl -n kubean-system delete pod egress-probe --wait=true
  echo 'Manager egress: local SSH/HTTP allowed; public HTTP blocked.'
}

require flock
mkdir -p "$ROOT/.state"
exec 9>"$ROOT/.state/run.lock"
flock -n 9 || fail "another demo run is using this state directory"

if [[ "$MODE" == prepare-only ]]; then
  phase '1: CONNECTED - assemble and verify transfer bundle'
  "$ROOT/scripts/prepare-bundle.sh"
  exit 0
fi
if [[ "$MODE" != vm-smoke ]]; then
  require kubectl jq docker curl ssh
  manager_preflight
fi
if [[ "$MODE" == connected || "$MODE" == vm-smoke ]]; then
  phase '1: CONNECTED - boot VMs and prove upstream connectivity'
  "$ROOT/scripts/kvm.sh" up
  "$ROOT/scripts/kvm.sh" connect-egress
  "$ROOT/scripts/kvm.sh" check-connected
  if [[ "$MODE" == connected ]]; then "$ROOT/scripts/prepare-bundle.sh"; fi
fi
if [[ "$MODE" == vm-smoke ]]; then
  phase '2: AIR-GAPPED - verify persistent VM egress filters (no bundle or Kubean)'
  "$ROOT/scripts/kvm.sh" isolate-egress
  "$ROOT/scripts/kvm.sh" check-isolation
  exit 0
fi

phase '2: AIR-GAPPED - apply VM isolation before loading local artifacts'
"$ROOT/scripts/kvm.sh" isolate-egress
"$ROOT/scripts/kvm.sh" check-isolation
if [[ "$MODE" != verify-only ]]; then
  (cd "$ROOT/artifacts"; sha256sum --check SHA256SUMS)
  docker image load --input "$ROOT/artifacts/artifact-services.tar" >/dev/null
  mkdir -p "$ROOT/.state/files/kubean"
  printf 'ready\n' > "$ROOT/.state/files/healthz"
  docker compose -f "$ROOT/config/services.compose.yaml" up -d --pull never
  for attempt in {1..30}; do
    if curl -fsS --max-time 2 http://192.168.56.1:5000/v2/ >/dev/null &&
      curl -fsS --max-time 2 -o /dev/null http://192.168.56.1:8080/healthz; then break; fi
    (( attempt != 30 )) || fail "local artifact services did not become ready"
    sleep 2
  done
  "$ROOT/scripts/stage-artifacts.sh"
  "$ROOT/scripts/import-images.sh"
fi
manager_policy
target_state
if [[ "$MODE" == verify-only ]]; then
  [[ "$NODE_STATE" == upgraded ]] || fail "--verify-only requires the upgraded two-node cluster"
else
  phase '3: AIR-GAPPED - install only when the target is empty'
  if [[ "$NODE_STATE" == empty ]]; then
    "$ROOT/scripts/configure-guest-apt.sh" "$BASE_KUBEAN_VERSION"
    mctl -n kubean-system create secret generic kubean-lifecycle-ssh \
      --type=kubernetes.io/ssh-auth --from-file=ssh-privatekey="$ROOT/.state/ssh/id_ed25519" \
      --dry-run=client -o yaml | mctl apply -f -
    mctl apply -f "$ROOT/config/hosts.yaml"
    mctl apply -f "$ROOT/config/vars-v1.yaml"
    mctl apply -f "$ROOT/config/cluster.yaml"
    mctl apply -f "$ROOT/artifacts/kubean/$BASE_KUBEAN_VERSION/localartifactset.cr.yaml"
    run_operation "$ROOT/config/install-operation.yaml"
    target_state
    verify_nodes "$BASE_KUBERNETES_VERSION"
  else
    echo "Skipping base install: target state is $NODE_STATE."
  fi
fi

phase '4: AIR-GAPPED - verify official httpd and actual policy enforcement'
tctl apply -f "$ROOT/config/httpd.yaml"
verify_httpd
verify_target_policy
if [[ "$MODE" != verify-only && ( "$NODE_STATE" != upgraded || "$RECONCILE_UPGRADE" == true ) ]]; then
  phase '5: AIR-GAPPED - upgrade with the full network role enabled'
  "$ROOT/scripts/configure-guest-apt.sh" "$UPGRADE_KUBEAN_VERSION"
  mctl apply -f "$ROOT/artifacts/kubean/$UPGRADE_KUBEAN_VERSION/localartifactset.cr.yaml"
  mctl apply -f "$ROOT/config/vars-v2.yaml"
  run_operation "$ROOT/config/upgrade-operation.yaml"
fi

phase '6: AIR-GAPPED - verify final version, workload, and isolation'
verify_nodes "$UPGRADE_KUBERNETES_VERSION"
verify_httpd
verify_target_policy
"$ROOT/scripts/kvm.sh" check-isolation
echo 'Lifecycle verification complete: both nodes Ready at the expected version; httpd and isolation checks passed.'
