# Offline admission: Ratify, local trust and signed SBOMs

| Spectrum level | Demo app | Headline tooling | Status |
|----------------|----------|------------------|--------|
| 3 | go-httpbin | Ratify, Notation, cosign, Syft | Tested 2026-10-17 |

Deploy-time signature verification with locally bundled trust roots

[Offline spectrum](../../docs/offline-spectrum.md) · [Top-level README](../../README.md)

Transfer-time verification is not deployment-time enforcement. This demo makes
the API server ask Gatekeeper and Ratify before admitting a Pod, while the
cluster cannot reach the internet. The application is **mccutchen/go-httpbin
2.26.0**, the latest stable release checked on 2026-10-16; there is no nginx.

**Offline spectrum: level 3.** See the shared [offline spectrum](../../docs/offline-spectrum.md).
This demo covers offline execution and admission, not autonomous offline
provisioning, updates, trust lifecycle, or a physically disconnected host.

The tested baseline is **Ratify**, not a Kyverno substitute. It admits a signed
image, pins its digest, rejects an unsigned image, and rejects a previously
signed tag overwritten with a one-layer modification. No Rekor, Fulcio, TUF,
cloud credentials, external key service or online CA is involved in admission.

Two tested stretch profiles extend that baseline: **cosign OCI-referrer
signatures with a local public key**, and **mandatory signed SPDX SBOMs in
addition to Notation image signatures**. They are separate profiles, not a
claim that the cosign profile also enforces SBOMs.

## Architecture

```text
CONNECTED: download tools/charts/images; generate test key; populate/sign zot

Linux host (Docker, kind, Helm, Notation; remains connected)
  |
  +-- offline-ratify-uplink: 172.30.88.0/24
  |     |
  |     +-- kind node: 172.30.88.2
  |           API server --> Gatekeeper --> Ratify / Notation verifier
  |           kubelet --> containerd            |
  |                         |                  | local cert + trust policy
  |                         +------------------+
  |                                            |
  +-- offline-ratify-internal: 172.30.87.0/24 (--internal)
        +-- same kind node: 172.30.87.3          |
        +-- zot: 172.30.87.2:5000 <-------------+
              demo/httpbin:{signed,unsigned,tampered}
              OCI signature referrers (Notation OR cosign)
              SBOM profile: image <-- SPDX artifact <-- Notation signature

AIR-GAPPED:
  pod egress: default deny + explicit cluster/registry allowlist (kube-router)
  node egress/forwarding: allow local destinations only; REJECT everything else
  node: no default route; IPv6 denied except loopback; Docker DNS stub denied
  registry: only the internal Docker network; no upstream or sync configuration
  all API operations: docker exec --> node-local kubectl (not remote downloads)
```

The node keeps its original Docker network attachment so its advertised
control-plane IP does not disappear. **Its firewall and missing default route,
not an assertion that both networks are internal, isolate the node.** The host
firewall, Docker daemon configuration and unrelated networks are not changed.

## Prerequisites

- Native Linux **amd64**, rootful Docker, cgroup v2, and permission to launch
  privileged kind nodes. Allow about 4 CPU cores, 6 GiB RAM and 6 GiB disk.
  Rootless Docker, Docker Desktop host routing and arm64 are not tested.
- `kind v0.31.0` and `helm v4.3.0` on PATH; the script checks these versions.
- Bash 4+, curl, jq, OpenSSL, GNU coreutils (`timeout`, `sha256sum`, `base64`,
  `date`, etc.), tar, grep, sed, diff and `clear`. No host kubectl, Skopeo or
  Notation, cosign, ORAS or Syft installation is required. The pinned kind node
  includes `nft` for the independent network-audit counter.
- Connected access to GitHub releases/raw chart hosting, GHCR, Docker Hub,
  Quay and their auth/CDN endpoints. The positive egress tests use
  `https://1.1.1.1/cdn-cgi/trace` and `https://example.com`. If those are blocked
  before isolation, the demo stops rather than pretending isolation worked.
- Both `172.30.87.0/24` and `172.30.88.0/24` must be unused, including by your
  VPN/LAN. Pod/service ranges are `10.244.0.0/16` and `10.96.0.0/16`.
