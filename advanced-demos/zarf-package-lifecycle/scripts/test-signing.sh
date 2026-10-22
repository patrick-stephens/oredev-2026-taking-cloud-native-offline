#!/usr/bin/env bash
# After ./scripts/run-demo.sh:
# bash ./scripts/test-signing.sh --trusted-key /independently/enrolled/cosign.pub
# Additional test-only host dependencies: GNU tar and zstd.
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
[[ $# == 2 && "$1" == --trusted-key && -s "$2" ]] ||
    die "Usage: bash ./scripts/test-signing.sh --trusted-key /trusted/cosign.pub"
trusted_key="$(realpath "$2")"
require_tools
assert_isolated
for tool in tar zstd; do command -v "$tool" >/dev/null || die "Test dependency missing: $tool"; done
docker image inspect "$COSIGN" >/dev/null || die "Run CONNECTED first to stage Cosign."
umask 077
private="$(mktemp -d "$STATE/signing-test.XXXXXXXX")"
work="$(mktemp -d "$ARTIFACTS/signing-test.XXXXXXXX")"
cleanup() {
    rm -rf -- "$private" "$work"
}
trap cleanup EXIT
target="/work/artifacts/$(basename "$work")"
mkdir "$work/payload"
docker exec "$NODE" mkdir -p /work/trust
docker cp "$trusted_key" "$NODE:/work/trust/cosign.pub"
target_zarf package verify "/work/artifacts/$PACKAGE" --key /work/trust/cosign.pub
before="$(kube -n zarf get secret zarf-package-podinfo-offline -o jsonpath='{.metadata.resourceVersion}')"
docker exec "$NODE" iptables -t mangle -Z ZARF_DEMO_EGRESS
docker exec "$NODE" ip6tables -t mangle -Z ZARF_DEMO_EGRESS

# Only this unrelated PUBLIC key is exposed to the target; its private key stays
# in the unmounted host state directory and is deleted on exit.
COSIGN_PASSWORD=negative-test-only docker run --rm --network none \
    --user "$(id -u):$(id -g)" --env COSIGN_PASSWORD --env HOME=/tmp \
    --mount "type=bind,src=$private,dst=/keys" --workdir /keys "$COSIGN" generate-key-pair
cp "$private/cosign.pub" "$work/wrong.pub"

reject() {
    local name=$1 package=$2 key=$3 pattern=$4
    if target_zarf package verify "$package" --key "$key" \
        > "$STATE/signing-$name-verify.log" 2>&1; then
        die "$name unexpectedly passed pre-init verification."
    fi
    grep -Eiq "$pattern" "$STATE/signing-$name-verify.log" ||
        die "$name failed pre-init verification for an unexpected reason."
    if target_zarf package deploy "$package" --confirm --timeout=10s \
        --verify=always --key "$key" > "$STATE/signing-$name.log" 2>&1; then
        die "$name unexpectedly passed mandatory signature verification."
    fi
    grep -Eiq "$pattern" "$STATE/signing-$name.log" ||
        die "$name failed for an unexpected reason; inspect .state/signing-$name.log."
    [[ "$(kube -n zarf get secret zarf-package-podinfo-offline -o jsonpath='{.metadata.resourceVersion}')" == "$before" ]] ||
        die "$name modified the deployed package before rejection."
    printf 'PASS: %s rejected before deployment.\n' "$name"
}

reject wrong-key "/work/artifacts/$PACKAGE" "$target/wrong.pub" 'signature|verification'
tar --zstd -xf "$ARTIFACTS/$PACKAGE" -C "$work/payload"
[[ -f "$work/payload/zarf.bundle.sig" ]] || die "Expected Zarf v0.88.0 signature bundle missing."
mv "$work/payload/zarf.bundle.sig" "$private/signature"
tar --zstd -cf "$work/unsigned.tar.zst" -C "$work/payload" .
reject unsigned "$target/unsigned.tar.zst" /work/trust/cosign.pub 'not signed|no signature|no verification material|signature not found'
mv "$private/signature" "$work/payload/zarf.bundle.sig"
printf '\n# changed after signing\n' >> "$work/payload/zarf.yaml"
tar --zstd -cf "$work/manifest-tampered.tar.zst" -C "$work/payload" .
reject manifest-tampered "$target/manifest-tampered.tar.zst" /work/trust/cosign.pub 'signature|verification|checksum'
tar --zstd -xf "$ARTIFACTS/$PACKAGE" -C "$work/payload" zarf.yaml
printf '\nchanged after signing\n' >> "$work/payload/components/podinfo.tar"
tar --zstd -cf "$work/payload-tampered.tar.zst" -C "$work/payload" .
reject payload-tampered "$target/payload-tampered.tar.zst" /work/trust/cosign.pub 'checksum|integrity|mismatch|expected sha256'
assert_isolated
audit_egress > "$ARTIFACTS/signing-test-egress.txt"
for family in iptables ip6tables; do
    rejected="$(docker exec "$NODE" "$family" -t mangle -nvxL ZARF_DEMO_EGRESS |
        awk '$3=="DROP" {packets += $1} END {print packets+0}')"
    [[ "$rejected" == 0 ]] || die "$family recorded forbidden egress during signature tests."
done
printf 'PASS: signature negative tests made no forbidden network attempts; deployed package unchanged.\n'
