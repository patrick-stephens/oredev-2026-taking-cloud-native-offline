# Building a minimal Go image offline with melange and apko

This demo tests the supply-chain boundary behind the minimal-image story:
**can melange build an APK and apko assemble an OCI image without network
access once their inputs have been staged?** It builds a static Go HTTP server,
pushes the apko image to local zot, and runs it in k3d without external egress.

| Offline spectrum | Result |
|------------------|--------|
| Level 3 of 4 | CONNECTED staging is required; the build and cluster phases run without external network access. |

Here, Level 3 means that a connected staging step acquires the required tools,
images, packages, and trust keys; subsequent build, registry, and workload
steps are isolated from external endpoints. This is not a claim that artifact
acquisition or upstream provenance is itself air-gapped.

## Network dependency analysis

This table is the central result of the demo. Endpoints are the client-facing
origins; registry and package downloads may redirect blob traffic to changing
CDN or object-storage hosts.

| Tool step | Remote endpoint(s) | Phase | What requires the endpoint |
|-----------|--------------------|-------|---------------------------|
| Install melange and apko | `github.com/chainguard-dev/*` release URLs; GitHub release asset redirects | CONNECTED | Checksum-pinned release archives, downloaded only when the local binary is absent. |
| Install k3d | `github.com/k3d-io/k3d/releases` and its release-asset redirect | CONNECTED | Checksum-pinned k3d binary, downloaded only when absent. |
| Install kubectl | `dl.k8s.io/release/v1.33.5/` and the `.sha256` URL | CONNECTED | kubectl client and checksum. |
| Pull runtime and baseline images | Docker Hub (`registry-1.docker.io` and its auth/blob delivery); GHCR (`ghcr.io` and its blob delivery) | CONNECTED | Digest-pinned Alpine, nginx baseline, zot, k3s, pause, and k3d helper images. |
| Fetch APK indexes and Go toolchain closure | `dl-cdn.alpinelinux.org/alpine/v3.22/main` and `/community`, plus any mirror/CDN redirects | CONNECTED | Signed APK indexes, the recursive `go` APK dependency closure, and Alpine public verification keys. The tested closure was 18 APKs, including `go-1.24.13-r0`. |
| Compile the Go application | None | AIR-GAPPED | The source uses only the Go standard library; `GOPROXY=off`, `GOSUMDB=off`, and `GOTOOLCHAIN=local` prevent module or toolchain retrieval. |
| `melange build` | None | AIR-GAPPED | Runs under bubblewrap `--unshare-net`, consumes staged APKs and Alpine keys, and signs the resulting APK with a local ephemeral key. |
| `apko build --offline` | None | AIR-GAPPED | Runs in the same networkless namespace and consumes only the locally signed melange repository and local keys. |
| Push and pull the app image | None outside the internal Docker bridge | AIR-GAPPED | `ctr` pushes from the k3d node to zot over `zot:5000`; kubelet pulls the image from that mirror. The app image is removed from node containerd after the push so the pod must pull it from zot. |
| k3d runtime dependency | None during this phase | AIR-GAPPED | The pause image is staged in CONNECTED and imported into node containerd. No kubelet fallback to Docker Hub is needed. |

**Conclusion:** the tested melange recipe and apko assembly are fully offline
after staging. Network is unavoidable for the preceding acquisition of tools,
container images, and the signed Alpine package inputs. A future recipe that
downloads source or invokes networked tooling would fail under this demo's
network namespace.

## Architecture

```text
CONNECTED host
  ├── checksum-pinned tools: melange, apko, kubectl, k3d
  ├── digest-pinned images: Alpine, nginx baseline, zot, k3s, pause, k3d helpers
  └── signed Alpine indexes + recursive Go APK closure + Alpine public keys
                         │ staged files and local Docker image cache
                         ▼
AIR-GAPPED
  ┌─ bubblewrap --unshare-net ───────────────────────────────────────┐
  │ local Go source + APK closure ──> melange ──> signed Go APK     │
  │ signed APK repository ──────────> apko --offline ──> OCI image  │
  └─────────────────────────────────────────────────────────────────┘
                         │ local Docker save/import
                         ▼
  Docker --internal network (no external egress)
  ┌──────────┐   OCI push/pull   ┌─────────┐    ┌───────────────┐
  │ k3d/k3s  │ ────────────────> │  zot    │ <──│ Go HTTP pod   │
  │ node     │                   │ :5000   │    │ :8080         │
  └──────────┘                   └─────────┘    └───────────────┘
```

