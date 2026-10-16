#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/k0s-common.sh"

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
base="https://github.com/k0sproject/k0s/releases/download/${K0S_VERSION/+/%2B}"
download "$base/$BINARY" "$BINARY"
download "$base/$BUNDLE" "$BUNDLE"
download "$base/sha256sums.txt" sha256sums.txt
(
  cd "$ARTIFACTS"
  awk -v bin="$BINARY" -v bundle="$BUNDLE" \
    '$2 == "*" bin || $2 == "*" bundle {print}' sha256sums.txt > official.sha256
  [[ "$(wc -l < official.sha256)" == 2 ]] || die 'Missing official k0s checksums.'
  sha256sum -c official.sha256
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
chmod +x "$ARTIFACTS/$BINARY" "$ARTIFACTS/linux-amd64/helm"
[[ "$("$ARTIFACTS/linux-amd64/helm" version --template '{{.Version}}')" == "$HELM_VERSION" ]] ||
  die 'Unexpected Helm version.'
for image in "$K0S_IMAGE" "$WHOAMI_IMAGE" "$PROBE_IMAGE"; do
  docker pull --platform linux/amd64 "$image"
done
docker save -o "$ARTIFACTS/node.tar" "$K0S_IMAGE"
docker save -o "$ARTIFACTS/workloads.tar" "$WHOAMI_IMAGE" "$PROBE_IMAGE"
"$ARTIFACTS/linux-amd64/helm" template offline-whoami "$ROOT/config/chart" \
  --namespace offline-demo --set-string image="$WHOAMI_IMAGE" > "$ARTIFACTS/whoami.yaml"
{
  echo "k0s=$K0S_VERSION"
  echo "node=$K0S_IMAGE"
  echo "helm=$HELM_VERSION"
  echo "workload=$WHOAMI_IMAGE"
  echo "probe=$PROBE_IMAGE"
  docker image inspect "$K0S_IMAGE" "$WHOAMI_IMAGE" "$PROBE_IMAGE" \
    --format '{{.Id}} {{json .RepoDigests}}'
} > "$ARTIFACTS/versions.txt"
(
  cd "$ARTIFACTS"
  sha256sum "$BINARY" "$BUNDLE" node.tar workloads.tar whoami.yaml \
    linux-amd64/helm versions.txt > SHA256SUMS
)
echo "CONNECTED k0s preparation complete: $ARTIFACTS"