- Reserve the names `offline-ratify`, `offline-ratify-zot`,
  `offline-ratify-internal`, `offline-ratify-uplink`, and local image tags
  `offline-ratify-httpbin:*` for this demo. Run one instance
  per Docker engine. A new run deletes and recreates this named cluster.

## Tested with

Latest end-to-end test date: **2026-10-17**, native Linux amd64, cgroup v2.

| Component | Exact tested version |
|---|---|
| Docker CLI / engine | 29.9.1 / 29.9.1 |
| kind | v0.31.0 (go1.25.5) |
| Kubernetes / containerd in kind | v1.35.0 / 2.2.0 |
| Helm | v4.3.0+gbec5b06 |
| Ratify / Helm chart | v1.4.6 / 1.15.7 |
| Gatekeeper / Helm chart / CRD hook image | v3.23.1 / 3.23.1 / v3.23.1 |
| Notation CLI | 1.3.2 |
| cosign CLI (cosign profile) | 2.4.3 |
| ORAS CLI (stretch profiles) | 1.3.0 |
| Syft CLI (SBOM profile) | 1.46.0 |
| Ratify SPDX verifier (SBOM profile) | 2.0.0-alpha.1 |
| zot | v2.1.15, linux-amd64 image |
| go-httpbin | 2.26.0; binary reports commit `8b1bc14` |
| kube-router (policy controller only) | v2.5.0 |
| Skopeo | v1.20.0 |
| curl probe / Gatekeeper install-hook curl image | 8.16.0 / 8.20.0 |
| htpasswd tooling image | httpd:2.4.65-alpine |
| Host Bash / curl / jq / ShellCheck | 5.2.21 / 8.5.0 / 1.7 / 0.9.0 |

The latest full `--all` rehearsal passed in **370 seconds (6m10s)** with
container/tool downloads cached and `DEMO_PAUSE_SECONDS=0`:

| Profile | Runtime | Verified result |
|---|---:|---|
| `notation` | 109s | Signed allowed; unsigned/tampered denied |
| `cosign` | 119s | Same admission matrix; real OCI referrers, no legacy signature tags |
| `sbom` | 142s | Signed image + signed SBOM allowed; all seven negative fixtures denied |

All profiles served go-httpbin after isolation, pinned the verified image digest,
blocked node/Pod/verifier internet probes, and observed no external packets in
the workload audit. Cold downloads are additional and were not measured as a
successful cold end-to-end run. Default narration sleeps add 12 seconds per
profile; bootstrap time varies. Each successful run records runtime and versions
in its own evidence directory.

Supplementary revalidation on 2026-10-17 also confirmed that unsigned
`initContainers` and an unsigned `ephemeralContainers` update are denied.
Scaling Ratify to zero rejected even a signed Pod; restoring it admitted a
new signed, digest-pinned Pod without reopening internet access. The repeated
outage/recovery check took 15 seconds, separate from the orchestrator runtime.
Admission may remain unavailable briefly after Deployment readiness while
Service endpoints/dataplane rules converge; the test allowed at most 60 seconds
for a server-side dry-run admission to succeed. These supplementary checks are
not extra phases in the normal presentation run.

[config/versions.env](./config/versions.env) pins image/tool/chart versions,
the kind node and application source digests, and chart/tool archive
checksums. Supporting images use version tags, not immutable digest locks;
their publishers remain part of connected bootstrap trust.

## Run in one terminal

From the repository root:

```bash
cd advanced-demos/ratify-notation-policy
./scripts/run-demo.sh
```

Select a stretch profile, or test all three with fresh clusters sequentially:

```bash
DEMO_PROFILE=cosign ./scripts/run-demo.sh
DEMO_PROFILE=sbom ./scripts/run-demo.sh
DEMO_PAUSE_SECONDS=0 ./scripts/run-demo.sh --all
```

`notation` remains the default. Each invocation replaces the same named cluster
and registry. Evidence and public trust exports are separated under
`.state/<profile>/` and `bundle/<profile>/`; only the last cluster remains
running after `--all`. For later inspection, set `DEMO_PROFILE` before sourcing
[scripts/common.sh](./scripts/common.sh).

