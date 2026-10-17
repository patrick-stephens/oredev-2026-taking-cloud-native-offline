# Zarf package lifecycle: podinfo across the air gap

| Spectrum level | Demo app | Headline tooling | Status |
|----------------|----------|------------------|--------|
| 3–4 | podinfo | zarf, k3d | 🚧 WIP |

One-file packages (images + charts + git) with SBOM, deployed disconnected

[Offline spectrum](../../docs/offline-spectrum.md) · [Top-level README](../../README.md)

Zarf is an **OpenSSF project**, contributed by Defense Unicorns in **June 2024**,
not a CNCF sandbox project. This demo packages podinfo's chart, image, a file,
Git source and generated SBOM on the connected side, then initializes and deploys
to an egress-blocked k3d cluster.

**Offline spectrum: level 3.** Use the shared [offline spectrum](../../docs/offline-spectrum.md)
as the definition of levels. This demo reaches a prepared disconnected runtime;
it does not claim a fully autonomous supply chain or lifecycle.

## Architecture

```text
CONNECTED (host + fresh k3d infrastructure)
  GitHub releases ---- Zarf CLI + matching init archive
  GHCR --------------- podinfo:6.15.0
  podinfo Helm repo -- podinfo chart:6.15.0
  public Git --------- podinfo@a9b846405af7697629de8a1da335aaf639a09f34
            |
  zarf package create zarf-config.yaml  (automatic SBOM generation)
            |
  zarf-package-podinfo-offline-amd64-6.15.0.tar.zst
            |
============ explicit isolation boundary =========================
AIR-GAPPED (all CLI operations inside the k3d node)
  mangle OUTPUT + FORWARD: IPv4/IPv6 external traffic DROP
  allow only local node, loopback, pod/service and IPv6 link-local traffic
            |
  local init archive -> injector -> seed registry -> permanent registry
                                            + mutating agent + local Gitea
            |
  package deploy -> images pushed to local registry, Git pushed to local Gitea
                 -> Helm chart installed, admitted pod references rewritten
            |
  podinfo Running + HTTP response + package list + SBOM extraction
            |
  zero unexpected DROP counters, explicit node/pod negative controls
```

No repository is created, pushed or forked on GitHub or another external host.
Zarf's Git component populates a repository **only in the disposable local
Gitea inside this cluster**, using the public source cloned during CONNECTED.

## Prerequisites

- Native **Linux amd64**, local Docker engine, permission to run privileged
  k3d containers. At least 4 CPUs, 8 GiB available RAM and **8 GiB free disk**.
- Bash 4+, curl, jq, GNU coreutils (timeout, sha256sum, cmp), awk, grep and sed.
  Zarf supplies Helm; k3s supplies kubectl. No host Helm/kubectl is required.
- Initial GitHub/GHCR/Docker Hub/chart-repository access and adequate anonymous
  registry pull quota. No custom internet proxy on the node.
- One copy per engine: `zarf-lifecycle` / `k3d-zarf-lifecycle-server-0` are
  reserved for this demo. Host API exposure is loopback-only on a dynamic port.

The installer downloads verified release binaries into `.tools/`, not `/usr/bin`;
it never uses sudo or changes a remote repository. Release checksums establish
download consistency, not independent publisher identity.

## Run in one terminal

From the repository root:

```bash
cd advanced-demos/zarf-package-lifecycle
./scripts/run-demo.sh
```

Banners, clears on interactive terminals and one-second sleeps separate the
beats. The script leaves the cluster **isolated and alive** for inspection.
Errors are fatal; private detailed logs stay under `.state/`. Nothing falls
back to an online deploy.

The two phases can also be run separately:

```bash
./scripts/connected.sh
./scripts/air-gapped.sh
./scripts/cleanup.sh
```

### CONNECTED: create the immutable transport artifact

