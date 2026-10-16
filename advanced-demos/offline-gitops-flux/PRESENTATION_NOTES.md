# Presentation notes: offline GitOps with Flux

## Story

GitOps is often described as declarative pull reconciliation, but the happy
path hides two external dependencies: a hosted Git provider and a public
image/chart source. This demo replaces both with local services, then makes
the audience watch the part that is usually skipped: a change is bundled on
the connected side, carried across the boundary, imported into local Gitea,
and reconciled by Flux without restoring Internet access.

## Key beats

1. **Set the boundary.** Explain that the host is the presenter/operator
   bridge. Gitea and the registry are on a Docker network marked `Internal:
   true`; the kind node has an internal-network leg and explicit `iptables`
   OUTPUT/FORWARD blocks on its regular bridge leg. The host deliberately
   remains online, so do not call this a physically disconnected laptop.
2. **Connected staging.** Point to the exact local copies: four Flux
   controller images, Podinfo image, Podinfo chart, Gitea and the Kubernetes
   node image. Show the generated `offline.bundle`, `update.bundle`, and their
   SHA-256 values.
3. **Bootstrap locally.** Show Gitea's admin user created by the CLI, Flux
   bootstrapping from SSH, and controllers pulling from the registry override.
   The resulting GitRepository and Kustomization are both Ready.
4. **Prove the isolation.** The orchestrator's short-lived curl pod tries
   `https://example.com`; a non-zero result is required. Then show the
   Podinfo pod Running and its initial one-replica state.
5. **Land the update.** The new commit is in the pre-staged bundle, but the
   importer fetches that bundle and cherry-picks the content onto the history
   Gitea now has after Flux's bootstrap commit. It pushes over local SSH only.
6. **Observe reconciliation.** Flux sees a new Git revision. The Deployment
   rolls to two replicas, and the UI message changes to “Updated through
   offline bundle”.

## Likely questions

- **Is the host really offline?** No. This is an isolated Docker/kind boundary
  on an online host. The host is the transport and administration station;
  containers and pods are what this demo proves cannot reach the Internet.
- **Why use cherry-pick after fetching a bundle?** Flux bootstrap committed
  controller manifests after the baseline bundle was imported. The connected
  update bundle has the baseline commit as its parent, so cherry-pick places
  that update on the Gitea branch that now also contains the bootstrap commit.
- **Why not just use a local Git server and stop there?** The meaningful
  claim is the complete chain: staged chart and image, offline Git import,
  Flux reconciliation, and a second disconnected delivery.
- **Why is the registry HTTP?** The aim is a small reproducible local
  topology. Flux's `OCIRepository` explicitly allows insecure HTTP; a real
  platform should use TLS, authentication, scoped credentials and digest
  verification.
- **What would change for a real air gap?** Preload the pinned tools and
  artifacts through an approved transfer process, verify signatures and
  digests, and keep the operator/transfer path separate from the target's
  network boundary.
- **Why not put kind directly on `--internal`?** kind's node bootstrap breaks
  on Docker's internal network in this environment. The script attaches kind
  to the isolated service network and blocks its external interface with
  `iptables` before AIR-GAPPED begins.
- **Does the probe prove every external destination is blocked?** It proves
  the pod cannot complete an HTTPS request through its normal egress path.
  Docker's internal service network plus node-level egress blocks are the
  isolation mechanisms; this is not a production firewall or exhaustive
  adversarial network test.
