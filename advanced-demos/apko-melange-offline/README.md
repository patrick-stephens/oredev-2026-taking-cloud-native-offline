# Building minimal APK images offline with melange and apko

This demo tests the supply-chain boundary behind the minimal-image story:
**melange can build an APK and apko can assemble an OCI image without egress,
provided the signed APK closure and tools are staged first.** The resulting
image is pushed to a local zot registry and run in a k3d cluster whose Docker
network has no external egress.

| Offline spectrum | Status |
|------------------|--------|
| Level 3 for the build and cluster phases; connected staging is required | Verified on Linux/amd64 |

See the repository's [offline spectrum](../../docs/offline-spectrum.md) for
what the levels mean. This demo is not a Level 4/TEMPEST or full supply-chain
reproducibility claim.

## Network dependency analysis

The table separates the unavoidable connected staging from the offline proof.
Network endpoints are listed as the client-facing origins; registries and CDNs
may redirect blob downloads to changing backing hosts.

| Step | Client-facing remote endpoint(s) | Phase | Why / result |
|------|-----------------------------------|-------|--------------|
| Download melange, apko, k3d, kubectl | `github.com` release URLs; `dl.k8s.io` for kubectl; redirects may serve release assets from GitHub's object storage or Kubernetes' storage CDN | CONNECTED | Required once unless pinned binaries are already cached. Each downloaded binary/archive is checked against a fixed SHA-256 in `scripts/install-tools.sh`. |
| Pull Alpine, zot, k3s, and pause images | Docker Hub (`registry-1.docker.io`, Docker auth and blob/CDN endpoints); GHCR (`ghcr.io` and its blob delivery endpoints) | CONNECTED | Digest-pinned images provide the package-fetching client, local registry, cluster node, and Kubernetes' pause sandbox image. The pause image is explicitly transferred into k3s containerd; otherwise kubelet tries Docker Hub during pod startup. |
| Download Alpine APK index and package closure | `dl-cdn.alpinelinux.org/alpine/v3.22/main`, including any mirror/CDN redirects | CONNECTED | `apk update` and recursive `apk fetch` stage the signed index, APKs, and Alpine public verification keys. The closure observed on the tested run was `busybox-binsh 1.37.0-r20`, `busybox 1.37.0-r20`, and `musl 1.2.5-r12`. |
| Build and sign the demo APK | None | AIR-GAPPED | melange runs under bubblewrap's `--unshare-net` namespace. It consumes the staged Alpine repository and the local signing key. The namespace check finds only loopback and a direct-IP egress probe fails. |
| Assemble the OCI image | None | AIR-GAPPED | apko runs in the same network-isolated namespace with `--offline`, using only the staged Alpine and melange APK repositories and local keyrings. |
| Start zot and k3d; transfer images; schedule the pod | None outside the local Docker network | AIR-GAPPED | zot and all k3d containers attach only to a Docker `--internal` network. Image transfer, registry push/pull, DNS, and Kubernetes traffic stay inside it. A separate container probe confirms external egress is blocked. |

**Conclusion:** the demonstrated melange package build and apko image assembly
do not need network access once the APK repository and trust keys are staged.
The complete demo still needs network during CONNECTED staging to fetch the
pinned tools, container images, and Alpine package inputs. It also trusts that
the connected staging machine fetched the expected sources and that the APK
signatures and binary checksums are valid.

## Architecture

```text
CONNECTED host
  ├── pinned tools (melange, apko, kubectl, k3d)
  ├── Alpine APK index + recursive APK closure + Alpine public keys
  └── digest-pinned Alpine, zot, k3s, and pause images
             │ local files / Docker image cache
             ▼
AIR-GAPPED
  ┌─ bubblewrap --unshare-net ───────────────────────────────┐
  │ staged Alpine APKs ──> melange ──> signed greeter APK  │
  │                           │                              │
  │ local APK repositories ──> apko --offline ──> OCI image │
  └─────────────────────────────────────────────────────────┘
             │ image imported into k3d node containerd
             ▼
  Docker --internal network (no external egress)
  ┌──────────┐   HTTP/OCI    ┌─────────┐   image pull  ┌────────┐
  │ k3d/k3s  │ ────────────> │  zot    │ <─────────── │  pod   │
  │ node     │               │ :5000   │              │ greeter│
  └──────────┘               └─────────┘              └────────┘
```

## Prerequisites

- Linux amd64 with Docker Engine and a working Docker daemon; the Docker client
  must be able to create networks and run containers.
- `bubblewrap` (`bwrap`) with unprivileged user namespaces enabled, plus
  `awk`, `curl`, `clear`, `find`, `grep`, `sha256sum`, `tar`, and `wget`.
- Enough local disk for the pinned images, APK cache, and a disposable k3d
  cluster. The k3d server runs a container and does not need host-installed
  Kubernetes.
- Network access for CONNECTED staging. No network is needed for the AIR-GAPPED
  work after staging completes.

The script's `DEMO_RELAX_DISK_EVICTION=true` option was needed in the test
sandbox because its reported kubelet ephemeral-storage capacity was unusually
small. It relaxes the disposable node's disk-pressure eviction threshold to
1%; it is not a general production setting.

