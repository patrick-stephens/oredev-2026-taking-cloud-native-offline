#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"

require_command curl
require_command tar
mkdir -p "$TOOLS_DIR"
tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

download() {
    curl --fail --location --silent --show-error --retry 3 --max-time 180 "$1" -o "$2"
}

if [[ ! -x "$TOOLS_DIR/flux" ]] || ! "$TOOLS_DIR/flux" --version | grep -q "flux version $FLUX_VERSION"; then
    download "https://github.com/fluxcd/flux2/releases/download/v${FLUX_VERSION}/flux_${FLUX_VERSION}_linux_amd64.tar.gz" "$tmp_dir/flux.tar.gz"
    tar -xzf "$tmp_dir/flux.tar.gz" -C "$tmp_dir" flux
    install -m 0755 "$tmp_dir/flux" "$TOOLS_DIR/flux"
fi

if [[ ! -x "$TOOLS_DIR/kind" ]] || ! "$TOOLS_DIR/kind" version | grep -q "kind v$KIND_VERSION"; then
    download "https://github.com/kubernetes-sigs/kind/releases/download/v${KIND_VERSION}/kind-linux-amd64" "$TOOLS_DIR/kind"
    chmod 0755 "$TOOLS_DIR/kind"
fi

if [[ ! -x "$TOOLS_DIR/kubectl" ]] || ! "$TOOLS_DIR/kubectl" version --client -o yaml | grep -q "gitVersion: v$KUBECTL_VERSION"; then
    download "https://dl.k8s.io/release/v${KUBECTL_VERSION}/bin/linux/amd64/kubectl" "$TOOLS_DIR/kubectl"
    chmod 0755 "$TOOLS_DIR/kubectl"
fi

if [[ ! -x "$TOOLS_DIR/helm" ]] || ! "$TOOLS_DIR/helm" version --short | grep -q "v$HELM_VERSION"; then
    download "https://get.helm.sh/helm-v${HELM_VERSION}-linux-amd64.tar.gz" "$tmp_dir/helm.tar.gz"
    tar -xzf "$tmp_dir/helm.tar.gz" -C "$tmp_dir"
    install -m 0755 "$tmp_dir/linux-amd64/helm" "$TOOLS_DIR/helm"
fi

"$TOOLS_DIR/flux" --version
"$TOOLS_DIR/kind" version
"$TOOLS_DIR/kubectl" version --client
"$TOOLS_DIR/helm" version --short
