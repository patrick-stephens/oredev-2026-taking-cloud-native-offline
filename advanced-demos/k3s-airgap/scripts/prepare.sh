#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"

check_host
mkdir -p "$ARTIFACTS"
chmod 700 "$ARTIFACTS"
download() {
  local url="$1" file="$2"
  if [[ ! -s "$ARTIFACTS/$file" ]]; then
    curl --fail --location --retry 3 --connect-timeout 15 --max-time 900 \
      "$url" -o "$ARTIFACTS/$file.part"
    mv "$ARTIFACTS/$file.part" "$ARTIFACTS/$file"
  fi
}

base="https://github.com/k3s-io/k3s/releases/download/${K3S_VERSION/+/%2B}"
download "$base/k3s" k3s
download "$base/k3s-airgap-images-amd64.tar.zst" k3s-airgap-images-amd64.tar.zst
download "$base/sha256sum-amd64.txt" sha256sum-amd64.txt
(
  cd "$ARTIFACTS"
  awk '$2 == "k3s" || $2 == "k3s-airgap-images-amd64.tar.zst" { print }' \
    sha256sum-amd64.txt > k3s-selected.sha256
  [[ "$(wc -l < k3s-selected.sha256)" == 2 ]] || die 'Missing official k3s checksum entries.'
  sha256sum -c k3s-selected.sha256
)

download "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz" helm.tar.gz
download "https://get.helm.sh/helm-${HELM_VERSION}-linux-amd64.tar.gz.sha256sum" helm.sha256sum
(
  cd "$ARTIFACTS"
  expected="$(awk '{print $1}' helm.sha256sum)"
  [[ "$expected" =~ ^[0-9a-f]{64}$ ]] || die 'Invalid Helm checksum.'
  printf '%s  helm.tar.gz\n' "$expected" | sha256sum -c -
  tar -xzf helm.tar.gz linux-amd64/helm
)
chmod +x "$ARTIFACTS/k3s" "$ARTIFACTS/linux-amd64/helm"
[[ "$("$ARTIFACTS/linux-amd64/helm" version --template '{{.Version}}')" == "$HELM_VERSION" ]] ||
  die 'Unexpected Helm version.'

docker pull --platform linux/amd64 "$K3S_IMAGE"
docker pull --platform linux/amd64 "$WHOAMI_IMAGE"
docker save -o "$ARTIFACTS/k3s-node.tar" "$K3S_IMAGE"
docker save -o "$ARTIFACTS/whoami.tar" "$WHOAMI_IMAGE"
"$ARTIFACTS/linux-amd64/helm" template offline-whoami "$ROOT/config/chart" \
  --namespace offline-demo --set-string image="$WHOAMI_IMAGE" > "$ARTIFACTS/whoami.yaml"
{
  echo "k3s=$K3S_VERSION"
  echo "node=$K3S_IMAGE"
  echo "helm=$HELM_VERSION"
  echo "workload=$WHOAMI_IMAGE"
  docker image inspect "$K3S_IMAGE" "$WHOAMI_IMAGE" \
    --format '{{.Id}} {{json .RepoDigests}}'
} > "$ARTIFACTS/versions.txt"
(
  cd "$ARTIFACTS"
  sha256sum k3s k3s-airgap-images-amd64.tar.zst k3s-node.tar whoami.tar \
    whoami.yaml linux-amd64/helm versions.txt > SHA256SUMS
)
echo "CONNECTED preparation complete: $ARTIFACTS"
