# Offline GitOps with Flux or Argo CD, Gitea and Podinfo

| Spectrum level | Demo app | Headline tooling |
|----------------|----------|------------------|
| 3 | podinfo | flux / Argo CD, gitea, git bundle |

Full GitOps loop (push → reconcile → deploy) inside the boundary

[Offline spectrum](../../docs/offline-spectrum.md) · [Top-level README](../../README.md)

This demo tests the missing half of offline GitOps: how a Git change crosses
the boundary after the hosted Git provider disappears. Flux reads from local
Gitea, the chart and workload image come from a local OCI registry, and a Git
bundle carries an update into Gitea while the cluster has no Internet route.
The app is [Podinfo](https://github.com/stefanprodan/podinfo), deployed using
its Helm chart and a Flux `HelmRelease`.

The optional **Argo CD variant** exercises the same boundary, private Gitea,
local image registry, bundle import and observable update. It vendors the pinned
Helm chart into Git and uses an automatically synced `Application` instead of
a Flux HelmRelease. Neither variant requires a hosted Git provider offline.

**Offline spectrum: level 3.** See the shared [offline spectrum](../../docs/offline-spectrum.md).
Reconciliation and update delivery work inside the isolated boundary. This is
a container/cluster isolation simulation on a connected Linux host, not a
physically disconnected machine; the host remains the operator/transfer station.

## Architecture

```text
CONNECTED HOST (Internet)                AIR-GAPPED BOUNDARY
                                         Docker network --internal
Flux CLI, Helm, kind, kubectl             +------------------------------+
  | pull tool/controller/app images       | Gitea (SSH)      local OCI    |
  | fetch Podinfo chart                   |   |              registry    |
  | push everything to localhost          |   |               ^         |
  | create offline.bundle + update.bundle  |   |               |         |
  +-------------------------------------->|   |         kind control-plane|
      local operator/transfer bridge       |   +------ Flux controllers  |
                                          |              |              |
                                          |              +-- Podinfo     |
                                          +------------------------------+
                                                  no external egress

offline.bundle: baseline app manifests -> Gitea -> Flux bootstrap
update.bundle: connected-side follow-up commit -> local SSH import -> Flux
```

For Argo CD, replace the Flux controllers with Argo CD's non-HA installation:
Gitea supplies both the Helm chart and its values to repo-server; the application
controller applies the rendered resources; containerd pulls Podinfo and all
Argo CD components from the internal registry. The OCI chart is also staged,
but Argo CD deliberately consumes the chart from Git, not that OCI artifact.

The registry and Gitea use dynamically assigned IPs on the internal Docker
network. The registry is briefly attached to Docker's default bridge during
CONNECTED staging so the host can push to its published loopback port; the
script then attaches it to the internal network and disconnects the bridge
before AIR-GAPPED begins. kind cannot reliably boot on a Docker `--internal`
network, so its node starts on kind's regular Docker bridge during CONNECTED
staging. Before the phase boundary, the script attaches the node to the
internal services network and installs `iptables` OUTPUT and FORWARD reject
rules on the bridge-facing interface for both IPv4 and IPv6. Only replies to
inbound administration are exempt; connections opened during CONNECTED staging
do not remain exempt. Those rules prevent node and pod egress; the internal
interface remains available to Gitea and the registry.
The internal service IPs are substituted into the generated kind
configuration and Git repository, so Flux does not rely on Docker DNS being
available to pods. kind's containerd is configured for HTTP access to the
local registry; this is deliberately an unauthenticated, disposable demo
registry.

## Tested with

Tested on **2026-10-17**, Linux amd64, Docker Engine and CLI **29.9.1**:

| Component | Pinned version |
| --- | --- |
| Flux CLI | 2.5.1 |
| source-controller | 1.5.0 |
| kustomize-controller | 1.5.1 |
| helm-controller | 1.2.0 |
| notification-controller | 1.5.0 |
| Argo CD (optional variant) | 3.1.9 |
| Helm bundled in Argo CD repo-server | 3.18.4 |
| Dex (Argo CD installation) | 2.43.0 |
| Redis (Argo CD installation) | 7.2.11-alpine |
| kind | 0.27.0 |
| Kubernetes node image | `kindest/node:v1.32.2` |
| kubectl | 1.32.2 |
| Helm | 3.17.1 |
| Gitea | `gitea/gitea:1.23.8` |
| Distribution registry | `registry:2.8.3` |
| Podinfo chart | 6.15.0 |
| Podinfo image | `ghcr.io/stefanprodan/podinfo:6.15.0` |
| egress probe image | `curlimages/curl:8.12.1` |
| Host helpers | Bash 5.2.21, Git 2.43.0, curl 8.5.0, jq 1.7, OpenSSH 9.6p1, GNU coreutils 9.4 |
| ShellCheck (validation only) | 0.9.0 |

`scripts/install-tools.sh` downloads pinned amd64 Flux, kind, kubectl and Helm
binaries into the ignored `.tools/` directory and checks their reported
versions. Container images and the chart are pinned separately in
`scripts/common.sh` and `config/git-repo/`.

## Prerequisites

- Linux amd64 host with Docker Engine and Docker CLI; at least 4 CPUs, 6 GiB
  available RAM and 8 GiB free Docker storage. Allow 8 GiB RAM and 12 GiB
  storage for the larger Argo CD variant.
- Outbound Internet during CONNECTED staging to GitHub releases, GHCR,
  Docker Hub, and `stefanprodan.github.io`. The Argo CD variant also uses
  `raw.githubusercontent.com` and `quay.io`.
- Bash, Git, curl, `jq`, `ssh-keygen`, `ssh-keyscan`, `od`, `sha256sum`,
  `xargs`, and `clear` (interactive terminal only).
- Ports `127.0.0.1:5001` and `127.0.0.1:16443` unused. Gitea uses its
  internal bridge IP directly; it does not publish host ports.
- Docker access without `sudo`; kind requires privileged containers.

This demo owns fixed Docker object names (`offline-gitops-net`, its containers,
and named volumes). Do not run concurrent copies on the same Docker engine.
The `.state/` directory contains temporary credentials, SSH keys, kubeconfig,
Git worktrees and bundles; it is ignored and deleted by cleanup.

## Run the demo

One orchestrator drives every phase from one terminal:

```bash
cd advanced-demos/offline-gitops-flux
./scripts/run-demo.sh
```

The script pauses between phases when attached to an interactive terminal. For
an unattended rehearsal:

```bash
DEMO_AUTO_ADVANCE=1 ./scripts/run-demo.sh
```

### Argo CD variant

```bash
./scripts/run-demo.sh --argocd
# Or unattended:
DEMO_AUTO_ADVANCE=1 ./scripts/run-demo.sh --argocd
```

The same cleanup and object names are used: **each run recreates the demo**,
so run the variants sequentially, not concurrently. No Argo CD CLI is needed.
The existing pinned Flux CLI is still installed by the shared tool installer.
The phase descriptions below describe the default Flux run; Argo CD differs
as follows:

1. **CONNECTED:** download the official
   [v3.1.9 installation manifest](https://github.com/argoproj/argo-cd/blob/v3.1.9/manifests/install.yaml).
   Extract and mirror its three unique image references, including images used
   by init containers. Use official Redis `docker.io/library/redis:7.2.11-alpine`
   rather than the manifest's public ECR mirror, which rate-limited the rehearsal.
   Mirror Argo CD from Quay and Dex from GHCR. Extract Podinfo's chart into
   `apps/podinfo` in the generated Git repository and add
   `values-offline.yaml` with the local image address, one replica and baseline
   message. Both the chart and values travel inside each Git bundle.
2. **AIR-GAPPED:** rewrite every controller/init-container image to the local
   registry and server-side apply the staged installation, not a remote URL.
   Register the generated SSH key as a repository Secret and the scanned Gitea
   host keys in `argocd-ssh-known-hosts-cm`. Create the
   [Application](config/argocd/application.yaml) with automated sync, prune and
   self-heal, rendering the chart with the bundled values. Wait for its exact
   Git revision, successful sync operation, `Synced` and `Healthy`, then verify
   one ready replica and the live baseline HTTP message.
3. **AIR-GAPPED UPDATE:** import the second bundle using the same checksum,
   fetch, cherry-pick and local SSH push path. A hard-refresh annotation
   accelerates Git discovery; **the controller performs the automatic sync**,
   not a host-side `helm upgrade` or `kubectl apply` of Podinfo. Check the
   imported SHA, successful sync, two ready replicas and the updated live
   message. Repeat the same external-egress negative/local-registry positive
   controls before and after the update.

Argo CD uses [Helm to render resources](https://argo-cd.readthedocs.io/en/release-3.1/user-guide/helm/),
not to manage a Helm release. The chart has no external dependencies; no
dependency download is needed offline. Repository credentials are generated
under ignored `.state/` and stored in the disposable cluster, never committed.
This is Argo CD's standard non-HA evaluation installation with broad cluster
permissions, not a hardened production configuration.

#### Flux versus Argo CD in this demo

| Concern | Flux (default) | Argo CD (`--argocd`) |
| --- | --- | --- |
| Reconciliation entry point | GitRepository + Kustomization | Git-backed Application |
| Chart transport | Local OCI registry via OCIRepository | Pinned chart vendored in the Git bundle |
| Helm behavior | HelmRelease drives Helm install/upgrade and release state | Repo-server runs Helm templating; Argo CD owns sync/lifecycle |
| Bootstrap | Flux CLI commits its own manifests to Gitea | Apply staged controller manifests and a local Application; no bootstrap Git commit |
| Update | Bundle carries HelmRelease values | Bundle carries chart and Helm values |
| Import history | Cherry-pick preserves Flux's bootstrap commit | Same importer works; no bootstrap commit to preserve |
| Operator surface | Flux CLI and Kubernetes CRs | Application sync/health CRs; server/UI available but not needed |
| Offline payload | Four controller images plus chart OCI artifact | Three unique images across seven controller workloads, plus chart files in Git |

Vendoring is intentional: one checksummed bundle carries the chart and values
without plain-HTTP OCI repository configuration. It enlarges Git history when
charts change. Argo CD also supports native OCI Helm sources and multi-source
Applications; this variant does **not** claim to exercise those features.

### Phase 1 — CONNECTED

The host installs the pinned CLI tools, pulls the Gitea, registry, kind node,
Podinfo and probe images, then exports the four Flux controller image
references from `flux install --export`. It copies those images into the local
registry and imports the Podinfo chart as an OCI artifact.

The script also initializes a local Git repository with the Podinfo
`OCIRepository` and `HelmRelease`, creates `offline.bundle` for the baseline,
commits a two-replica/message update, and creates `update.bundle`. Both bundle
SHA-256 checksums are saved in `.state/bundle-checksums.txt`. Finally it
creates the kind cluster while the host is still connected, attaches the node
to the internal services network, and proves external HTTPS works from the
node. It records that destination's IPv4 address for DNS-independent negative
tests, then installs IPv4/IPv6 egress-blocking rules before clearing the screen
for AIR-GAPPED.

Flux's official [air-gapped installation guide](https://fluxcd.io/flux/installation/configuration/air-gapped/)
documents mirroring controller images and passing `--registry` to bootstrap.
The script verifies these options against the pinned CLI and uses:

```bash
flux install --export
flux bootstrap git --registry=<internal-registry-ip>:5000/fluxcd ...
```

The versioned [Flux `install` CLI reference](https://fluxcd.io/flux/cmd/flux_install/)
defines `--registry` as the registry used for toolkit controller images.

### Phase 2 — AIR-GAPPED

Gitea starts on `offline-gitops-net`, and the script:

1. Creates the Gitea admin user non-interactively with
   `gitea admin user create`, creates a private repository through Gitea's
   local API, and registers a generated Ed25519 public key.
2. Pushes the baseline Git bundle into that repository over SSH.
   Bundle SHA-256 checksums are verified before this initial import and again
   before the update import.
3. Uses the prepared kind node. Its egress-blocking rules prevent outbound
   traffic over kind's regular Docker bridge; its internal interface can reach
   only Gitea and the local registry. Flux and Podinfo images are already
   present in that registry.
4. Runs `flux bootstrap git` with the private key and the local registry
   override. Flux commits its controller manifests to Gitea and configures
   the cluster to reconcile `clusters/demo`.
5. Explicitly reconciles the HelmRelease after the Kustomization, waits for
   its current generation and Deployment rollout, and checks exact Git
   revisions, one updated/ready/available replica, and the live Podinfo HTTP
   message. An embedded logo replaces Podinfo's default GitHub-hosted logo.
6. Checks Docker network membership and IPv4/IPv6 firewall rules. Fresh
   clients sharing the node, Gitea and registry network namespaces must reach
   the local registry but fail external HTTPS against the previously reachable
   IPv4 address. A Kubernetes probe pod must also reach the local registry and
   fail external IPv4 and IPv6 HTTPS. Missing tools, image failures, DNS errors
   or HTTP/TLS errors are not accepted as evidence of isolation.

The OCI chart source uses a Flux `OCIRepository` with `insecure: true` because
the local registry is HTTP. `HelmRelease.chartRef` points at that local chart
artifact; its image points at the same registry. The selected behavior is
documented in Flux's [OCIRepository](https://fluxcd.io/flux/components/source/ocirepositories/)
and [HelmRelease](https://fluxcd.io/flux/components/helm/helmreleases/)
references. The repository manifest uses `source.toolkit.fluxcd.io/v1beta2`,
the served OCIRepository API version in the pinned Flux 2.5.1 CRDs.

### Phase 3 — AIR-GAPPED UPDATE ROUND TRIP

The update commit and its bundle were created on the connected host, then
staged before isolation. The script verifies the bundle SHA-256 checksums,
fetches the update commit from `update.bundle`, cherry-picks it onto the
post-bootstrap Gitea history, and pushes it over the internal SSH path. Cherry-picking is
needed because Flux bootstrap added its own commit to Gitea after the baseline
bundle was imported. Flux reconciles that new commit; the Deployment changes
from one to two replicas. The script checks the exact imported Git revision,
Helm's current generation, two ready replicas, and the live message
`Updated through offline bundle`, then repeats all isolation checks.

Checksums detect transport corruption, not malicious replacement of the bundle
and its checksum file together. They are not signatures. `git bundle verify`
checks bundle prerequisites/header metadata; SHA-256 verification is the byte
integrity check before import.

## Expected evidence

Versions and hashes are stable; IPs, timestamps, pod names and digests vary.
Near the end, expect output equivalent to:

```text
PASS: the Kubernetes pod reaches the registry; external IPv4/IPv6 HTTPS is blocked.
NAME          REVISION              SUSPENDED  READY  MESSAGE
flux-system   main@sha1:<revision>  False      True   stored artifact ...
NAME          REVISION              SUSPENDED  READY  MESSAGE
flux-system   main@sha1:<revision>  False      True   Applied revision ...
podinfo-...   1/1       Running
podinfo-...   1/1       Running
desired=2 ready=2
PASS: revision <commit>, 2 ready replicas, live message "Updated through offline bundle" and embedded logo.
COMPLETE: flux reconciled the Gitea update with external egress blocked.
Total runtime: <minutes>m <seconds>s
```

The initial evidence block shows `desired=1 ready=1`. If Flux reports
`Ready=True` but the new revision has not appeared yet, the orchestrator's
explicit `flux reconcile` and rollout waits have not completed and the run
does not claim success.

For the Argo CD run, the evidence block instead includes:

```text
NAME      SYNC STATUS   HEALTH STATUS
podinfo   Synced        Healthy
desired=2 ready=2
COMPLETE: argocd reconciled the Gitea update with external egress blocked.
```

Additional Application columns depend on kubectl's CRD printer. The script also
checks `.status.sync.revision` and the successful operation's revision against
the exact imported commit; a stale Healthy condition is not sufficient.

## Validation results

The final Argo CD addition and default Flux regression both passed on
**2026-10-17**, each recreating the cluster, Gitea and registry:

| Full orchestrator run | Runtime | Result |
| --- | --- | --- |
| Argo CD 3.1.9, final rehearsal | **2m 39s** | Synced/Healthy at baseline and imported update SHA; live app 1 -> 2 ready replicas and updated message |
| Flux 2.5.1, default regression | **1m 57s** | Git source/Kustomization/HelmRelease reconciled; same live app update |

Both final runs used cached upstream Docker layers and tool binaries, but
new registry volumes and new kind nodes. Argo CD's seven workloads, including
all init containers, referenced the internal registry. Identical isolation
checks passed before and after both updates. Negative Argo CD assertions
rejected an incorrect Git SHA and an incorrect live message. The first Argo CD
attempt failed honestly during CONNECTED on public ECR's Redis rate limit;
the explicit Docker Hub source resolved it. The first successful Argo CD run
took **4m 51s** before the final rehearsal. Runtime includes staging and waits,
but not post-run cleanup; cold downloads and interactive pauses add time.

Earlier Flux-only validation:

On 2026-10-17, the full demo was rerun from recreated cluster, Gitea and registry
volumes, including a fresh download of all four CLI tools. The final successful
orchestrator runtime was **1m 34s** with Docker image layers cached; separate
fresh CLI downloads and cleanup are not included in that duration.

Verified baseline `1/1`, update `2/2`, the exact reconciled Git commits, both live
HTTP messages, all four controller image references pointing to the internal
registry, bundle checksums, and isolation before and after the update.
Negative tests rejected an incorrect expected message, an incorrect Git
revision, missing firewall rules, a corrupt bundle checksum and a truncated
bundle import. The IPv4 destination was reachable before isolation. IPv6
firewall rules and failed IPv6 pod requests were checked, but native IPv6
Internet connectivity was not established as a connected positive control.

Static checks:

```bash
shellcheck -x -P scripts scripts/*.sh
for script in scripts/*.sh; do bash -n "$script"; done
```

Cleanup was run twice and checked for absence of the demo's containers, network,
volumes and `.state/` credentials. The Docker-wide shared `kind` network and
cached images/tools are deliberately retained.

## Troubleshooting

- **Port already allocated:** stop the process using the conflicting loopback
  port or change the matching published port and API-server port before
  running. The ports are listed in Prerequisites.
- **Registry push/pull errors:** confirm Docker can access GitHub/GHCR in
  CONNECTED staging and check `docker logs offline-gitops-registry`. No
  controller or workload pull should go upstream.
- **Flux `ImagePullBackOff`:** inspect
  `kubectl -n flux-system describe pod <pod>` and confirm that all four image
  tags appear in the local registry API, for example
  `curl --noproxy '*' http://<registry-ip>:5000/v2/fluxcd/source-controller/tags/list`.
  `config/kind.yaml` sets containerd's registry mirror to HTTP.
- **Gitea SSH authentication:** inspect
  `docker logs offline-gitops-gitea`, `.state/home/.ssh/known_hosts`, and the
  generated public key's Gitea account registration. The private key remains
  under the ignored `.state/ssh/` directory.
- **Chart pull or HelmRelease failure:** check
  `kubectl -n podinfo get ocirepository,helmrelease` and
  `kubectl -n podinfo describe helmrelease podinfo`. The chart tag must be
  `6.15.0`, and the OCI source must use the internal registry's current IP.
- **Argo CD sync failure:** inspect
  `kubectl -n argocd get application podinfo -o yaml` and
  `kubectl -n argocd logs deployment/argocd-repo-server`. A comparison error
  commonly means incorrect SSH host keys, missing credentials, or an incorrect
  Git path. Confirm the bundled chart and `values-offline.yaml` exist at
  `apps/podinfo`. For pull errors, inspect the failing pod's normal and init
  image references; all must use the internal registry.
- **Egress probe succeeds:** stop. The run is not a successful offline demo.
  Verify `offline-gitops-net` is marked `Internal: true` and inspect the
  IPv4 and IPv6 `OUTPUT`/`FORWARD` rules in the kind node with
  `docker exec offline-gitops-control-plane iptables -S` and
  `docker exec offline-gitops-control-plane ip6tables -S`.
- **Failure midway:** state and logs are intentionally retained. Inspect with
  `docker ps -a`, `docker logs`, and the pinned tools in `.tools/`; then run
  `./scripts/cleanup.sh` before retrying.

For manual inspection from the demo directory after a successful run:

```bash
export PATH="$PWD/.tools:$PATH"
export KUBECONFIG="$PWD/.state/kubeconfig"
flux get sources git -A
flux get kustomizations -A
kubectl -n podinfo get helmrelease,ocirepository,pods
kubectl get --raw /api/v1/namespaces/podinfo/services/http:podinfo:9898/proxy/
```

For Argo CD, replace the Flux-specific commands with:

```bash
kubectl -n argocd get application podinfo -o wide
kubectl -n argocd get application podinfo -o jsonpath='{.status.sync.revision}{"\n"}'
kubectl -n podinfo get deployment,pods
kubectl get --raw /api/v1/namespaces/podinfo/services/http:podinfo:9898/proxy/
```

## Cleanup

```bash
./scripts/cleanup.sh
```

This deletes only this demo's kind cluster, containers, Docker network,
registry/Gitea volumes and `.state/` credentials and bundles. The downloaded
pinned binaries in `.tools/` are retained for faster reruns.

## Known limitations

- This models an isolated cluster boundary on a connected host. The host
  retains Internet access and can communicate with the internal network
  through its bridge route. The kind node retains a normal Docker network
  attachment, but its external-interface OUTPUT and FORWARD paths are
  firewall-blocked for IPv4 and IPv6 before AIR-GAPPED begins. The operator
  host can change those rules or add Docker attachments; it is trusted.
- A registry IP is inserted into this run's Git commits and cluster config.
  Recreating the Docker network requires recreating both bundles and
  bootstrapping again; the script does this on every run.
- The demo registry is HTTP and unauthenticated; Gitea is a single disposable
  instance. Neither is a production security configuration.
- kind's CNI and this per-node `iptables` rule set are not equivalent to a
  physically isolated cluster or a production CNI enforcing NetworkPolicy.
- Controller image signatures, image digest pinning, repository signing and
  bundle signature verification are intentionally not part of this demo.

## Where network is still required

Internet is required on the **host** during CONNECTED staging to fetch tools,
the pinned Gitea/registry/kind/Podinfo/probe images, selected controller images,
the Argo CD install manifest when selected, and the Podinfo chart. During AIR-GAPPED phases the containers and Kubernetes
pods cannot egress to external destinations, checked with namespace-level and
pod-level HTTPS probes. The host remains the local operator/transfer bridge and uses SSH to import the
bundle into Gitea; that local access is required and is not Internet access.
Running this on a physically offline host therefore requires preloading the
pinned binaries, images, chart, and bundle outside this orchestrator.

## Future tooling

Flux's native OCI source support makes a Helm chart a first-class local
artifact rather than a pre-rendered exception. A next iteration could verify
the bundle and OCI artifacts with signatures before import, pin controller
and Podinfo images by digest, and use a registry with TLS and authentication.
For an operational deployment, compare this Git-bundle handoff with
content-addressed OCI Git artifacts and a controlled transfer gateway; keep
the Git revision and artifact digest linked in the release record.
The included Argo CD variant compares Application reconciliation with the same
bundle-import boundary. A further extension could use a local OCI Helm source
plus Git-hosted values for Argo CD, comparing artifact promotion and trust
without vendoring chart files into Git.
