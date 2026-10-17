# Taking cloud-native offline: carry the whole OCI artifact graph

| Spectrum level | Demo app | Headline tooling | Status |
|----------------|----------|------------------|--------|
| 3 | alpine | oras, zot, syft, cosign | Verified 2026-10-17 |

OCI 1.1 artifact graph (SBOM, policy, model, signature) travels offline intact

[Offline spectrum](../../docs/offline-spectrum.md) · [Top-level README](../../README.md)

An image mirror is incomplete when the deployment also needs its SBOM, policy,
signature or model data. This demo takes the official stable **Alpine 3.24.2**
image, attaches three small artifacts and a Cosign signature, exports their graph
as an OCI layout, and reconstructs it in a fresh, isolated zot registry.
Cosign verifies the image with a local public key, without contacting Sigstore
services. No remote repositories are
created, forked or pushed; the only pushes are into disposable local registries.

**Offline spectrum: level 3.** See the shared [offline spectrum](../../docs/offline-spectrum.md).
This demo uses a prepared, disconnected runtime enclave; it does not provision
an independently operated air-gapped platform or claim a physically disconnected host.

## Why OCI 1.1 changes the offline strategy

OCI image manifests now have standard `artifactType` and `subject` fields.
An attached artifact's manifest records the image's digest as its subject. The
Distribution 1.1 endpoint
`GET /v2/<repository>/referrers/<subject-digest>` returns an OCI index of
descriptors referring to that subject. The registry stores and serves the
relationships; clients do not need to infer them from tag names.

Historically, tools used conventions such as `sha256-<digest>.sig` (signatures),
or maintained a referrers index under a synthetic tag on registries without the
API. These are different legacy mechanisms, not a universal artifact schema.
An ordinary tag-list mirror can miss either convention, and copying just the
subject manifest follows image layers, **not reverse referrer edges**.
`oras copy --recursive` is the important difference here: copy the graph closure,
not an image list. An OCI layout is the portable, content-addressed carrier.

This demo forces `v1.1-referrers-api` on registry attachment, discovery and recursive
copy. There is **no silent legacy fallback**. zot v2.1.15 serves the endpoint;
the script also prints its raw JSON. If a replacement registry lacks the API,
upgrade it rather than presenting a tag-schema run as this native-API demo.

For the talk's **Future work** slide, the takeaway is: “Move from image-list
mirroring to dependency-graph closure, with portable metadata and offline trust.”
The future is not simply more image cache capacity.

## Architecture

```text
CONNECTED
  Docker Hub official alpine (pinned index; select linux/amd64)
                     |
                     v
  connected zot <--> ORAS + Syft client (same network namespace)
  demo/alpine@sha256:IMAGE
       ^ subject     ^ subject       ^ subject          ^ subject
       |             |               |                  |
       SBOM          policy.json     model.bin          Cosign bundle
       SPDX JSON     metadata only   1024 fake bytes    key-only signature
                                     NOT a ModelKit
                     |
              oras copy --recursive --to-oci-layout
                     v
        .state/latest/bundle/{index.json,oci-layout,blobs/...}

  ===== source zot and its uplink are REMOVED =====

AIR-GAPPED
  OCI layout --> oras copy --recursive --from-oci-layout
                               |
                               v
                 fresh offline zot + fresh storage
                 docker network --internal
                 client shares zot's network namespace
                 IPv4/IPv6 OUTPUT allows only ::1 / 127.0.0.1
                 all other output REJECTed, including embedded DNS
                               |
                 discover + pull all three data artifacts
                 Cosign fetches and verifies the signature referrer
                 compare digests, graph and original bytes
```

Neither registry publishes a host port. Both can use `localhost:5000` because
each client joins its registry's network namespace. This also makes the reference
names identical for graph comparison. No Docker socket is mounted in clients.
Registry volumes are separate; there is no shared registry storage or sync
configuration. The source image's selected amd64 manifest is the subject, **not
the upstream multi-architecture index** or Docker Hub's own attestation graph.

## Prerequisites

- A **rootful Linux amd64 Docker engine** and permission to use its CLI.
  The pinned zot image is architecture-specific.
- Kernel support for network namespaces and iptables/ip6tables (nft backend is
  tested), and permission to grant a short-lived helper `NET_ADMIN`.
  Full `--privileged`, host networking and host firewall changes are not used.