The Docker `--internal` network has no default route. k3s expects a route at
startup, so the orchestrator adds a default route **inside the disposable k3d
node** through the internal bridge gateway. The Docker network still blocks
external egress; the script tests that both from a container with an explicit
default route and from the k3d node itself. The host reaches zot and the k3s
API only through their private bridge addresses; no registry port is published
to the host.

## Prerequisites

- Linux amd64, Docker Engine, and a working local Docker daemon.
- `bubblewrap` (`bwrap`) with unprivileged network namespaces enabled.
- Host commands: Bash, `awk`, `clear`, `curl`, `docker`, `find`, `grep`,
  `seq`, `sha256sum`, `sleep`, `tar`, and `wc`.
- Enough local disk for the pinned images, APK cache, and disposable k3d
  cluster. The tested sandbox needed the optional low-disk setting described
  below.
- Internet access during CONNECTED staging. No external network access is
  needed for AIR-GAPPED work after staging.

The Docker host and daemon remain capable of internet access; this demo does
not install host firewall rules. It isolates melange/apko and all demo
containers, and verifies that their AIR-GAPPED operations cannot reach an
external endpoint.

## Run

From this directory:

```sh
scripts/run-demo.sh
```

The single orchestrator prints `CONNECTED` and `AIR-GAPPED` banners, clears
the terminal between phases when interactive, and pauses briefly for
presenter narration. Set `DEMO_SLEEP_SECONDS=0` to skip the pauses.

On a host where kubelet reports disk pressure despite sufficient free space
for this disposable demo, use:

```sh
DEMO_SLEEP_SECONDS=0 DEMO_RELAX_DISK_EVICTION=true scripts/run-demo.sh
```

That opt-in sets the kubelet disk-pressure thresholds to 0.1% for this
temporary single-node cluster. It is a sandbox workaround, not a production
recommendation; omit it on hosts with a normal disk budget.

### Expected output

The final lines should include:

```text
Expected: external request failed even with a default route to the internal bridge.
Expected: k3d server has a default route but external egress is blocked.
deployment "offline-go-server" successfully rolled out
{"message":"hello from a static Go binary in an apko image"}
=== COMPLETE: signed Go APK -> apko image -> local zot -> offline k3d HTTP check (... seconds) ===
```

The pod's Kubernetes events should report that the image was pulled. The
orchestrator verifies the tag in zot before deployment and removes the app
image from node containerd before the pod starts, so the successful rollout
tests the local registry path rather than a preloaded app image.

## Image footprint

Measured with Docker Engine's image `.Size` field on the tested amd64 host:

| Image | Bytes | MiB |
|-------|------:|----:|
| nginx baseline, `nginx:1.27.4-alpine` | 47,903,935 | 45.68 |
| Static Go server assembled by apko | 5,706,843 | 5.44 |

The apko image is **88.09% smaller** by this metric. These are Docker-reported
unpacked image sizes, not compressed registry transfer sizes. The app build
uses `CGO_ENABLED=0`; apko's runtime package set contains the signed Go
application package rather than a general-purpose base image.

## Tested with

Tested **2026-10-17** on Linux amd64, kernel `7.0.0-38-generic`, Docker Engine
`29.9.1`:

| Component | Tested version |
|-----------|----------------|
| melange | `v0.62.1` |
| apko | `v1.4.11` |
| Go compiler APK | `go-1.24.13-r0` |
| kubectl | `v1.33.5` |
| k3d | `v5.9.0` |
| k3s cluster image | `v1.33.5-k3s1` |
| Alpine package repositories | `v3.22` (`main` and `community`); base image `3.22.2` |
| zot | `v2.1.22` |
| nginx baseline | `1.27.4-alpine` |
| pause image | `rancher/mirrored-pause:3.6` |
| k3d helper images | `k3d-tools:5.9.0`, `k3d-proxy:5.9.0` |