## Run

From this directory:

```sh
scripts/run-demo.sh
```

The orchestrator has two visibly separate phases and clears the terminal
between them when run interactively. Short narration pauses default to two
seconds. To shorten them for automated testing:

```sh
DEMO_SLEEP_SECONDS=0 scripts/run-demo.sh
```

For environments with the same tight kubelet disk budget as the tested
sandbox:

```sh
DEMO_SLEEP_SECONDS=0 DEMO_RELAX_DISK_EVICTION=true scripts/run-demo.sh
```

CONNECTED staging is repeatable: binaries are downloaded only if missing,
images are digest-pinned, and the package repository is rebuilt from the
configured Alpine endpoint. AIR-GAPPED steps use the staged contents. The
script fails if either direct-IP or Docker-internal-network egress unexpectedly
works.

### Expected output

The successful run ends with output equivalent to:

```text
=== PHASE 1: CONNECTED ===
...
=== PHASE 2: AIR-GAPPED ===
Network namespace interfaces: lo; direct-IP egress: blocked
Expected: external request from the Docker internal network failed.
...
pod/offline-greeter condition met
hello from an APK built and assembled with no network
Docker network apko-melange-offline: Internal=true
=== COMPLETE: signed APK -> apko image -> zot -> offline k3d pod (... seconds) ===
```

Generated package/image data and proof files are under `artifacts/`; the local
signing key, kubeconfig, and caches are under `.state/`. Those paths are
ignored by Git.

## Tested with

Tested **2026-10-17** on Linux amd64 with:

- melange `v0.62.1`
- apko `v1.4.11`
- kubectl `v1.33.5`
- k3d `v5.9.0`
- Alpine `3.22.2` (`alpine:3.22.2`, digest-pinned)
- Docker Engine `29.9.0`
- zot `v2.1.22` and k3s `v1.33.5-k3s1` (both digest-pinned)
- pause sandbox image `rancher/mirrored-pause:3.6` (digest-pinned)

The successful warm-cache end-to-end run took **22 seconds**. That is the
orchestrator's measured runtime after its pinned tool binaries and container
images were already present; it excludes the initial downloads needed on a
fresh machine. The test used `DEMO_SLEEP_SECONDS=0` and
`DEMO_RELAX_DISK_EVICTION=true`.

The Alpine `v3.22/main` repository is a rolling endpoint, not an immutable
snapshot. The package versions above describe the signed index captured in
that test, not a guarantee that a future staging run will fetch the same
versions.

## Troubleshooting

- **`bwrap: ... Operation not permitted`**: enable unprivileged user
  namespaces or run in a Linux environment that permits bubblewrap network
  namespaces. Do not silently skip the network isolation check.
- **`FailedCreatePodSandBox` tries Docker Hub for `mirrored-pause:3.6`**:
  ensure CONNECTED staging pulled the digest-pinned pause image and that
  `preload_pause_image` imported it into the k3d node's `k8s.io` containerd
  namespace. This is a cluster runtime dependency, not an APK dependency.
- **Pod is evicted for ephemeral storage**: on this disposable demonstration
  cluster only, retry with `DEMO_RELAX_DISK_EVICTION=true`. This does not solve
  actual storage exhaustion and should not be copied to production clusters.
- **Existing Docker network/container refuses reuse**: inspect its `demo`
  ownership label. The scripts deliberately refuse to adopt or delete
  resources that do not belong to this demo.
- **APK version/signature resolution fails**: the Alpine index, recursively
  fetched APK closure, architecture layout (`x86_64/APKINDEX.tar.gz`), and
  copied public keys must come from the same connected staging run.
- **K3d node fails to start on the internal network**: the entrypoint adds a
  default route through the internal network gateway. That route does not
  provide internet egress; Docker's `--internal` network remains the boundary.

## Where network is still required

Network is required before the offline boundary to download binaries, container
images, and the Alpine package index and APK closure. The exact hosts and
purposes are listed in the dependency table above. The downloaded artifacts
must then be preserved and transferred into the disconnected environment.

This is not a proof that an arbitrary melange recipe is offline-safe. A recipe
that downloads source code, invokes networked tooling, or references
unavailable build inputs will fail under the enforced namespace. The demo's
recipe writes a tiny shell program and has no source-fetch step. Nor does this
test prove the upstream build infrastructure is trustworthy or that a rolling
Alpine repository is reproducible forever.

## Future tooling

The direction is from hand-maintained endpoint allowlists toward supply-chain
tooling that can emit a complete, attestable offline bundle: locked package
versions, verified APK and OCI digests, SBOM/provenance, source archives, and
an explicit inventory of required registry/CDN endpoints. Reproducible builds
and snapshot-backed APK repositories would make the connected staging output
more stable. This demo intentionally exposes that boundary instead of
pretending `--offline` removes the need to acquire inputs.

## Cleanup

Remove the cluster, zot container, internal network, signing key, caches, and
generated artifacts owned by this demo:

```sh
scripts/cleanup.sh
```

Pinned tool binaries and downloaded Docker images remain cached. Cleanup only
removes this demo's `.state/offline-greeter/` and `artifacts/offline-greeter/`
subdirectories; unrelated generated files are left alone.