- Host Bash 4+, `flock`, `jq`, `diff`, `sha256sum`, `date`, `du`, `sleep`, and
  `clear` for interactive terminals. No host ORAS, Syft, Cosign or Compose is required.
- About 1 GB free Docker storage for tools and builds. The actual transferable
  graph is about 3.9 MiB; tool images are not part of that layout.
- CONNECTED access to Docker Hub (auth service and blob CDN), GHCR, and Alpine
  package mirrors. Docker Hub anonymous pull limits still apply.
- Only one run per Docker engine: names use the fixed
  `offline-oras-referrers` prefix. A local lock serializes run/cleanup commands.
  Unowned Docker resources with those names cause an explicit refusal.

Use a local checkout on the Docker host: the scripts use bind mounts, so a
remote Docker context with a different filesystem is not supported.

## Run in one terminal

From the repository root:

```bash
cd advanced-demos/oras-oci-referrers
./scripts/run-demo.sh
```

The orchestrator clears interactive terminals between numbered phases, prints
CONNECTED/AIR-GAPPED banners and sleeps two seconds per phase. Non-interactive
output is not cleared. For a faster rehearsal:

```bash
DEMO_PAUSE_SECONDS=0 ./scripts/run-demo.sh
```

The default run is unattended. To give a live narration more breathing room,
set `DEMO_PAUSE_SECONDS=8`. The measured duration includes phase sleeps.
The script exits nonzero on failed assertions and never prints a successful
result after a failed import or isolation check. On failure, inspect the
reported evidence directory and then run cleanup. A rerun removes only
label-owned demo containers, networks and registry volumes, creates fresh
registries, and retains previous evidence in separate run directories.

### CONNECTED: phases 1–3

1. Build the tools container from digest-pinned Alpine, ORAS, Syft and Cosign images;
   pull the digest-pinned zot image. Direct APK tool versions are pinned in
   [config/Dockerfile](config/Dockerfile). Its image defaults also support
   standalone builds; keep them aligned with [versions.env](config/versions.env)
   when updating pins. The orchestrator passes those pins explicitly.
2. Copy the official Alpine image into connected zot with `--platform
   linux/amd64`. Resolve the destination digest once and use that immutable
   subject for every attachment.
3. Export that exact image into a temporary scanning layout. Syft scans
   `oci-dir:/work/scan` and produces an SPDX 2.3 JSON SBOM (about 91 KiB).
   Attach it as `application/spdx+json`.
4. Attach [policy.json](config/policy.json) as
   `application/vnd.offline-demo.policy.v1+json`. Generate and attach a
   **1024-byte fake model**, `application/vnd.offline-demo.model.v1`.
   These custom demo media types are not industry standards. The policy
   illustrates distribution, not admission enforcement; the blob hints at
   KitOps/ModelKit distribution without claiming to implement its format.
5. Generate ephemeral signing and wrong-key test keypairs on the tools
   container's `/tmp` tmpfs. Save only their public keys under the ignored
   run directory's `trust/`; private keys disappear when that container exits.
   Sign the image digest with Cosign's native Sigstore bundle format, with
   `--tlog-upload=false --use-signing-config=false`. The fourth referrer has type
   `application/vnd.dev.sigstore.bundle.v0.3+json`. Verify it before export.
6. Display the tree (`oras discover --format tree`, the ORAS 1.3 spelling of
   the deprecated `-o tree`) and the raw referrers endpoint. Record manifest
   digests, subject edges, descriptor metadata and recursive discovery JSON.
7. Export using:

   ```bash
   oras copy --recursive --from-plain-http \
     --from-distribution-spec v1.1-referrers-api --to-oci-layout \
     localhost:5000/demo/alpine@sha256:IMAGE /work/bundle:alpine
   ```

   `/work` is the current run directory mounted inside the tools container.
   The layout tag `alpine` is a local entry point, not a legacy referrer tag.
   A SHA-256 inventory covers every layout file, including its index.

### AIR-GAPPED: phases 4–5

1. Delete the connected registry container and its uplink network.
2. Start the second zot with **new storage**, only on a Docker internal network.
   Validate the Docker network configuration and absence of IPv4/IPv6 default
   routes. Install OUTPUT chains in the registry/client network namespace:
   permit loopback to `127.0.0.1` and `::1` only; reject everything else.
   Docker's `127.0.0.11` DNS forwarding address is deliberately not permitted.
3. Run negative probes for public IPv4, public IPv6, Docker Hub DNS and the
   embedded DNS proxy. A successful probe aborts the demo. Verify that the
   firewall actually rejected probe traffic, then zero its counters.
