#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TOOLS="$ROOT/.tools"
mkdir -p "$TOOLS"

fetch() {
    curl --fail --location --silent --show-error --retry 3 --max-time 180 "$1" -o "$2"
}

install_release_binary() {
    local name="$1" url="$2" expected_sha="$3" archive="$4"
    local destination="$TOOLS/$name"
    if [[ -x "$destination" ]]; then
        return
    fi
    fetch "$url" "$TOOLS/$archive"
    printf '%s  %s\n' "$expected_sha" "$TOOLS/$archive" | sha256sum --check -
    tar -xzf "$TOOLS/$archive" -C "$TOOLS" --strip-components=1 \
        "$(tar -tzf "$TOOLS/$archive" | grep -E "/$name$")"
    chmod +x "$destination"
}

install_release_binary \
    melange \
    https://github.com/chainguard-dev/melange/releases/download/v0.62.1/melange_0.62.1_linux_amd64.tar.gz \
    a8b0d4b3a8d191dde2955f802743cc1c401214fed3648a5e5407c6c34d03d8a6 \
    melange_0.62.1_linux_amd64.tar.gz
install_release_binary \
    apko \
    https://github.com/chainguard-dev/apko/releases/download/v1.4.11/apko_1.4.11_linux_amd64.tar.gz \
    5445ea2467a4ab0db3e31d9f795133128d0564c7afdaa46fcdaa1ee3cf92c757 \
    apko_1.4.11_linux_amd64.tar.gz

if [[ ! -x "$TOOLS/kubectl" ]]; then
    fetch https://dl.k8s.io/release/v1.33.5/bin/linux/amd64/kubectl "$TOOLS/kubectl"
    expected_sha="$(curl --fail --location --silent --show-error --retry 3 --max-time 180 \
        https://dl.k8s.io/release/v1.33.5/bin/linux/amd64/kubectl.sha256)"
    printf '%s  %s\n' "$expected_sha" "$TOOLS/kubectl" | sha256sum --check -
    chmod +x "$TOOLS/kubectl"
fi

if [[ ! -x "$TOOLS/k3d" ]]; then
    fetch https://github.com/k3d-io/k3d/releases/download/v5.9.0/k3d-linux-amd64 "$TOOLS/k3d"
    printf '%s  %s\n' \
        06d8f25bc3a971c4eb29e0ff08429b180402db0f4dec838c9eac427e296800a0 \
        "$TOOLS/k3d" | sha256sum --check -
    chmod +x "$TOOLS/k3d"
fi

"$TOOLS/melange" version
"$TOOLS/apko" version
"$TOOLS/kubectl" version --client
"$TOOLS/k3d" version
