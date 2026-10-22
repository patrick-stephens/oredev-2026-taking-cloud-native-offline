# Presentation notes: apko and melange offline

## Story

Minimal images reduce the runtime patch surface, but that is only half the
supply-chain question. This demo tests whether the APK build and OCI assembly
can continue after disconnect. The reveal is that the *build* can be offline,
but only after connected staging has acquired exact inputs and trust keys.

## Key beats

1. **Frame the hypothesis.** `apko --offline` is not enough by itself. The
   recipe, APK closure, trust roots, runtime images, and cluster sandbox image
   all need to be accounted for.
2. **Show CONNECTED staging.** Point to the pinned tool/image versions and the
   signed Alpine indexes, recursively fetched Go APK closure, and Alpine
   public keys. Call out the rolling `v3.22` repository.
3. **Prove AIR-GAPPED starts before the builds.** Bubblewrap reports only
   `lo`, and an external-IP probe fails. A container and the k3d node also fail
   their egress probes from Docker's `--internal` network.
4. **Build the APK.** melange compiles the standard-library Go program from
   local source and staged APKs, then signs its package with an ephemeral
   local key. The Go toolchain cannot use a proxy or download another toolchain.
5. **Assemble the minimal image.** apko runs with `--offline`, and the
   footprint file gives the measured nginx-versus-apko size difference.
6. **Trace local registry delivery.** The k3d node pushes the image to zot
   over the internal bridge. The app image is removed from node containerd
   before deployment; Kubernetes then pulls it from zot through the mirror.
7. **Surface the hidden runtime dependency.** Kubernetes also needs its pause
   image. That image is prefetched while connected and imported locally, so a
   pod sandbox does not quietly fall back to Docker Hub.
8. **Close on the honest boundary.** The build and workload need no external
   egress after staging. The host remains connected-capable, and first-time
   staging still needs the endpoints in the README table.

## Likely questions

- **Does this prove every melange recipe is offline-safe?** No. It verifies
  this recipe, whose source is local and whose dependency closure is staged.
  A recipe that fetches source or runs networked tooling should fail.
- **What network is unavoidable?** GitHub release endpoints, `dl.k8s.io`,
  Docker Hub/GHCR, and Alpine's package CDN/mirror path during CONNECTED
  staging. Blob delivery may redirect to CDN/object-storage hosts.
- **Why both bubblewrap and Docker `--internal`?** Bubblewrap isolates
  host-side melange/apko. The Docker internal bridge isolates zot and k3d.
  Neither boundary substitutes for the other.
- **Why add a default route to the k3d node?** k3s refuses to start without
  one. The route points only at the internal bridge gateway; a direct-IP
  probe verifies that Docker still blocks external egress.
- **Why not push from the host Docker CLI?** Docker treats a non-loopback
  registry address as HTTPS, and Docker does not publish ports on this
  internal network. A pre-staged Skopeo container pushes the Docker archive to
  zot over internal HTTP
  without weakening host daemon registry settings.
- **Why stage the pause image?** It is required before a workload container
  can start. Without it, kubelet attempts a remote Docker Hub pull even when
  the application image is already in zot.
- **Is the package set reproducible forever?** Not yet. The upstream Alpine
  branch is rolling; an immutable APK snapshot and replayable source bundle
  are needed for that stronger guarantee.
- **Is the cluster physically air-gapped?** No. Demo containers have no
  external egress, but the host and Docker daemon remain capable of internet
  access between phases.
- **Why might the command relax disk eviction?** This test sandbox reported
  disk pressure. The opt-in 0.1% threshold is restricted to a disposable
  cluster; do not use it as a production setting.
- **Does the smaller image prove the service is more secure?** It reduces the
  runtime package footprint, but does not establish upstream provenance,
  vulnerability status, or a complete trust chain.

## Presenter controls

Run `scripts/run-demo.sh` from this directory. The default two-second pause
between phases gives time to narrate; set `DEMO_SLEEP_SECONDS=0` to skip it.
Use `DEMO_RELAX_DISK_EVICTION=true` only if the venue sandbox has the same
disk-pressure constraint as the tested environment. Finish with
`scripts/cleanup.sh` to remove only this demo's runtime resources and state.