4. Verify the layout inventory and import:

   ```bash
   oras copy --recursive --from-oci-layout --to-plain-http \
     --to-distribution-spec v1.1-referrers-api \
     /work/bundle:alpine localhost:5000/demo/alpine:alpine-3.24.2
   ```

5. Verify the resolved image digest and all four referrer manifest digests;
   hash fetched manifest bytes and verify each artifact's `subject.digest`.
   Compare complete sorted descriptors and canonical recursive discovery trees.
   Pull **all three artifacts** from isolated zot and byte-compare each payload
   against its original. Cosign fetches the fourth referrer from isolated zot,
   verifies it with the public key, and rejects the wrong key. Finally require
   **zero IPv4 and IPv6 non-local REJECT hits during import, discovery, pull and
   signature verification**. A blocked packet during the
   workload is a failure even if the command later succeeds using local data.

Raw tree sibling order is not stable: the API does not promise an ordering.
Both raw trees are retained. Canonical comparison sorts only each `referrers`
array by digest and JSON object keys, retaining every node, edge, annotation,
type, size, digest and reference. It does not strip differences to manufacture
a match.

### Expected output and evidence

Illustrative output, with full digests in the real run:

```text
=== PHASE 2 / CONNECTED: build and sign the image + SBOM + policy + fake model graph ===
localhost:5000/demo/alpine@sha256:d56c381f...
+-- application/spdx+json                         -> sha256:SBOM
+-- application/vnd.offline-demo.policy.v1+json    -> sha256:POLICY
+-- application/vnd.offline-demo.model.v1         -> sha256:MODEL
+-- application/vnd.dev.sigstore.bundle.v0.3+json  -> sha256:SIGNATURE
...
BLOCKED as expected: external-IPv4
BLOCKED as expected: external-IPv6
BLOCKED as expected: Docker-Hub-DNS
BLOCKED as expected: embedded-DNS-proxy
...
PASS: image + 4 referrers, identical digests, descriptors, trees and payload bytes.
PASS: Cosign verified the isolated image; wrong-key verification failed.
PASS: external egress blocked; zero rejected workload packets.
Total runtime: 25s
```

Each run is retained under `.state/run-<UTC timestamp>-<pid>/`; `.state/latest`
points to the newest. Useful evidence:

- `bundle/`, `bundle.sha256`: transferable OCI layout and transport inventory.
- `subject.txt`: selected image digest, tested as
  `sha256:d56c381f961d307a21b3ca004cf1e3910f106644aefb1f43e654c8a56c4fd395`.
- `connected/` and `airgapped/`: raw endpoint JSON, raw trees, canonical trees,
  sorted descriptors, digest lists and all five fetched manifests.
- `pulled/`: artifacts downloaded from the isolated registry.
- `trust/*.pub`: demo signing public key and wrong public key for the negative
  test. No private key is written to the host.
- `connected-signature.json`, `airgapped-signature.json`: identical verified
  image claims; `wrong-key.stderr` records the cryptographic verification error.
- `isolation-probes.txt`, `firewall-probes.txt`, `firewall-workload.txt`,
  `offline-network.json`, `offline-container.json`, `offline-routes*.txt`.
- `tool-versions.txt`, `docker-version.txt`, `tool-images.json`, `result.txt`.

Referrer digests change between new runs because SBOM IDs and manifest creation
timestamps change. **Equality is asserted across the connected/offline boundary
within one run**, not across newly generated SBOMs.

For manual inspection after a successful run:

```bash
source scripts/common.sh
RUN_DIR="$ROOT/.state/latest"
tools "$OFFLINE" curl --noproxy '*' -fsS \
  "http://localhost:5000/v2/demo/alpine/referrers/$(cat "$RUN_DIR/subject.txt")" | jq .
tools "$OFFLINE" oras discover --plain-http \
  --distribution-spec v1.1-referrers-api --format tree \
  "$REPOSITORY:alpine-$ALPINE_VERSION"
```

Manual operations after completion are outside the recorded workload-counter
window. Do not restart the isolated registry for inspection: restarting its
namespace discards the installed firewall. Rerun the orchestrator instead.

## Offline Cosign verification and trust boundary

[verify-signature.sh](scripts/verify-signature.sh) runs:

```bash
cosign verify --key /work/trust/cosign.pub --offline \
  --new-bundle-format=true --insecure-ignore-tlog \
  --trusted-root /demo/trusted-root.json --allow-http-registry \
  localhost:5000/demo/alpine@sha256:IMAGE
```

