#!/usr/bin/env bash
# Shared constants are consumed by the scripts sourcing this file.
# shellcheck disable=SC2034
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
ARTIFACTS="$ROOT/artifacts"
STATE="$ROOT/.state"
K3S_VERSION='v1.37.1+k3s1'
K3S_IMAGE='rancher/k3s:v1.37.1-k3s1'
HELM_VERSION='v4.3.1'
WHOAMI_IMAGE='docker.io/traefik/whoami:v1.12.0'
MISSING_IMAGE='docker.io/library/busybox:1.37.0'
NODE='taking-offline-k3s-airgap'
NETWORK='taking-offline-k3s-airgap'
LABEL='io.taking-offline.demo=k3s-airgap'

die() { echo "ERROR: $*" >&2; exit 1; }

require() {
  local tool
  for tool in "$@"; do
    command -v "$tool" >/dev/null || die "Missing prerequisite: $tool"
  done
}

phase() {
  if [[ -t 1 && -n "${TERM:-}" ]]; then clear; fi
  echo "=== PHASE $* ==="
  sleep "${DEMO_PAUSE_SECONDS:-2}"
}

check_host() {
  require docker curl jq sha256sum tar timeout awk grep date
  [[ "$(uname -s)" == Linux ]] || die 'Use a Linux host or Linux VM.'
  [[ "$(docker info --format '{{.OSType}}/{{.Architecture}}')" == linux/x86_64 ]] ||
    die 'This demo deliberately supports only a Linux amd64 Docker engine.'
}

k() { docker exec -i "$NODE" /bin/k3s kubectl "$@"; }
images() { docker exec "$NODE" /bin/k3s ctr images ls -q; }

wait_for_resource() {
  local namespace="$1" resource="$2" deadline=$((SECONDS + 120))
  until k -n "$namespace" get "$resource" --request-timeout=10s \
    > /dev/null 2>"$STATE/resource-wait.log"; do
    (( SECONDS < deadline )) || {
      cat "$STATE/resource-wait.log" >&2
      die "Resource $namespace/$resource did not appear in 120 seconds."
    }
    sleep 2
  done
}

expect_blocked() {
  local name="$1" rc
  shift
  if timeout 15 docker exec "$NODE" "$@" > "$STATE/$name.log" 2>&1; then
    cat "$STATE/$name.log"
    die "EGRESS LEAK: $name unexpectedly succeeded."
  else
    rc=$?
    (( rc == 1 || rc == 124 )) || die "$name probe failed unexpectedly (exit $rc)."
    [[ "$(docker inspect "$NODE" --format '{{.State.Running}}')" == true ]] ||
      die 'Node stopped during the negative test.'
    echo "Expected blocked probe: $name (exit $rc)"
    cat "$STATE/$name.log"
  fi
}

verify_offline_network() {
  local applet deadline reason
  assert_isolated
  docker exec "$NODE" /bin/busybox --list > "$STATE/busybox-applets.txt"
  for applet in wget nslookup; do
    grep -Fx "$applet" "$STATE/busybox-applets.txt" >/dev/null ||
      die "Missing $applet probe."
  done
  expect_blocked external-ip /bin/busybox wget -T 5 -O /dev/null http://1.1.1.1/
  expect_blocked public-dns /bin/busybox nslookup registry-1.docker.io 1.1.1.1
  expect_blocked docker-dns /bin/busybox nslookup registry-1.docker.io 127.0.0.11
  k apply -f - < "$ROOT/config/network-proof.yaml"
  if ! k wait --for=jsonpath='{.status.phase}'=Succeeded pod/network-proof --timeout=90s; then
    k logs network-proof
    die 'Pod-level local-network/egress proof failed.'
  fi
  k logs network-proof | tee "$STATE/pod-network-proof.log"
  k apply -f - < "$ROOT/config/unseeded.yaml"
  deadline=$((SECONDS + 120))
  while :; do
    reason="$(k -n offline-demo get pod unseeded \
      -o jsonpath='{.status.containerStatuses[0].state.waiting.reason}')"
    case "$reason" in ErrImagePull|ImagePullBackOff) break ;; esac
    (( SECONDS < deadline )) || die "No expected pull failure in 120 seconds; reason=$reason"
    sleep 2
  done
  k -n offline-demo describe pod unseeded | tee "$STATE/unseeded.txt"
  grep -E 'Failed to pull image|failed to pull and unpack image' "$STATE/unseeded.txt" >/dev/null ||
    die 'Missing actual failed pull evidence.'
  images > "$STATE/images-after.txt"
  if grep -F "$MISSING_IMAGE" "$STATE/images-after.txt" >/dev/null; then
    die 'EGRESS LEAK: unseeded image was imported.'
  fi
  k -n offline-demo rollout status deployment/whoami --timeout=30s
  assert_isolated
}

assert_isolated() {
  local networks
  [[ "$(docker network inspect "$NETWORK" --format '{{.Internal}}')" == true ]] ||
    die 'Demo network is not internal.'
  [[ "$(docker network inspect "$NETWORK" --format '{{.EnableIPv6}}')" == false ]] ||
    die 'Unexpected IPv6 enabled on demo network.'
  networks="$(docker inspect "$NODE" --format '{{json .NetworkSettings.Networks}}')"
  [[ "$(jq 'length' <<<"$networks")" == 1 ]] ||
    die 'Node has more than one network.'
  jq -e --arg n "$NETWORK" 'has($n)' <<<"$networks" >/dev/null ||
    die 'Node is not on the demo network.'
  [[ "$(docker inspect "$NODE" --format '{{json .HostConfig.PortBindings}}')" == null ||
     "$(docker inspect "$NODE" --format '{{json .HostConfig.PortBindings}}')" == '{}' ]] ||
    die 'Unexpected published ports.'
}

remove_runtime() {
  if docker container inspect "$NODE" >/dev/null 2>&1; then
    [[ "$(docker inspect "$NODE" --format '{{index .Config.Labels "io.taking-offline.demo"}}')" == k3s-airgap ]] ||
      die "Refusing to delete unowned container $NODE."
    docker rm -fv "$NODE"
  fi
  if docker network inspect "$NETWORK" >/dev/null 2>&1; then
    [[ "$(docker network inspect "$NETWORK" --format '{{index .Labels "io.taking-offline.demo"}}')" == k3s-airgap ]] ||
      die "Refusing to delete unowned network $NETWORK."
    docker network rm "$NETWORK"
  fi
}