The connected script installs **Zarf v0.88.0**, the latest stable release
resolved on the test date, and **k3d v5.9.0**. These versions are then fixed for
rehearsals, not silently upgraded each run. It stages the matching init archive
and verifies its release checksum.

The package definition is [zarf-config.yaml](zarf-config.yaml). v0.88.0 defaults
to `zarf.yaml` when given a directory, so pass our requested filename explicitly:

```bash
.tools/zarf package create zarf-config.yaml --confirm \
  --output artifacts --cache .state/cache
.tools/zarf package inspect sbom \
  artifacts/zarf-package-podinfo-offline-amd64-6.15.0.tar.zst \
  --output artifacts/sbom-connected
```

**CLI change:** current Zarf uses `package inspect sbom`, not the historical
`package inspect --sbom` flag. SBOM generation is on by default; we do not use
`--skip-sbom`. The tested image inventory contains **120 packages**.
This is inventory, not vulnerability scanning or a safety certification.

The package includes the chart's values without a local-registry override,
`ghcr.io/stefanprodan/podinfo:6.15.0`, the repository at a fixed commit, and a
teaching file. The Git component is source delivery, **not** a GitOps controller.
The image tag is a fixed release tag; the package captures its resolved image
content. Rebuilding that tag is not guaranteed byte-for-byte reproducible.

k3d is provisioned before isolation. CoreDNS, storage provisioner, the **pause
image**, and the StorageClass's **BusyBox helper image** must already be cached.
A first PVC or sandbox can otherwise trigger an internet pull before Zarf's
registry/agent exists. We pre-stage and CRI-pin both helper images against
garbage collection, then restart the node while still CONNECTED
to close old containerd HTTP keepalives before the offline counter measurement.

### AIR-GAPPED: initialize from local bytes, then deploy

The isolation script runs **inside the node**, never on the host. It uses
IPv4/IPv6 **mangle-table OUTPUT and FORWARD** hooks, before kube-router's
filter-table ACCEPT rules. kube-router periodically prepends filter rules;
simply putting a rule first in the filter table was not reliable.

Allowed destinations are loopback, the node's own IP, pod CIDR `10.42.0.0/16`
and service CIDR `10.43.0.0/16`, plus IPv6 link-local/neighbor discovery.
Docker's external DNS-forwarding endpoint is explicitly blocked. No external
traffic, including established connections, gets an allowlist exception.

A numerical-IP HTTP probe first proves the node cannot reach the internet.
Counters are then reset so deliberate probes are not counted as unexpected
deployment dependencies. Init and deploy run inside that **same namespace**:

```bash
docker exec -e KUBECONFIG=/etc/rancher/k3s/k3s.yaml \
  k3d-zarf-lifecycle-server-0 /work/.tools/zarf init \
  /work/artifacts/zarf-init-amd64-v0.88.0.tar.zst --confirm \
  --components=git-server \
  --set-variables REGISTRY_PVC_SIZE=2Gi,GIT_SERVER_PVC_SIZE=2Gi,REGISTRY_HPA_ENABLE=false

docker exec -e KUBECONFIG=/etc/rancher/k3s/k3s.yaml \
  k3d-zarf-lifecycle-server-0 /work/.tools/zarf package deploy \
  /work/artifacts/zarf-package-podinfo-offline-amd64-6.15.0.tar.zst --confirm
```

The injector in this release splits registry payloads into ConfigMaps, mounts
a static injector binary in a pod using an **already-cached infrastructure
image**, and exposes a temporary seed registry. It does not fetch a registry
image from the internet or depend on an application image preloaded into the
node. The permanent registry and agent then self-host; the init archive
contains Gitea and its chart too.

### Before/after evidence: image mutation, not manual Helm overrides

Before initialization, CONNECTED creates a short-lived pod with
`imagePullPolicy: Never`, describes it, then deletes it. This preserves the
original reference **without preloading podinfo or making an application pull**.