Cosign retrieves the bundle referrer from the isolated registry, not a sidecar
signature file or host cache. Each verification container starts with an empty
`/tmp` home; the connected Cosign cache is not carried offline. Successful
verification must report exactly the expected image digest and signing predicate.
The script compares connected/offline claims and requires a **signature
verification error** for the wrong key, not just any nonzero exit status.

The local public key is the trust anchor. [trusted-root.json](config/trusted-root.json)
is explicitly empty: it configures **no** trusted Sigstore CAs, transparency logs
or timestamp authorities, avoiding network-backed TUF bootstrap. It does not
replace the `--key` check or cause arbitrary signatures to be accepted.
`--insecure-ignore-tlog` intentionally waives public transparency verification:
no Rekor upload, inclusion proof, signing time, Fulcio identity or keyless
verification is demonstrated. Cosign warns about this waiver. Cosign 3.0.2 also
prints “Existence of the claims in the transparency log was verified offline”
when `--offline` is set, **even with the log check disabled**; that status line
is not evidence of log inclusion in this demo.

For a real transfer, provision and authenticate the public key independently
of the untrusted bundle. Here it is freshly generated and explicitly trusted
within one rehearsal; replacing both key and signature would defeat that trust.
Only the **image digest** is signed. The SBOM, policy and model are not individually
signed or cryptographically bound to the image by this signature: new referrers
can be added without changing the image digest. Their preservation is checked
by the graph comparison, not an admission authenticity policy.

## Tested with

Test date: **2026-10-17**, Linux amd64, kernel **7.0.0-38-generic**.
Image tags **and immutable digests** are recorded in
[versions.env](config/versions.env); direct tool packages are pinned in
[config/Dockerfile](config/Dockerfile).

| Component | Tested version |
|---|---|
| Official Alpine image and tools base | 3.24.2 |
| zot | 2.1.15 |
| ORAS | 1.3.0 |
| Syft | 1.46.0 |
| Cosign | 3.0.2 |
| Docker engine / CLI | 29.9.1 |
| Host Bash / tools Bash | 5.2.21 / 5.3.9 |
| Tools curl / jq | 8.22.0 / 1.8.2 |
| Tools iptables (nf_tables) / iproute2 | 1.8.13 / 7.0.0 |
| Tools GNU coreutils | 9.11 |
| ShellCheck | 0.9.0 |

The final Cosign-enabled end-to-end run on 2026-10-17 took **25 seconds**,
including two-second presenter sleeps, with tools cached. The first signed run
took **37 seconds**, including a cached-base toolbox rebuild.
The layout occupied about **3.9 MiB**.
Allow for variation in connected upstream access and Docker operations.
Initial tool-image pulls/builds are additional network-dependent preparation
costs; no cold-download runtime is claimed. An exact runtime for each completed
run is written to `result.txt`.

Validation also rejected a deleted policy referrer, a corrupted layout index
and an injected blocked packet in the workload-counter check. The Cosign run
also checks wrong-key rejection. A further test deleted the signature referrer:
verification failed with the correct key until the bundle was reimported, proving
the verifier depends on registry content rather than a cached signature.
No private keys were found in the persisted run directory. The toolbox
rebuilt successfully with `docker build --no-cache`. ShellCheck and Bash syntax
checks passed. Repeatability, lock contention, unowned-resource protection and
cleanup (including state purge) are tested; no Kubernetes cluster is required.

## Where network is still required

- CONNECTED pulls from Docker Hub and GHCR, plus APK installation while building
  the toolbox. The host, Docker daemon and build engine remain connected.
- AIR-GAPPED still uses **local loopback HTTP** between ORAS/curl and zot.
  “No network” here means no traffic outside this isolated registry/client
  enclave; it cannot mean no registry protocol traffic.
- Every AIR-GAPPED `docker run` uses `--pull=never`. The daemon must already have
  the registry/tool images. Docker daemon control traffic and host processes
  are **outside** the enclave's isolation proof; this is not host-wide packet
  auditing. Image transfer to a genuinely offline machine also requires
  preloading those runtime/tool images and Docker itself separately.
- Deliberate blocked connectivity probes precede the measured workload. DNS
  forwarding is blocked explicitly rather than trusting internal networking
  alone. Both registry and client output traverse the same firewall.
