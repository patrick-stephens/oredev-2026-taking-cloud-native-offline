#!/usr/bin/env bash
# shellcheck disable=SC2034
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"

K0S_VERSION='v1.36.4+k0s.1'
K0S_IMAGE='docker.io/k0sproject/k0s:v1.36.4-k0s.1'
PROBE_IMAGE='docker.io/rancher/mirrored-library-busybox:1.37.0'
ARTIFACTS="$ROOT/artifacts/k0s"
STATE="$ROOT/.state/k0s"
NODE='taking-offline-k0s-airgap'
NETWORK='taking-offline-k0s-airgap'
BUNDLE="k0s-airgap-bundle-${K0S_VERSION}-linux-amd64.tar"
BINARY="k0s-${K0S_VERSION}-amd64"

k() { docker exec -i "$NODE" k0s kubectl "$@"; }
images() { docker exec "$NODE" k0s ctr images ls -q; }