```bash
grep -E 'Image:|Image ID:' artifacts/before-describe.txt
# Image: ghcr.io/stefanprodan/podinfo:6.15.0

grep -E 'Image:|Image ID:' artifacts/after-describe.txt
# Image:    127.0.0.1:31999/stefanprodan/podinfo:6.15.0-zarf-2985051089
# Image ID: 127.0.0.1:31999/stefanprodan/podinfo@sha256:72611294759d...
```

Inspect live using k3s' own kubectl:

```bash
docker exec k3d-zarf-lifecycle-server-0 /bin/kubectl \
  --kubeconfig /etc/rancher/k3s/k3s.yaml -n podinfo describe pod \
  -l app.kubernetes.io/name=podinfo
```

Zarf records the original image mapping and pushes it under a local name with
a collision-resistant suffix. The mutating agent's find/replace rewrites
matching **admitted pod** image references and supplies pull credentials.
The Deployment template can still show the original GHCR reference: inspecting
only the Deployment is not proof of the actual pull source.

This replaces per-chart manual registry settings with package inventory plus
admission-time mutation. It does not discover images omitted from the package,
rewrite arbitrary application strings, or bundle dependencies magically.
Compare the basic demos' explicit `--set image.registry=...` approach.

### Verification and expected output

```text
=== PHASE 1: CONNECTED - stage tools, init package and workload package ===
... generating SBOM
... writing package to disk
CONNECTED COMPLETE: both application and init archives are staged locally.
=== PHASE 2: AIR-GAPPED - block and prove node/pod egress ===
PROVED: external HTTP blocked; egress firewall covers node OUTPUT and pod FORWARD.
=== PHASE 3: AIR-GAPPED - Zarf injector bootstraps registry, agent and Git ===
INITIALIZED: registry, mutating agent and local Gitea are running.
=== PHASE 4: AIR-GAPPED - deploy the complete package ===
podinfo-...  1/1  Running  0
stefanprodan/podinfo
podinfo-offline ... 6.15.0 ... [podinfo source]
VERIFIED: pinned podinfo Git commit is present in local Gitea.
PASS: pod Running, local registry seeded, package listed, SBOM recovered offline.
PASS: no forbidden node/pod egress attempts during init, deploy or verification.
```

The script checks all of the above, an HTTP JSON response with version 6.15.0,
matching connected/offline SBOM bytes, and **zero forbidden DROP packets**
between the initial negative control and completion. A final deliberate
external request from the **running pod** must fail too. Its counters are
saved separately, not confused with the zero-attempt lifecycle evidence.

Evidence remains in ignored `artifacts/`:
`before-describe.txt`, `after-describe.txt`, `registry-catalog.txt`,
`package-list.txt`, `sbom-connected/`, `sbom-offline/`, `egress-before.txt`,
`egress-after.txt` and `egress-deliberate-pod-probe.txt`.

## Tested with

Test date: **2026-10-16**, native Linux amd64:

| Item | Exact version |
| --- | --- |
| Docker engine | 29.9.0 |
| Zarf CLI and init package | v0.88.0 |
| k3d / k3d-tools | v5.9.0 / 5.9.0 |
| k3s node image | rancher/k3s:v1.35.5-k3s1 |
| Podinfo image and chart | 6.15.0 |
| Bundled Git commit | a9b846405af7697629de8a1da335aaf639a09f34 |
| StorageClass helper | rancher/mirrored-library-busybox:1.37.0 |
| Pod sandbox | rancher/mirrored-pause:3.6 |

**Fresh final complete run: 159 seconds; idempotent repeat: 27 seconds**, with CLI/init/node artifacts pre-staged,
including connected package creation, cluster bootstrap, offline init and deploy.
Initial CLI/init downloads add connection-dependent time; the init archive is
about 392 MiB. Timings are measurements, not guarantees.

## Troubleshooting and known limitations