For an unattended, readable rehearsal without terminal clearing:

```bash
set -o pipefail
DEMO_PAUSE_SECONDS=0 ./scripts/run-demo.sh 2>&1 | tee rehearsal.log
```

The sole orchestrator is [scripts/run-demo.sh](./scripts/run-demo.sh).
It clears only an interactive terminal and pauses briefly after each banner.
No manual firewall step or second terminal is needed. On failure it exits
nonzero and retains resources for inspection; it never substitutes success
output for a failed command.

### CONNECTED: phases 1-4

1. Acquire checksum-checked Notation and Helm charts and missing pinned images.
   Builds use the locally staged go-httpbin source and `--network=none`.
2. Start authenticated local zot on its **internal-only network**, generate a
   random throwaway registry password, and push three local tags.
3. Generate the throwaway signing identity using the verified CLI syntax:

   ```bash
   notation cert generate-test --default offline-demo
   notation sign --insecure-registry 172.30.87.2:5000/demo/httpbin:signed
   ```

   These commands run in the script's private `XDG_CONFIG_HOME`; use the
   orchestrator rather than pasting them into your personal Notation config.
   Verify both `signed` and the original `tampered` tag, then overwrite
   `tampered` with the modified image. Export the public certificate and policy.
   The cosign profile uses a key pair instead; the SBOM profile also generates,
   attaches and signs a real Syft inventory plus negative fixtures. See below.
4. Create kind, configure containerd's **endpoint-specific** HTTP registry
   mirror, install kube-router alongside kindnet, and preload policy/probe
   images. **Do not preload the application into the node.** Install Gatekeeper
   and Ratify from local charts while connected. Ratify uses Kubernetes
   registry credentials via its service account; Pods have their own
   `imagePullSecrets`. Both are necessary.
5. Install the admission policy and prove public IP/hostname access initially
   works. Apply default-deny egress plus explicit local allowances in every
   existing namespace. Prove the probe Pod now cannot reach a public IP while
   the node still can: this tests NetworkPolicy enforcement independently
   of the later node firewall.

NetworkPolicy starts during the transition, before declaring AIR-GAPPED.
The node is then sealed before the AIR-GAPPED banner. kindnet alone does not
enforce NetworkPolicy; omitting kube-router would invalidate this demo.

### AIR-GAPPED: phases 5-6

1. Enforce node OUTPUT/FORWARD destination allowlists and IPv6 restrictions,
   deny the Docker DNS stub, remove the default route, and retain a local
   service-CIDR route for kube-proxy DNAT. IPv6 loopback remains available for
   API self-calls. None of these rules are installed on the Docker host.
2. Check the registry's network is internal and its only attachment; assert
   the node has no default route. Probe public IP access from the node, a Pod,
   and **Ratify's actual network namespace** while the authenticated local
   registry remains reachable.
3. Create `httpbin-signed` by tag. Gatekeeper's external-data mutation resolves
   it to the digest; validating admission asks Ratify to verify that digest.
   Assert the admitted Pod is digest-pinned and becomes Ready, then call
   `/get?demo=offline` from the local probe.
4. Submit `httpbin-unsigned` and `httpbin-tampered`. Require actual
   `validation.gatekeeper.sh` denials containing `Offline signature required:`;
   a timeout, image pull failure or registry authentication error is **not**
   accepted as a passing negative test. Assert neither rejected Pod exists.
5. In the SBOM profile, reject five additional evidence-negative fixtures.
   Compare a separate nftables audit counter before/after the actual workload;
   any disallowed packet increment fails the demo. The audit excludes cluster,
   registry, node/loopback and IPv6 link-local multicast destinations.
   IPv6 multicast remains blocked by the firewall; creating Pod interfaces
   naturally generates local neighbor-discovery/membership packets, not internet
   traffic. A separate nft table avoids kube-router's iptables counter resets.
