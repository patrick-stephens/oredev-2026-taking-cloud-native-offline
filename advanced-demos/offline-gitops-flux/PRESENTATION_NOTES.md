# Presentation notes: offline GitOps with Flux or Argo CD

## Story

GitOps is often described as declarative pull reconciliation, but the happy
path hides two external dependencies: a hosted Git provider and a public
image/chart source. This demo replaces both with local services, then makes
the audience watch the part that is usually skipped: a change is bundled on
the connected side, carried across the boundary, imported into local Gitea,
and reconciled by Flux without restoring Internet access.

Use `./scripts/run-demo.sh --argocd` to tell the same story with Argo CD.
The default remains Flux. Each run recreates the same local environment, so
show them sequentially rather than trying to compare two running clusters.

## Key beats

1. **Set the boundary.** Explain that the host is the presenter/operator
   bridge. Gitea and the registry are on a Docker network marked `Internal:
   true`; the kind node has an internal-network leg and explicit `iptables`
   IPv4/IPv6 OUTPUT/FORWARD blocks on its regular bridge leg. Only reply
   traffic for inbound administration is exempt. The host deliberately
   remains online, so do not call this a physically disconnected laptop.
2. **Connected staging.** Point to the exact local copies: four Flux
   controller images, Podinfo image, Podinfo chart, Gitea and the Kubernetes
   node image. Show the generated `offline.bundle`, `update.bundle`, and their
   SHA-256 values.
3. **Bootstrap locally.** Show Gitea's admin user created by the CLI, Flux
   bootstrapping from SSH, and controllers pulling from the registry override.
   The resulting GitRepository and Kustomization are both Ready.
4. **Prove the isolation.** External HTTPS succeeds from the node during
   CONNECTED staging. After the boundary, the node, Gitea, registry and a
   Kubernetes pod must still reach the local registry but fail HTTPS to that
   same external IPv4 destination without relying on DNS failure. The pod also
   attempts IPv6 HTTPS, and both firewall families are checked. These checks
   run again after the update.
5. **Land the update.** The new commit is in the pre-staged bundle, but the
   importer fetches that bundle and cherry-picks the content onto the history
   Gitea now has after Flux's bootstrap commit. It pushes over local SSH only.
6. **Observe reconciliation.** Flux sees a new Git revision. The Deployment
   rolls to two replicas, and the live HTTP message changes to “Updated through
   offline bundle”. The script checks the exact imported Git revision and
   Helm's observed generation, not just a possibly stale Ready condition.
   Podinfo's logo is embedded rather than fetched from GitHub.

## Argo CD presentation beats

- **Same boundary, different reconciliation model.** All controller and init
  images come from the local registry. Three unique images supply six
  Deployments and the application-controller StatefulSet. No Argo CLI is needed.
- **Show the transfer unit.** The Git bundle contains Podinfo's pinned Helm
  chart and `values-offline.yaml`. The local registry supplies the workload
  image. Contrast this with Flux's OCI chart source: bundling the chart reduces
  repository configuration but grows Git history.
- **Watch Application health and revision.** Baseline and update both show
  `Synced` and `Healthy`. Point to the exact imported commit, then the one-to-two
  replica change and live message. A healthy old revision is not success.
- **Explain the refresh.** The script annotates the Application for a hard
  refresh to keep the rehearsal short. Automated sync still performs the
  deployment; the host never runs `helm upgrade` against Podinfo.
- **Keep lifecycle distinctions honest.** Flux's Helm controller creates a
  Helm release. Argo CD templates the same chart, then manages resources and
  their lifecycle itself. Do not use `helm list` as Argo CD evidence.
- **Keep bootstrap distinctions honest.** Argo CD's Application and repository
  credentials are installed locally and it makes no bootstrap Git commit.
  The shared cherry-pick importer remains valid; it is essential for Flux's
  divergent bootstrap history, not essential for Argo CD's baseline history.

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
- **Why not use an OCI chart source with Argo CD too?** It supports OCI Helm
  sources and separate Git values. This variant deliberately vendors the chart
  so a single bundle transfers both chart and values without insecure OCI
  repository settings. It is a transport trade-off, not an Argo CD limitation.
- **Can I use the Argo CD UI?** The standard server is installed, but the
  scripted evidence uses Application CRs rather than login or UI automation.
  The installation is disposable, non-HA and broadly privileged; it is not
  production hardening guidance.
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
  clients in the node, service and pod namespaces cannot complete external
  HTTPS requests while local registry requests work. IPv4 has a connected
  positive control; IPv6 has firewall checks and a failed pod request, not a
  positive control for native Internet connectivity. Docker's internal service
  network plus node-level egress blocks are the mechanisms, not an exhaustive
  adversarial network test.

## Rehearsal result

The final 2026-10-17 rehearsals recreated each environment with cached upstream
Docker image layers and tools:

| Variant | Full runtime | Evidence |
| --- | --- | --- |
| Argo CD 3.1.9 | **2m 39s** | Synced/Healthy at exact baseline/update commits, 1 -> 2 ready replicas, updated live message |
| Flux 2.5.1 regression | **1m 57s** | Ready source/Kustomization/HelmRelease, same live update |

Isolation checks passed before and after both updates. An initial Argo CD
staging run hit public ECR's Redis rate limit; the script now explicitly uses
the same pinned official Redis version from Docker Hub. Argo CD's embedded
Helm was verified as 3.18.4 (the host Helm remains 3.17.1). Incorrect Argo CD
revision and live-message assertions were rejected.

An earlier Flux-only run took 1m 34s; fresh CLI downloads were tested separately.
Allow extra time for cold image downloads and narration; the orchestrator
pauses between phases unless `DEMO_AUTO_ADVANCE=1`. Cleanup is not included
in these runtimes.