- **No suitable injector image/node:** check Ready status and taints. This host
  had 41 GiB free on a large filesystem but tripped percentage-based disk
  pressure. The disposable node uses a documented **2 GiB absolute eviction
  threshold**, image-GC high/low thresholds **99/98%**, and 1% inode threshold.
  These are demo-only settings, not production capacity recommendations.
  Never clear unrelated host Docker storage to make the demo work.
- The pause image `rancher/mirrored-pause:3.6` and storage helper are marked
  `io.cri-containerd.pinned=pinned` during CONNECTED so image GC cannot remove
  these irreplaceable offline bootstrap dependencies. Repeats reuse a completed
  initialization rather than running the injector again.
- **PVC Pending / helper image pull:** the BusyBox helper must be pre-staged
  CONNECTED, not fetched during AIR-GAPPED.
- **Dropped packets:** a hidden dependency is a failure. Inspect private
  init/deploy logs and firewall evidence. Do not loosen the allowlist.
  Lingering connected-bootstrap TCP FIN/RST packets also caused false lifecycle
  dependencies until the pre-isolation node restart closed those sockets.
- **Embedded `zarf tools kubectl` panic:** v0.88.0 can conflict on shorthand
  flags. This demo uses k3s' `/bin/kubectl` directly.
- **Unsigned-package warning:** base demo does not implement the optional
  signing stretch goal. The init archive is release-checksummed, but its
  keyless signature is not authenticated here. The application package is
  unsigned. Checksums/SBOMs do not replace publisher authentication.
- Secrets/certificates, caches and logs are generated only in ignored paths
  or the local cluster. Init output may contain generated credentials, so
  `.state/` is private; do not commit or publish it.
- A single-node sandbox is not a hostile-admin isolation boundary. Root/Docker
  administrators could change rules; privileged pods are trusted. Local
  Kubernetes networking is required; “offline” means no **external** egress.
- No SBOM vulnerability database or scanner is used offline. Revocation, trusted
  time, upstream signature verification and future update policies remain work.

## Cleanup

```bash
./scripts/cleanup.sh
./scripts/cleanup.sh   # safe to repeat
```

Only the recorded demo node identity is accepted. Cleanup deletes the cluster,
its registry/Gitea volumes and the firewall's network namespace. It preserves
local CLI binaries, package archives and SBOM evidence for the next run.
It never touches host firewall rules or your default kubeconfig. No keys,
certificates or secrets should be added to version control.

## Where network is still required

CONNECTED uses GitHub releases, GitHub source, the podinfo chart repository,
GHCR and Docker Hub/k3d infrastructure assets. Initial Kubernetes bootstrap
and the storage helper image are pre-provisioning, not attributed to Zarf.
AIR-GAPPED uses **only local node/pod/service networking**, Kubernetes API
port-forward tunnels, the seeded registry and Gitea. The CLI runs inside the
blocked node, not an online host. GitHub and public registries are not contacted.

## Zarf versus the hand-rolled bundle

| Concern | Basic signed bundle | This Zarf lifecycle |
| --- | --- | --- |
| Packaging | Scripts, tar, custom inventory | Declarative package: chart/image/file/Git |
| Bootstrap registry | Explicit local registry process | Injector, seed registry, self-hosted registry |
| Image routing | Chart-specific registry/digest values | Inventory + admitted-pod mutation |
| Git | Not included | Offline Git source delivered to local Gitea |
| SBOM | Not generated | Built-in Syft inventory in package |
| Signing | Explicit Cosign verify-before-import | Supported by Zarf; optional, not enabled here |
| Operational cost | Small, easy to audit | More services, storage and admission infrastructure |

## Future tooling

Expect increasingly declarative package composition and OCI distribution,
portable SBOM/provenance, policy-gated promotion and offline trust-root
management. Zarf already supports Cosign-compatible signing and offline
verification; signing packages is the natural next exercise. Keyless workflows
still need their verification material, inclusion proof and trusted-time policy
carried across the gap. The ecosystem can automate transport and reference
mutation, but not remove the need to inventory bootstrap dependencies or plan
revocation, rollback, storage and recovery.