- Counters measure packets reaching namespace OUTPUT, not every `connect()`
  syscall. A connection rejected by routing before OUTPUT is not counted.
  Isolation still blocks that access; this is not a syscall-level claim that
  no library ever tried a remote address.
- No remote signing service, trust root refresh, vulnerability database or
  online model endpoint is used. Adding one changes the preparation contract.

## Known limitations and troubleshooting

- **`NET_ADMIN`, ip6tables or rootful networking unavailable:** the script fails
  closed, retains evidence, and does not claim a verified air gap. Run on a
  suitable Linux VM. Rootless Docker, Desktop, ARM and restricted CI are
  **untested**; do not remove the guardrails just to obtain a green result.
- **Tool download/auth/rate-limit failure:** resolve GHCR/Docker Hub access in
  CONNECTED and rerun. Docker credentials on the host are not mounted into
  toolbox containers. Private upstream images need an explicit credential
  design; this demo only fetches public content.
- **Pinned APK package no longer available:** rebuild against a deliberately
  updated, tested version set or maintain your own package snapshot. Transitive
  APK dependencies are not an immutable package archive; actual installed
  versions are recorded. Keep the built toolbox image for rehearsals.
- **Referrers endpoint 404, empty list, or wrong artifact count:** check zot
  version/config and the subject digest. Do not drop `--recursive` or use
  ordinary tag mirroring. Snapshot validation requires exactly the three
  data artifact types plus the Cosign bundle type.
- **Firewall workload counter nonzero:** investigate hidden network traffic,
  not just command exit status. Do not reset counters during the workload.
  The final assertion intentionally treats blocked external attempts as bugs.
- **Raw tree diff but matching graph:** sibling order can differ. Compare
  `tree.canonical.json`; sorting display lines is not a safe graph comparison.
- **Failure diagnostics:** `docker logs offline-oras-referrers-airgapped`
  (or `offline-oras-referrers-connected` during CONNECTED) and the current
  evidence directory. No host ports need freeing.
- HTTP without auth/TLS is limited to these disposable namespaces. Checksums
  detect damage against the inventory, not malicious replacement of both.
  Cosign adds image authenticity relative to the demo public key, not an
  independently provisioned publisher identity. Ephemeral private signing keys
  exist only in tmpfs, use an empty password for unattended demonstration, and
  must never be reused for production. No keys or certificates are committed.
- Both stretch goals are implemented: raw referrers API inspection and key-based
  Cosign verification. Keyless signatures and transparency verification remain
  outside this demo's trust contract.

## Cleanup

```bash
./scripts/cleanup.sh                 # registries, networks and storage volumes
./scripts/cleanup.sh                 # safe to repeat
./scripts/cleanup.sh --purge-state   # also delete this demo's local bundles/evidence
```

Pinned downloaded images and the built toolbox are retained to speed rehearsals.
Cleanup never prunes Docker globally or touches another demo. Generated state,
keys and certificate-like files are excluded by [.gitignore](.gitignore).
The ignored `.demo.lock` file deliberately survives state purge so run and cleanup
commands always lock the same inode. Do not remove it while either command is running.

## Future tooling

OCI 1.1 makes subject relationships interoperable, but the operational contract
still needs graph-closure selection, repository-boundary handling, trust policy,
retention/GC and an auditable transfer inventory. Tooling should make “export
everything required to verify and deploy this digest” a first-class operation.
Nested referrers, multiple platforms, large-model chunking, and OCI artifacts
consumed directly by Kubernetes are useful follow-on experiments.

KitOps ModelKits illustrate packaging model-related data in registries, but a
random blob with a custom type is not a conformant ModelKit. This demo now carries
a signature bundle and verifies it against a local key. The next extension is
independently provisioned trust, transparency proofs, key rotation/revocation and
a policy binding every required artifact to the deployment. A signature referrer
alone does not establish those properties.

References: [OCI Distribution referrers specification](https://github.com/opencontainers/distribution-spec/blob/v1.1.1/spec.md#listing-referrers),
[OCI image manifest](https://github.com/opencontainers/image-spec/blob/v1.1.1/manifest.md),
[ORAS copy](https://oras.land/docs/commands/oras_cp/),
[zot](https://zotregistry.dev/),
[Syft](https://github.com/anchore/syft),
[Cosign](https://github.com/sigstore/cosign),
[KitOps](https://kitops.org/),
[official Alpine image metadata](https://github.com/docker-library/official-images/blob/master/library/alpine).