6. Check public DNS fails from node and Pod using unprimed names, then recheck
   external IP access. DNS negative probes run after the workload audit because
   CoreDNS can retry an intentionally blocked lookup after curl has exited.
   Save actual denials/logs/manifests/firewall state,
   and print PASS only after all assertions succeed.

Ratify's ORAS cache, Ratify verification cache and Gatekeeper external-data
response cache are disabled. A stale success cannot make the overwritten tag
pass. Fail-closed webhooks and the constraint apply to **`offline-demo` only**;
control-plane maintenance is not subjected to this demo admission policy.

### Why the three tags have different digests

Notation signatures are OCI referrers to **manifest digests**, not tag names.
Two identical manifests under different tags in one repository share signatures:
renaming the original image to `unsigned` would **not** make it unsigned.

- `signed`: original application, signed locally.
- `unsigned`: identical filesystem layers and binary, but a config-only label
  `offline.demo.variant=unsigned` gives it a distinct unsigned digest.
- `tampered`: initially aliases the signed digest and verifies successfully;
  then rebuilt with **one added filesystem layer** containing
  `/demo-tamper-marker.txt`, and pushed over that same `tampered` tag.

The script checks layer equality for `unsigned`, exactly one extra layer for
`tampered`, and distinct negative-control digests. Tampering here means a valid
new OCI image without an authorized signature, **not** serving corrupt bytes
under an unchanged content digest. The original signature remains valid for
the original digest; it does not authorize the replacement.

## Expected output and captured evidence

Abbreviated successful output:

```text
BLOCKED: pod-policy-external (curl exit 7)
=== PHASE 5: AIR-GAPPED - node firewall sealed, no default route, local trust only ===
BLOCKED: node-offline-external (curl exit 7)
BLOCKED: pod-offline-external (curl exit 7)
BLOCKED: ratify-offline-external (curl exit 7)
pod/httpbin-signed created
pod/httpbin-signed condition met
BLOCKED: node-offline-public-dns (curl exit 6)
BLOCKED: pod-offline-public-dns (curl exit 28)
PASS: signed allowed and digest-pinned; unsigned denied; tampered denied.
PASS: go-httpbin /get served locally; pod, verifier and node external access blocked.
PASS: notation profile; no external packets observed by node audit during admission workload.
Runtime: 109 seconds
```

Actual denials captured in the tested run:

```text
Error from server (Forbidden): admission webhook "validation.gatekeeper.sh" denied the request: [offline-httpbin-signature] Offline signature required: 172.30.87.2:5000/demo/httpbin@sha256:ed65e530520c76fbf54774eab42213d5afd8af6dda3c628a9c72e44d4985155f (Ratify trace: f90f6e8a-16a7-4283-97ff-7acd52207592)
Error from server (Forbidden): admission webhook "validation.gatekeeper.sh" denied the request: [offline-httpbin-signature] Offline signature required: 172.30.87.2:5000/demo/httpbin@sha256:fe0fdc422a90975ab5cfae3da7f45a3018451861d5f4d16e05150d8a109bb84b (Ratify trace: 416fb529-2714-4b18-801e-91032d4a54f2)
```

Trace IDs change each run. go-httpbin returns `args.demo: ["offline"]`, not the
scalar shape of some other httpbin implementations.

The ignored `.state/<profile>/evidence/` directory contains exact denial text, signed Pod
JSON, application response, source/local digests, effective trust policy,
network inspection, routes, iptables state, Ratify/zot logs, events and runtime.
A rejected direct Pod creation has **no Pod Event**, because no Pod is created;
the API response is the authoritative denial. The events file contains lifecycle
events for admitted resources, not invented denial events.

Inspect without reopening internet access:

```bash
(
  export DEMO_PROFILE=notation # use cosign or sbom for the most recent run
  source ./scripts/common.sh
  k -n offline-demo get pods -o wide
  k get verifier verifier-notation -o yaml
  k get store store-oras -o yaml
  cat "$STATE/evidence/unsigned-denial.txt"
  cat "$STATE/evidence/tampered-denial.txt"
  docker exec "$NODE" ip route
  docker exec "$NODE" iptables -nvL OFFLINE_EGRESS
)
```

## Trust store contents and offline trust model

