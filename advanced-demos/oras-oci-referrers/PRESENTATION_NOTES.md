# Presenter notes: an image is not the whole deployment

## Story

“We have already learned to carry images offline. But what happens when admission
requires an SBOM, platform policy lives beside the image, and an application wants
model data? The deliverable is a graph, not a tag.”

Use this as an advanced follow-on to the cache and bundle demos, and as a concrete
bridge to the talk's **Future work** slide: OCI registries as artifact stores,
portable metadata, graph-aware promotion, and eventually offline trust.

This example deliberately uses official stable Alpine, not an application build:
the interesting change is the supply-chain packaging around a familiar image.

## Before going on stage

- Read the isolation and authenticity limitations in [README.md](README.md).
- Rehearse [scripts/run-demo.sh](scripts/run-demo.sh) on the actual Linux amd64
  Docker host. Check it prints both PASS lines. Prepare tool downloads/builds in
  advance by doing one full run; do not rely on conference Wi-Fi for first pulls.
- Run [scripts/cleanup.sh](scripts/cleanup.sh) to remove registry storage.
  Downloaded tools remain local. A new run also resets those resources itself.
- Use a wide terminal for full digests. The presenter-paced run is:

  ```bash
  DEMO_PAUSE_SECONDS=8 ./scripts/run-demo.sh
  ```

- Default two-second sleeps gave 18- and 78-second warm rehearsals on 2026-10-17;
  allow two to four minutes for explanation, not just command execution.
  Banners clear an interactive terminal, but evidence is retained under
  `.state/latest`. Redirected output is not cleared.

## Key beats

### CONNECTED: preparation is part of the contract

1. **Phase 1 — Tools are inputs too.** zot, ORAS, Syft and Alpine are version
   pinned. Tool images must already exist before isolation.
2. **Phase 2 — Point at the three reverse edges.** The image digest is the
   immutable anchor. The SBOM is real Syft output; policy is illustrative JSON;
   the 1024-byte fake model makes the universal artifact-store story tangible.
   Do not call it a trained model or a ModelKit.
3. **Show the endpoint JSON.** `artifactType`, `digest` and `size` are descriptors
   returned by zot's native referrers API, not fabricated tag parsing. The
   attached manifest contains `subject.digest`.
4. **Phase 3 — The critical flag is `--recursive`.** Image layers are forward
   dependencies; referrers point back toward their subject. Ordinary image copy
   is not enough. Carry the complete layout directory, not just its index file.

### AIR-GAPPED: prove the outage, then prove the result

5. **Phase 4 — Remove the crutch.** Source zot and its uplink disappear. The
   destination is a second registry with new storage on an internal network.
   Clients share its namespace. Firewall rules allow only loopback; even Docker
   DNS forwarding is blocked. Public-address and DNS probes must fail.
6. **Phase 5 — The destination has to reconstruct it.** Import the OCI layout.
   Show the same image and three referrer digests. ORAS pulls every payload from
   the isolated registry and compares original bytes.
7. **Finish on the stronger assertion.** After intentional probes are reset,
   external-rejection counters must remain zero throughout the actual workload.
   Do not confuse that packet-level check with tracing every failed `connect()`
   syscall: a no-route failure can happen before OUTPUT.

The raw ASCII/Unicode tree may reorder siblings because response order is not
graph identity. The verifier compares canonical recursive discovery JSON while
retaining every field, plus all manifest digests and payload bytes. Explain
this before someone mistakes a different sibling position for lost data.

## Likely questions

**Is this a physically air-gapped machine?** No. It is a rootful Docker enclave,
with real egress enforcement for both registry and client. The host and daemon
are connected; tooling/provisioning transfer is outside the graph bundle.

**Are you really making no network calls?** There is necessary loopback registry
HTTP. Outside-enclave probes intentionally fail before measurement. External
access is blocked; import, discovery and pull must produce zero rejected OUTPUT
packets. Counters do not observe syscalls rejected earlier by routing.

**Why not Docker save/load?** That transports runtime images, not a discoverable
repository's subject/referrer graph. This layout is exported with graph-aware
ORAS copy, and reconstructed using the destination registry's API.

**Why not just mirror all tags?** Native referrers need not have user tags.
Legacy signature-tag and fallback-index conventions differ between tools.
Follow subjects and reverse edges explicitly.

**What about multi-arch images?** This run selects linux/amd64 and attaches to that
manifest. It does not claim to mirror Docker Hub's entire index and attestations.

**Does the SBOM prove the image is safe?** No. It inventories packages, not risk,
and this demo does not query a vulnerability database or enforce policy.

**Do checksums prove who published the artifacts?** No. They prove preservation.
The inventory is not signed. Cosign plus an offline verification/trust bundle
is future work; never imply signature verification was demonstrated.

**Will this work with every registry?** Only when the required API and artifact
semantics are supported. The script forces OCI 1.1 native referrers and fails
rather than silently using tags.

**Does it really run a model?** No. The fake blob is exactly 1024 bytes. It hints
at model distribution without requiring a GPU, a model download or a huge demo.

## If it fails live

Do not edit isolation rules or read out an old PASS as if it belonged to the
current run. Keep the error visible, inspect the reported evidence, and explain
whether tooling acquisition, privileges, transfer integrity or graph discovery
failed. `NET_ADMIN`/ip6tables failures require a suitable Linux sandbox, not a
weaker claim. Remove resources using [scripts/cleanup.sh](scripts/cleanup.sh).

If using saved evidence as a fallback, explicitly label it as a prior rehearsal
and show its test date, versions and runtime. Close with: “The next packaging
unit is the verified artifact graph, not the container tag.”
