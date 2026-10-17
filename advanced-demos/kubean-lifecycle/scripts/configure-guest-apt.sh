#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../config/versions.env
source "$ROOT/config/versions.env"
SSH_DIR="$ROOT/.state/ssh"
SSH_KEY="$SSH_DIR/id_ed25519"
SSH_KNOWN_HOSTS="$SSH_DIR/known_hosts"
FILE_SERVICE_URL="${FILE_SERVICE_URL:-http://192.168.56.1:8080}"

version="${1:-$BASE_KUBEAN_VERSION}"
case "$version" in
  "$BASE_KUBEAN_VERSION"|"$UPGRADE_KUBEAN_VERSION") ;;
  *)
    echo "Usage: $0 [$BASE_KUBEAN_VERSION|$UPGRADE_KUBEAN_VERSION]" >&2
    exit 2
    ;;
esac

[[ -s "$SSH_KEY" ]] || {
  echo "ERROR: missing demo SSH key: $SSH_KEY" >&2
  exit 1
}
[[ -s "$ROOT/.state/files/kubean/ubuntu/$version/Packages.gz" ]] || {
  echo "ERROR: missing staged apt index for $version; run stage-artifacts.sh first." >&2
  exit 1
}

repo_url="$FILE_SERVICE_URL/kubean/ubuntu/$version"
for address in 192.168.56.11 192.168.56.12; do
  ssh -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=5 \
    -o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=$SSH_KNOWN_HOSTS" \
    "vagrant@$address" "sudo bash -s -- '$repo_url'" <<'REMOTE'
set -euo pipefail
repo_url="$1"
backup=/etc/apt/sources.list.kubean-demo.orig

if [[ ! -e "$backup" && -e /etc/apt/sources.list ]]; then
  cp -a /etc/apt/sources.list "$backup"
fi
for source_file in /etc/apt/sources.list.d/*.list /etc/apt/sources.list.d/*.sources; do
  [[ -e "$source_file" ]] || continue
  mv "$source_file" "$source_file.kubean-demo-disabled"
done
printf 'deb [trusted=yes] %s ./\n' "$repo_url" > /etc/apt/sources.list
printf 'Acquire::Languages "none";\n' > /etc/apt/apt.conf.d/99kubean-demo
apt-get clean
apt-get -o Acquire::Languages=none -o APT::Update::Error-Mode=any update
REMOTE
  printf 'Configured %s to use the %s local Ubuntu repository.\n' "$address" "$version"
done
