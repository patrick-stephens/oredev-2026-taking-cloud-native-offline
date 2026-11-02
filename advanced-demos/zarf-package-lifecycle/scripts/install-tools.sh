#!/usr/bin/env bash
# CONNECTED: ./scripts/install-tools.sh (local installs only, no sudo).
set -euo pipefail
if [[ "$(uname -s)" == Darwin ]]; then
    homebrew_prefix="${HOMEBREW_PREFIX:-/opt/homebrew}"
    if [[ -x "$homebrew_prefix/bin/brew" ]]; then
        PATH="$HOME/.local/bin:$homebrew_prefix/bin:$PATH"
        for formula in coreutils findutils gawk gnu-sed gnu-tar grep; do
            gnubin="$homebrew_prefix/opt/$formula/libexec/gnubin"
            [[ -d "$gnubin" ]] && PATH="$gnubin:$PATH"
        done
        export PATH
    fi
fi
DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$DIR/.tools"
cd "$DIR/.tools"
host_os="$(uname -s)"
host_arch="$(uname -m)"
case "$host_os/$host_arch" in
    Darwin/arm64) release_os=Darwin; release_arch=arm64; target_arch=arm64; k3d_os=darwin; k3d_arch=arm64 ;;
    Linux/x86_64) release_os=Linux; release_arch=amd64; target_arch=amd64; k3d_os=linux; k3d_arch=amd64 ;;
    *) printf 'ERROR: Supported hosts are macOS arm64 (experimental) and Linux x86_64.\n' >&2; exit 1 ;;
esac
host_platform="$host_os-$host_arch"
fetch() {
    curl --fail --location --silent --show-error --retry 3 --max-time 180 "$1" -o "$2"
}
verify_asset() {
    local checksum_file=$1 release_name=$2 local_name=$3
    awk -v source="$release_name" -v dest="$local_name" \
        '$2 == source {print $1 "  " dest; found=1} END {if (!found) exit 1}' "$checksum_file" |
        sha256sum --check -
}

if [[ ! -s zarf-checksums.txt ]]; then
    fetch https://github.com/zarf-dev/zarf/releases/download/v0.88.0/checksums.txt zarf-checksums.txt
fi
if [[ ! -x zarf || "$(cat .zarf-platform 2>/dev/null || true)" != "$host_platform" ]]; then
    zarf_asset="zarf_v0.88.0_${release_os}_${release_arch}"
    fetch "https://github.com/zarf-dev/zarf/releases/download/v0.88.0/$zarf_asset" zarf.partial
    verify_asset zarf-checksums.txt "$zarf_asset" zarf.partial
    mv zarf.partial zarf
    chmod +x zarf
    printf '%s\n' "$host_platform" > .zarf-platform
fi
target_asset="zarf_v0.88.0_Linux_${target_arch}"
if [[ ! -x zarf-target || "$(cat .target-platform 2>/dev/null || true)" != "linux-$target_arch" ]]; then
    if [[ "$host_os" == Linux && "$host_arch" == x86_64 ]]; then
        cp zarf zarf-target.partial
    else
        fetch "https://github.com/zarf-dev/zarf/releases/download/v0.88.0/$target_asset" zarf-target.partial
    fi
    verify_asset zarf-checksums.txt "$target_asset" zarf-target.partial
    mv zarf-target.partial zarf-target
    chmod +x zarf-target
    printf 'linux-%s\n' "$target_arch" > .target-platform
fi

if [[ ! -s k3d-checksums.txt ]]; then
    fetch https://github.com/k3d-io/k3d/releases/download/v5.9.0/checksums.txt k3d-checksums.txt
fi
k3d_asset="k3d-$k3d_os-$k3d_arch"
if [[ ! -x k3d || "$(cat .k3d-platform 2>/dev/null || true)" != "$host_platform" ]]; then
    fetch "https://github.com/k3d-io/k3d/releases/download/v5.9.0/$k3d_asset" k3d.partial
    verify_asset k3d-checksums.txt "_dist/$k3d_asset" k3d.partial
    mv k3d.partial k3d
    chmod +x k3d
    printf '%s\n' "$host_platform" > .k3d-platform
fi
./zarf version
./k3d version
