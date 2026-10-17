#!/usr/bin/env bash
set -euo pipefail

# Runs in the registry's network namespace, with /work as its working directory.
output=$1
trap 'echo "ERROR: graph snapshot validation failed at line $LINENO ($output)." >&2' ERR
repository=localhost:5000/demo/alpine
subject=$2
mkdir -p "$output"
oras manifest fetch --plain-http "$repository@$subject" > "$output/image.json"
[[ "sha256:$(sha256sum "$output/image.json" | cut -d ' ' -f 1)" == "$subject" ]]
curl --noproxy '*' -fsS "http://localhost:5000/v2/demo/alpine/referrers/$subject" \
  > "$output/referrers.json"
jq -e '
  .schemaVersion == 2 and
  .mediaType == "application/vnd.oci.image.index.v1+json" and
  (.manifests | length == 4) and
  ([.manifests[].artifactType] | sort) == ([
    "application/spdx+json",
    "application/vnd.offline-demo.policy.v1+json",
    "application/vnd.offline-demo.model.v1",
    "application/vnd.dev.sigstore.bundle.v0.3+json"
  ] | sort)
' "$output/referrers.json" >/dev/null
printf '%s\n' "$subject" > "$output/digests.txt"
while IFS= read -r digest; do
  oras manifest fetch --plain-http "$repository@$digest" > "$output/${digest#sha256:}.json"
  [[ "sha256:$(sha256sum "$output/${digest#sha256:}.json" | cut -d ' ' -f 1)" == "$digest" ]]
  jq -e --arg subject "$subject" '.subject.digest == $subject' \
    "$output/${digest#sha256:}.json" >/dev/null
  printf '%s\n' "$digest" >> "$output/digests.txt"
done < <(jq -r '.manifests | sort_by(.digest) | .[].digest' "$output/referrers.json")
oras discover --plain-http --distribution-spec v1.1-referrers-api \
  --format tree "$repository@$subject" | tee "$output/tree.txt"
oras discover --plain-http --distribution-spec v1.1-referrers-api \
  --format json "$repository@$subject" > "$output/discovery.json"
# Referrers API response order is not part of the graph's identity.
jq -S 'walk(
  if type == "object" and has("referrers")
  then .referrers |= sort_by(.digest) else . end
)' "$output/discovery.json" > "$output/tree.canonical.json"
jq -S '.manifests | sort_by(.digest)' "$output/referrers.json" > "$output/descriptors.json"
