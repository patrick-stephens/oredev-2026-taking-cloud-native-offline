#!/usr/bin/env bash
set -euo pipefail

# No TUF bootstrap, Fulcio, Rekor or timestamp service is used in key-only mode.
subject=$1
key=$2
cosign verify --key "$key" --offline --insecure-ignore-tlog \
  --new-bundle-format=true \
  --trusted-root /demo/trusted-root.json --allow-http-registry \
  "localhost:5000/demo/alpine@$subject" > /tmp/verification.json
jq -e --arg subject "$subject" '
  length == 1 and
  .[0].critical.image["docker-manifest-digest"] == $subject and
  .[0].critical.type == "https://sigstore.dev/cosign/sign/v1"
' /tmp/verification.json >/dev/null
cat /tmp/verification.json
