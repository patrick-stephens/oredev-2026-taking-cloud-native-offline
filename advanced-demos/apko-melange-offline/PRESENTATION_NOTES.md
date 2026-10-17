# Presentation notes: apko and melange offline

## Story

Minimal images reduce the patch surface, but the important question is whether
the image supply chain can operate after disconnect. This demo makes the
boundary visible: acquire and verify the inputs while connected, then remove
network access before building the APK, assembling the image, publishing it
to zot, and running it in k3d.

## Key beats

1. **Set the hypothesis.** `--offline` alone does not guarantee a build can
   happen without network; first identify every package and runtime artifact
   the build and cluster need.
2. **Show the connected staging boundary.** The script downloads checksum-
   verified tools, digest-pinned container images, a signed Alpine index and
   recursive APK closure, plus Alpine public keys. Call out that Alpine's
   configured endpoint is rolling.
3. **Prove the boundary before building.** In AIR-GAPPED, show the bubblewrap
   namespace has only `lo` and the direct-IP probe fails. Then show an Alpine
   container cannot reach an external IP from the Docker `--internal` network.
4. **Build the package.** melange creates and signs the greeter APK from the
   staged package repo. No network is available to the build process.
5. **Assemble and deliver the image.** apko runs with `--offline`; the image is
   loaded into the k3d node's containerd and pushed across the internal network
   to zot.
6. **Explain the runtime dependency.** Kubernetes needs its pause sandbox
   image as well as the application image. It is prefetched while connected
   and imported before scheduling, so kubelet does not try to reach Docker Hub.
7. **Close on the actual conclusion.** Both builds and the workload operate
   offline after staging. Internet is still required to acquire tool releases,
   base/runtime images, and APK inputs. The endpoint table is the key result.

## Likely questions

- **Does this mean melange always builds offline?** No. This proves the
  included recipe and staged inputs. Recipes that fetch sources or require
  undeclared external inputs will fail under the network namespace.
- **What is the unavoidable network?** The connected phase reaches release
  download endpoints, Docker Hub/GHCR image registries and blob delivery, and
  Alpine's package CDN/mirrors. Redirects and CDN hosts can vary; see the
  README dependency table.
- **Why both bubblewrap and Docker `--internal`?** bubblewrap isolates the
  host-side melange/apko process. The internal Docker network isolates zot,
  k3d, and test containers. One boundary does not protect the other.
- **Why explicitly stage the pause image?** Kubernetes creates a sandbox
  container before starting the workload. Without the image in containerd,
  kubelet attempts a remote Docker Hub pull even when the application image is
  available locally.
- **Are the APK dependencies permanently pinned?** No. Their versions are
  recorded from the signed index fetched during staging, but Alpine's
  `v3.22/main` is rolling. A permanent rebuild needs an immutable snapshot or
  preserved signed repository snapshot.
- **Is the cluster physically air-gapped?** It has no external Docker network
  egress, and network probes verify this. The host and Docker daemon remain
  connected-capable during phase transitions; AIR-GAPPED cluster containers
  can communicate only on the internal Docker network.
- **Why adjust disk-pressure eviction?** It is an optional workaround for the
  test sandbox's constrained reported capacity. It is disabled by default and
  should not be used as a production recommendation.
- **Does a tiny image mean a complete secure supply chain?** No. The demo
  reduces the runtime package set and makes acquisition visible, but it does
  not validate upstream provenance, make the rolling repository reproducible,
  or establish a full trust root for all artifacts.

## Presenter controls

Run `scripts/run-demo.sh` in a terminal. Set `DEMO_SLEEP_SECONDS=0` to skip
narration pauses, or set a larger value for a slower live walkthrough. Use
`DEMO_RELAX_DISK_EVICTION=true` only if the disposable node in the venue has
the same low reported ephemeral-storage capacity as the tested sandbox.
`scripts/cleanup.sh` removes only demo-owned runtime resources and generated
state.
