#!/usr/bin/env bash
# Variables are consumed by the scripts sourcing this file.
# shellcheck disable=SC2034
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../config/versions.env
source "$ROOT/config/versions.env"
STATE="$ROOT/.state"
BUNDLE="$ROOT/bundle"
CLUSTER=offline-ratify
NODE="$CLUSTER-control-plane"
REGISTRY=offline-ratify-zot
INTERNAL=offline-ratify-internal
UPLINK=offline-ratify-uplink
ENDPOINT=172.30.87.2:5000
REPOSITORY="$ENDPOINT/demo/httpbin"
export KUBECONFIG="$STATE/kubeconfig"
export XDG_CONFIG_HOME="$STATE/xdg"
export DOCKER_CONFIG="$STATE/docker"
export NO_PROXY='*' no_proxy='*'

fail() { echo "ERROR: $*" >&2; exit 1; }
k() { docker exec -i "$NODE" kubectl --kubeconfig=/etc/kubernetes/admin.conf "$@"; }
notation() { "$STATE/bin/notation" "$@"; }
phase() {
  if [[ -t 1 && -n ${TERM:-} ]]; then clear; fi
  echo "=== PHASE $* ==="
  sleep "${DEMO_PAUSE_SECONDS:-2}"
}
need() { command -v "$1" >/dev/null || fail "Missing prerequisite: $1"; }
ensure_image() {
  if ! docker image inspect "$1" >/dev/null 2>&1; then docker pull "$1"; fi
}
registry_copy() {
  docker run --rm --network "$INTERNAL" \
    -v "$STATE:/work:ro" "$SKOPEO_IMAGE" --command-timeout 90s copy \
    --authfile /work/docker/config.json --dest-tls-verify=false \
    "docker-archive:/work/$1.tar" "docker://$REPOSITORY:$2"
}
pod() {
  local name=$1 tag=$2
  k -n offline-demo run "$name" --image="$REPOSITORY:$tag" \
    --image-pull-policy=Always --restart=Never \
    --overrides='{"spec":{"imagePullSecrets":[{"name":"registry-credentials"}]}}'
}
expect_blocked() {
  local label=$1
  shift
  local rc=0
  "$@" >"$STATE/evidence/$label.txt" 2>&1 || rc=$?
  [[ $rc == 7 || $rc == 28 ]] || {
    cat "$STATE/evidence/$label.txt"
    fail "$label: expected curl connect failure/timeout (7/28), got $rc"
  }
  echo "BLOCKED: $label (curl exit $rc)"
}
expect_dns_blocked() {
  local label=$1
  shift
  local rc=0
  "$@" >"$STATE/evidence/$label.txt" 2>&1 || rc=$?
  [[ $rc == 6 || $rc == 28 ]] || {
    cat "$STATE/evidence/$label.txt"
    fail "$label: expected curl DNS failure/timeout (6/28), got $rc"
  }
  echo "BLOCKED: $label (curl exit $rc)"
}
probe() {
  k -n diagnostics exec egress-probe -- curl --noproxy '*' -fsS \
    --connect-timeout 2 --max-time 5 "$@"
}