The generated **trust-only** export is deliberately small:

```text
bundle/
  notation/
    trustPolicy.json
    truststore/x509/ca/offline-demo/root.crt   # public PEM certificate
  cosign/
    cosign.pub                               # public key only, no certificate
  sbom/
    trustPolicy.json
    truststore/x509/ca/offline-demo/root.crt
```

Only profiles actually run have exports. Each Notation certificate is a freshly
generated RSA-2048 self-signed **test** signing
certificate/trust anchor, with subject
`CN=offline-demo,O=Notary,L=Seattle,ST=WA,C=US`. It is not an enterprise CA
hierarchy. Notation gives this test certificate roughly **24 hours** of validity.
The script regenerates it on each run. Read its actual public contents with:

```bash
cat bundle/notation/truststore/x509/ca/offline-demo/root.crt
openssl x509 -in bundle/notation/truststore/x509/ca/offline-demo/root.crt \
  -noout -subject -dates -fingerprint -sha256
```

No certificate, private key or credential is checked into this repository.
The exported [trust policy](./config/trustPolicy.json) is:

```json
{
  "version": "1.0",
  "trustPolicies": [
    {
      "name": "offline-httpbin",
      "registryScopes": ["172.30.87.2:5000/demo/httpbin"],
      "signatureVerification": {"level": "strict"},
      "trustStores": ["ca:offline-demo"],
      "trustedIdentities": ["x509.subject: C=US, ST=WA, L=Seattle, O=Notary, CN=offline-demo"]
    }
  ]
}
```

The script derives Helm trust values from this exported policy, rather than
maintaining a separate cluster policy. The chart maps the certificate to
`ratify-notation-inline-cert-0` and its logical store to `ca:certs`; the script
compares the effective policy against the export with that name translation.
Ratify's inline key-management provider holds only the **public certificate**.
The private signing key stays under `.state/<profile>/xdg/notation/localkeys/` on the
host and is neither exported nor mounted into the cluster.

The verifier trusts a pre-distributed root and an explicit certificate subject,
checks the signature against the digest, and enforces certificate validity
using local time. The generated cert has no online revocation/transparency
dependency. Trust-root distribution, rotation, compromise response, trustworthy
time, and revocation freshness are the operator's responsibility.

Compared with Sigstore's public-good keyless mode, this trades public identity
and transparency infrastructure for local PKI/key custody and local policy.
There is no public Rekor inclusion proof or independent visibility into signing
activity. Sigstore can also verify properly bundled evidence offline; it is
incorrect to claim all Sigstore verification inherently requires internet.

## Stretch profile: cosign OCI referrers

`DEMO_PROFILE=cosign` disables the Notation verifier entirely. The host generates
a fresh cosign key pair; only the public key enters Ratify's inline key provider.
Private key `.state/cosign/cosign.key` has an empty passphrase for this throwaway
demo and restrictive host permissions. Do not reuse it for production.

The pinned cosign 2.4.3 integration uses `COSIGN_EXPERIMENTAL=1`, signing with
`--registry-referrers-mode=oci-1-1 --tlog-upload=false`, and CLI verification with
`--experimental-oci11 --offline --insecure-ignore-tlog`. Signing and verification
do **not** accept the same OCI flag. Ratify has `tLogVerify: false` and trusts
only the staged public key. Its scope is
`172.30.87.2:5000/demo/httpbin@sha256:*`: this Ratify version matches the full
digest reference, not a repository-only scope as Notation does.

The script queries zot's real `/v2/demo/httpbin/referrers/<digest>` endpoint and
requires artifact type `application/vnd.dev.cosign.artifact.sig.v1+json`.
It also asserts that no legacy `sha256-*.sig` tags exist. Thus Ratify's available
legacy lookup cannot be responsible for a passing verification.

These deliberately older compatibility pins exercise Ratify v1.4.6's cosign
integration, not the newest cosign v3 bundle format. There is no Notation
certificate, public log submission, inclusion proof, keyless identity or remote
key service. The public key remains a trust root that needs controlled
distribution and rotation.

## Stretch profile: require image signature AND signed SPDX SBOM

