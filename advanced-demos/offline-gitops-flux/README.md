# Offline GitOps with Flux, Gitea and Podinfo

| Spectrum level | Demo app | Headline tooling | Status |
|----------------|----------|------------------|--------|
| 3 | podinfo | flux, gitea, git bundle | 🚧 WIP |

Full GitOps loop (push → reconcile → deploy) inside the boundary

[Offline spectrum](../../docs/offline-spectrum.md) · [Top-level README](../../README.md)

This demo tests the missing half of offline GitOps: how a Git change crosses
the boundary after the hosted Git provider disappears. Flux reads from local
Gitea, the chart and workload image come from a local OCI registry, and a Git
bundle carries an update into Gitea while the cluster has no Internet route.
The app is [Podinfo](https://github.com/stefanprodan/podinfo), deployed using
its Helm chart and a Flux `HelmRelease`.

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

The registry and Gitea use dynamically assigned IPs on the internal Docker
network. The registry is briefly attached to Docker's default bridge during
CONNECTED staging so the host can push to its published loopback port; the
script then attaches it to the internal network and disconnects the bridge
before AIR-GAPPED begins. kind cannot reliably boot on a Docker `--internal`
network, so its node starts on kind's regular Docker bridge during CONNECTED
staging. Before the phase boundary, the script attaches the node to the
internal services network and installs `iptables` OUTPUT and FORWARD reject
rules on the bridge-facing interface. Those rules prevent host and pod
egress; the internal interface remains available to Gitea and the registry.
The internal service IPs are substituted into the generated kind
configuration and Git repository, so Flux does not rely on Docker DNS being
available to pods. kind's containerd is configured for HTTP access to the
local registry; this is deliberately an unauthenticated, disposable demo
registry.

## Tested with

Tested on **2026-10-16**, Linux amd64, Docker Engine and CLI **29.9.1**:

| Component | Pinned version |
| --- | --- |
| Flux CLI and controllers | 2.5.1 |
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

`scripts/install-tools.sh` downloads pinned amd64 Flux, kind, kubectl and Helm
binaries into the ignored `.tools/` directory and checks their reported
versions. Container images and the chart are pinned separately in
`scripts/common.sh` and `config/git-repo/`.

## Prerequisites

- Linux amd64 host with Docker Engine and Docker CLI; at least 4 CPUs, 6 GiB
  available RAM and 8 GiB free Docker storage.
- Outbound Internet during CONNECTED staging to GitHub releases, GHCR,
  Docker Hub, and `stefanprodan.github.io`.
- Bash, Git, curl, `jq`, `ssh-keygen`, `ssh-keyscan`, `od`, `sha256sum`,
  `xargs`, and `clear` (interactive terminal only).
- Ports `127.0.0.1:3000`, `127.0.0.1:2222`, `127.0.0.1:5001`, and
  `127.0.0.1:16443` unused.
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
to the internal services network, and installs egress-blocking rules before
clearing the screen for AIR-GAPPED.

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
3. Uses the prepared kind node. Its egress-blocking rules prevent outbound
   traffic over kind's regular Docker bridge; its internal interface can reach
   only Gitea and the local registry. Flux and Podinfo images are already
   present in that registry.
4. Runs `flux bootstrap git` with the private key and the local registry
   override. Flux commits its controller manifests to Gitea and configures
   the cluster to reconcile `clusters/demo`.
5. Waits for the Git source, Kustomization, Helm release and Podinfo
   Deployment. It runs a short-lived curl pod and requires external HTTPS to
   fail, then prints Flux source/Kustomization state and Podinfo readiness.

The OCI chart source uses a Flux `OCIRepository` with `insecure: true` because
the local registry is HTTP. `HelmRelease.chartRef` points at that local chart
artifact; its image points at the same registry. The selected behavior is
documented in Flux's [OCIRepository](https://fluxcd.io/flux/components/source/ocirepositories/)
and [HelmRelease](https://fluxcd.io/flux/components/helm/helmreleases/)
references. The repository manifest uses `source.toolkit.fluxcd.io/v1beta2`,
the served OCIRepository API version in the pinned Flux 2.5.1 CRDs.

### Phase 3 — AIR-GAPPED UPDATE ROUND TRIP

The update commit and its bundle were created on the connected host, then
staged before isolation. The script prints the bundle hashes, fetches the
update commit from `update.bundle`, verifies the bundle SHA-256 checksum, and
cherry-picks it onto the post-bootstrap
Gitea history, and pushes it over the internal SSH path. Cherry-picking is
needed because Flux bootstrap added its own commit to Gitea after the baseline
bundle was imported. Flux reconciles that new commit; the Deployment changes
from one to two replicas.

## Expected evidence

Versions and hashes are stable; IPs, timestamps, pod names and digests vary.
Near the end, expect output equivalent to:

```text
PASS: the Kubernetes pod cannot reach external HTTPS.
NAME          REVISION              SUSPENDED  READY  MESSAGE
flux-system   main@sha1:<revision>  False      True   stored artifact ...
NAME          REVISION              SUSPENDED  READY  MESSAGE
flux-system   main@sha1:<revision>  False      True   Applied revision ...
podinfo-...   1/1       Running
podinfo-...   1/1       Running
desired=2 ready=2
COMPLETE: Flux reconciled the Gitea update with no external network route.
Total runtime: <minutes>m <seconds>s
```

The initial evidence block shows `desired=1 ready=1`. If Flux reports
`Ready=True` but the new revision has not appeared yet, the orchestrator's
explicit `flux reconcile` and rollout waits have not completed and the run
does not claim success.

## Troubleshooting

- **Port already allocated:** stop the process using the conflicting loopback
  port or change the matching published port and API-server port before
  running. The ports are listed in Prerequisites.
- **Registry push/pull errors:** confirm Docker can access GitHub/GHCR in
  CONNECTED staging and check `docker logs offline-gitops-registry`. No
  controller or workload pull should go upstream.
- **Flux `ImagePullBackOff`:** inspect
  `kubectl -n flux-system describe pod <pod>` and confirm that all four image
  tags appear under `docker exec offline-gitops-registry ...` / the local
  registry API. `config/kind.yaml` sets containerd's registry mirror to HTTP.
- **Gitea SSH authentication:** inspect
  `docker logs offline-gitops-gitea`, `.state/home/.ssh/known_hosts`, and the
  generated public key's Gitea account registration. The private key remains
  under the ignored `.state/ssh/` directory.
- **Chart pull or HelmRelease failure:** check
  `kubectl -n podinfo get ocirepository,helmrelease` and
  `kubectl -n podinfo describe helmrelease podinfo`. The chart tag must be
  `6.15.0`, and the OCI source must use the internal registry's current IP.
- **Egress probe succeeds:** stop. The run is not a successful offline demo.
  Verify `offline-gitops-net` is marked `Internal: true` and inspect the
  `OUTPUT`/`FORWARD` rules in the kind node with
  `docker exec offline-gitops-control-plane iptables -S`.
- **Failure midway:** state and logs are intentionally retained. Inspect with
  `docker ps -a`, `docker logs`, and the pinned tools in `.tools/`; then run
  `./scripts/cleanup.sh` before retrying.

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
  firewall-blocked before AIR-GAPPED begins.
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
the pinned Gitea/registry/kind/Podinfo/probe images, Flux controller images,
and the Podinfo chart. During AIR-GAPPED phases the containers and Kubernetes
pods cannot egress to external destinations, checked with a real pod-level
HTTPS probe. The
host remains the local operator/transfer bridge and uses SSH to import the
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