Container images are pinned by digest in [config/versions.env](./config/versions.env);
downloaded tool archives are SHA-256 checked in
[scripts/install-tools.sh](./scripts/install-tools.sh). The Alpine `v3.22`
repository is rolling, not a permanent snapshot; the APK versions above are
recorded from the signed index used for this test.

The successful warm-cache orchestrator run took **40 seconds**, with
`DEMO_SLEEP_SECONDS=0` and `DEMO_RELAX_DISK_EVICTION=true`. It included both
phases, local registry transfer, pod scheduling, and the HTTP response, but
not first-time image or tool downloads.

## Known limitations

- Linux amd64 only. Bubblewrap network namespaces and direct host access to
  Docker bridge IPs are relied on; Docker Desktop and remote Docker daemons
  are not covered.
- The Docker daemon and host OS are not themselves air-gapped. The proof
  covers melange/apko namespaces and containers attached to the internal
  bridge.
- The Alpine repository URL is versioned by branch, not an immutable
  snapshot. Repeating CONNECTED acquisition later may select newer APKs.
- The optional 0.1% kubelet eviction threshold is solely for a disposable
  demo cluster under disk pressure. It must not be copied to production.
- The app is a small amd64-only standard-library HTTP server, not a
  production service. This compares image footprints; it is not a benchmark
  of application behavior.

## Troubleshooting

- **`bwrap: ... Operation not permitted`**: enable unprivileged user
  namespaces or use a Linux environment that permits bubblewrap network
  isolation. Do not skip the network-namespace check.
- **APK resolution or signature failure**: keep the Alpine indexes, recursive
  package closure, architecture layout (`x86_64/APKINDEX.tar.gz`), and public
  keys from the same CONNECTED staging run.
- **`k3d` node does not start**: Docker's internal network omits a default
  route. The script mounts a startup hook that adds a route to the internal
  bridge; an external egress probe must still fail.
- **`FailedCreatePodSandBox` tries to pull `mirrored-pause:3.6`**: confirm the
  CONNECTED phase pulled the pinned pause image and that `preload_pause_image`
  imported it into the node's containerd.
- **Pod is unschedulable for `DiskPressure`**: provide adequate free disk or,
  only for this disposable cluster, rerun with
  `DEMO_RELAX_DISK_EVICTION=true`.
- **Image pull or zot readiness fails**: confirm zot is on the internal
  network, the mirror in `config/registries.yaml` points `localhost:5000` to
  `http://zot:5000`, and the local image tag was pushed before deployment.
- **A named network/container already exists**: inspect its
  `demo=apko-melange-offline` ownership label. The scripts refuse to adopt or
  remove resources that are not owned by this demo.

## Where network is still required

Network is still required for CONNECTED staging: downloading tool binaries,
container images, signed Alpine indexes and APK packages. The explicit
endpoints and purposes are in the dependency table above. The fetched inputs
must be preserved and transferred into the disconnected environment.

The AIR-GAPPED checks do not reach external endpoints: bubblewrap exposes only
loopback to melange/apko, and containers on the internal Docker network cannot
reach an external IP even after a default route is installed. Local zot, the
k3d API, and the pod communicate only over that bridge. The host itself
remains connected-capable, so this is not a claim that the entire machine or
Docker daemon was physically disconnected.

## Future tooling

The likely evolution is from hand-built allowlists to offline bundles with
locked APK snapshots, complete source archives, digest-verified OCI images,
SBOMs and provenance attestations, plus machine-readable endpoint inventories.
Reproducible builds and immutable repository snapshots would make staged
inputs easier to audit and replay. This demo keeps the acquisition boundary
visible rather than treating `--offline` as a substitute for staging.

## Cleanup

Remove the demo cluster, zot container, internal network, generated signing
key, caches, and demo artifacts:

```sh
scripts/cleanup.sh
```

Pinned tool binaries, pulled Docker images, and artifacts belonging to other
demos are left in place. The `.state/` and `artifacts/` trees are ignored by
Git; the ephemeral signing key and kubeconfig are never committed.
