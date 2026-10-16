#!/usr/bin/env bash
# CONNECTED: ./scripts/install-tools.sh (local installs only, no sudo).
set -euo pipefail
DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$DIR/.tools"
cd "$DIR/.tools"
fetch() {
    curl --fail --location --silent --show-error --retry 3 --max-time 180 "$1" -o "$2"
}
if [[ ! -x zarf ]]; then
    fetch https://github.com/zarf-dev/zarf/releases/download/v0.88.0/zarf_v0.88.0_Linux_amd64 zarf
    fetch https://github.com/zarf-dev/zarf/releases/download/v0.88.0/checksums.txt zarf-checksums.txt
    grep ' zarf_v0.88.0_Linux_amd64$' zarf-checksums.txt |
        sed 's/zarf_v0.88.0_Linux_amd64$/zarf/' | sha256sum --check -
    chmod +x zarf
fi
if [[ ! -x k3d ]]; then
    fetch https://github.com/k3d-io/k3d/releases/download/v5.9.0/k3d-linux-amd64 k3d
    fetch https://github.com/k3d-io/k3d/releases/download/v5.9.0/checksums.txt k3d-checksums.txt
    grep ' _dist/k3d-linux-amd64$' k3d-checksums.txt |
        sed 's|_dist/k3d-linux-amd64$|k3d|' | sha256sum --check -
    chmod +x k3d
fi
./zarf version
./k3d version