`DEMO_PROFILE=sbom` uses Syft to inventory the local Docker archive, disables
Syft's update check, and requires nonempty SPDX 2.3 output. ORAS attaches that
document as `application/spdx+json` using the real OCI 1.1 referrers API.
Notation signs the **SBOM artifact digest** as well as the image digest:

```text
image digest <-- subject: SPDX artifact <-- subject: Notation signature
      ^
      +--------- subject: Notation image signature
```

Ratify's SPDX verifier validates the document; the nested Notation verifier
validates its signature against the same local trust policy.
[manifests/sbom-policy.yaml](./manifests/sbom-policy.yaml) explicitly requires
both a successful top-level image signature and a successful SPDX report with
a successful nested signature, rejecting any failed/empty verifier reports.
Simply enabling the chart's SBOM verifier is insufficient: the default policy
does not require an SBOM to exist.

| Tag | Image signature | SBOM evidence | Expected admission |
|---|---|---|---|
| `signed` | Trusted | Trusted signed SPDX bound to this image | Allow |
| `unsigned` | Missing | Missing | Deny |
| `tampered` | Missing for changed digest | Trusted signed SPDX | Deny |
| `missing-sbom` | Trusted | Missing | Deny |
| `wrong-subject-sbom` | Trusted | Trusted signed artifact attached to another digest | Deny |
| `untrusted-sbom` | Trusted | Signed with a separate, untrusted test identity | Deny |
| `unsigned-sbom` | Trusted | SPDX artifact without a signature | Deny |
| `unsigned-with-sbom` | Missing | Trusted signed SPDX | Deny |

The five extra variants change only image configuration labels, preserving the
same app filesystem. The tampered fixture still adds exactly one layer.
All seven denial messages are captured by tag; the script requires actual
validating evidence denials and no persisted rejected Pods.

This is a **signed, OCI-subject-bound SPDX artifact**, not an in-toto/DSSE
attestation. It proves trusted evidence exists for the digest, not that the
inventory is complete, vulnerability-free, or independently reproduced.
Negative fixtures intentionally reuse inventory bytes; there is no claim that
Ratify compares the listed packages to the actual image filesystem.
The Ratify SPDX plugin is **2.0.0-alpha.1**; treat this as a tested advanced demo,
not a production stability guarantee.

## Where network is still required

- **CONNECTED:** obtaining tools/charts/images and the deliberately successful
  public egress controls. Source dependencies and chart/image publishers must
  be trusted during staging. This script is not an offline-from-empty installer.
- **AIR-GAPPED local network:** API server, kubelet, Gatekeeper, Ratify,
  CoreDNS's cluster records, zot and the app still communicate. "No internet"
  does not mean "no packets." The registry must serve manifests, layers and
  signature referrers; a certificate alone is insufficient.
- **Outside this enclave:** the Docker host retains internet access. It is the
  operator and resource boundary, not a physically unplugged machine.
- **Future lifecycle:** software updates, new images, renewed trust material
  and revocation decisions need a new controlled connected staging/transfer
  process (or equivalent offline media). They are not part of this run.

## Troubleshooting and known limitations

- **kind fails before boot:** use privileged rootful Docker/cgroup v2. Starting
  kind directly on an internal-only network was tested and failed because its
  entrypoint expects a default route. This is why the tested node isolation uses
  in-container firewall rules instead.
- **Address pool overlaps:** choose a sandbox without these subnet conflicts.
  Changing the registry IP requires updating the script, trust policy and
  network allowlist together; it is intentionally not a configurable production
  network installer.
- **Unsigned admitted:** verify it has a different digest from `signed`.
  Signatures follow digests, not tags. Also check the request namespace:
  only `offline-demo` is protected.
- **Signed denied / `401`:** inspect `store-oras`, the `registry-credentials`
  Secret and `ratify-admin.imagePullSecrets`. `oras.useHttp=true` handles the
  local HTTP registry; it does not provide credentials. The separate
  containerd hosts configuration and Pod secret handle kubelet pulls.
- **Admission timeout:** check local service routing, provider TLS readiness
  and DNS. Removing the default route without the service-CIDR route breaks
  node-originated service DNAT. Denying IPv6 loopback breaks local API calls.
  After a Ratify restart, Deployment readiness alone does not prove admission
  readiness: allow bounded time for Service endpoints/dataplane convergence and
  confirm a signed server-side dry-run admission succeeds before resuming.
  Do not fix these by restoring public egress or disabling fail-closed admission.
- **Public egress test fails before policy:** resolve the connected firewall,
  DNS, proxy or upstream outage first. Negative tests without a positive control
  are not proof. Expected curl failures are checked by exit code; authentication,
  exec and admission failures are not counted as network-isolation successes.
- **Freshness:** the test cert expires in a day; rerun before a presentation.
  Caches are off for correctness, not performance. Production certificates
  need a rehearsed offline rotation/revocation design.
- **Cosign `No policy found`:** retain the digest-prefix wildcard scope above.
  A Notation-style repository-only scope does not match this verifier.
- **SBOM positive case denied:** inspect the nested verifier reports, not just
  the image signature. The Rego input is `input.verifierReports`; its children
  have their own `verifierReports` and `nestedReports` arrays. An untrusted SBOM
  identity must fail even when the image signature passes.
- **Admission scope/availability:** fail-closed behavior is namespace-scoped to
  avoid deadlocking cluster bootstrap. This is not a hardened multi-tenant
  cluster. Add RBAC, namespace protection, hostNetwork/privilege restrictions,
  least-privilege ingress/egress and webhook availability before production.
- **Boundary limits:** local destination allowlists trust the Docker host and
  allowed cluster services not to act as internet proxies. A host administrator
  or privileged hostile workload can defeat this software boundary. Namespace
  policy is applied to existing namespaces; no namespace controller is included.
- **Registry transport:** Basic auth over HTTP is a sandbox convenience, not
  confidential transport. No port is published to the host/LAN. Use private TLS
  and separate push/read-only credentials in production. The signing cert is
  not the registry TLS certificate.
- **Not exercised:** rootless/arm64/multi-node operation, real CA hierarchies,
  online CRL/OCSP policies, offline upgrades, cosign v3 compatibility, DSSE
  attestations, and combined cosign + SBOM enforcement. No Kyverno fallback
  was necessary.

## Cleanup

```bash
./scripts/cleanup.sh
```

[Cleanup](./scripts/cleanup.sh) is idempotent, removes only the named kind
cluster, zot container and two demo networks, and therefore removes the node
firewall with its container. No host firewall rules need undoing. It retains
downloaded Docker images, derived fixture image tags, `.state/` (including
throwaway keys/password/kubeconfig), and the public `bundle/` for inspection.
Those generated directories and certificate/key extensions are Git-ignored.
Do not publish the private state or your terminal trace with shell `-x`.
For a full local purge, after cleanup delete only this demo's generated
`.state/` and `bundle/` directories and the `offline-ratify-httpbin` image tags.
Do not prune the shared Docker engine.

## Future tooling

- **OCI referrer portability:** preserving image manifests without preserving
  their referrer graph loses signatures/SBOMs. Standardized graph-aware copy and
  bundle tooling is the next step beyond this local registry demonstration.
- **Cosign evolution:** migrate the tested v2 experimental OCI format toward
  stable bundle/referrer interoperability as Ratify support evolves; rerun the
  no-legacy-tag and offline tests rather than assuming CLI compatibility.
- **Evidence policy:** build on the tested signed-SPDX requirement with DSSE
  attestations, producer identity, freshness and independently verified SBOM
  coverage. Document signatures alone do not establish inventory correctness.
- **Lifecycle:** package signed trust snapshots, expiry windows, root rollover
  and revocation deltas with applications; verify those updates inside the
  disconnected site. Referrer-aware tooling alone cannot solve trust freshness.

References: [Ratify manual install](https://ratify.dev/docs/quickstarts/quickstart-manual/),
[Notation documentation](https://notaryproject.dev/docs/),
[go-httpbin v2.26.0](https://github.com/mccutchen/go-httpbin/releases/tag/v2.26.0).
