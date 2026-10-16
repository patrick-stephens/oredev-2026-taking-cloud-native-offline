# Presentation notes: the platform has to arrive first

## Story

"Caching application images is useful only after there is a platform to run
them. What does the very first node need?"

The protagonist is a **new node that has never been online**, not an existing
cluster surviving an outage. The connected station hands over a finite,
checksummed bundle. The node imports it and the embedded controller deploys an
application without fetching a chart, an installer or an image.

Use whoami's hostname and IP output as tangible evidence that a real pod served
the request. End with the red pull failure: this is a functioning boundary,
not a broken demo.

## Before promoting this to a live demo

- Rehearse on the actual Linux Docker engine and projector terminal. Read the
  [tested versions, limits and measured timing](README.md#tested-with).
- Reserve a disposable host: privileged containers and writable cgroups are
  intentional, not a production hardening recommendation.
- Prepare with `./scripts/run-demo.sh --prepare-only`. Check the bundle is
  present, leave the default two-second narration pauses enabled, and retain
  a captured rehearsal transcript if the venue does not permit live Docker.
- Allow 2-4 minutes for narration. The measured warm end-to-end execution was
  40 seconds; first-use downloads are not included in that expectation.
- For stronger theater, transfer the directory to a host with its external
  interfaces disconnected and run `./scripts/run-demo.sh --offline`.
  The internal-network demo does not require disconnecting the presenter's
  laptop or breaking unrelated host services.
- Avoid terminal commands that print k3s kubeconfigs, node tokens or private
  keys. Logs and artifacts are ignored; do not add them to a presentation commit.

## Key beats

### 1. CONNECTED: inventory is the product

Run `./scripts/run-demo.sh` for the combined story, or show the prepared bundle
and use `--offline` when downloads have already been narrated.

Point out the **same k3s release** supplies the binary, archive and checksums.
The outer `rancher/k3s` image is also exported for the receiving Docker engine.
whoami is saved separately for the nested containerd image store.

Helm renders a tiny local chart here. There is no live chart repository and no
Helm client needed in the isolated cluster.

### 2. AIR-GAPPED: isolate before first boot

The node is created stopped on an internal bridge. The binary, tarballs and
rendered YAML are copied into their final paths **before** k3s first runs.
Do not say "we disconnect the node now": it never had an uplink.

Explain the explicit node IP: no default route is a desired property here,
but it defeats k3s's normal route-based autodetection.

### 3. AIR-GAPPED: prove useful work

Let `Ready`, image inventory, AddOn status and whoami's HTTP response land.
The app has `imagePullPolicy: Never`; a public-looking reference is just a
local containerd key when its content is already imported.

The first HTTP check uses the pod address from inside the node; the diagnostic
pod then proves ordinary Service DNS and HTTP work through cluster networking.
Local traffic is intended. "Offline" does not mean "no networking."

### 4. AIR-GAPPED: prove what cannot work

The node's external-IP and two DNS probes fail. Then a seeded diagnostic pod
outside the application's deny-egress namespace confirms local DNS/HTTP work
while external IP and external DNS fail. This tests both node and pod paths.

The final BusyBox pod genuinely requests an unseeded reference and fails with
`ErrImagePull` / `ImagePullBackOff`. Rancher's mirrored BusyBox is present;
Docker Hub's `library/busybox` reference is not. Content availability and
reference mapping are different concerns.

Pause on the pull events before moving to questions. whoami remains healthy.
Only treat the final `PASS` and exit zero as a completed rehearsal.

### 5. Close: take this one level further

"k3s gives us an official, release-matched transfer set. Talos Image Factory
pushes the inventory toward reproducible node boot assets. Neither removes
the obligation to inventory application images, upgrades, trust and time."

Optionally run the tested k0s comparison below before the Talos close.
Do not present the untested VM fallback as a tested capability.

### Optional stretch: repeat with k0s

Prepare with `./scripts/run-demo.sh --k0s --prepare-only`, then present with
`./scripts/run-demo.sh --k0s --offline`. For an all-in-one rehearsal, use
`./scripts/run-demo.sh --k0s`. The measured full warm run took 119 seconds;
allow another 3-5 minutes for narration. The final offline-only repeat took
79 seconds. The k0s bundle is about 1016 MiB and independent of the k3s bundle.

Keep the comparison focused on three differences:

1. **Worker role matters:** `controller --single` enables workloads and image
   import on the same node. A controller-only node is not this demo.
2. **Different reconciliation surfaces:** images go to `/var/lib/k0s/images`;
   Helm-rendered YAML goes to the `manifests/whoami/` stack directory. Unlike
   k3s's AddOn, this is k0s's manifest deployer. The orchestrator verifies
   `k0s` owns the Deployment's managed fields.
3. **Same offline contract, different network assumptions:** the k0s Docker
   DNS fixup expects a gateway, so we disable it. Host-networked kube-router
   also needs a route covering Service IPs before DNAT; the wrapper adds only
   the Service CIDR, never a default route. Show that local service networking
   works while external IP/DNS and the unseeded pull still fail.

whoami and the network checks are the same in both modes. k0s does not ship
our Rancher BusyBox diagnostic reference, so it is explicitly included in
the extra workload archive rather than silently fetched offline. System pods
are configured with `Never`; the deliberate unseeded Pod overrides to `Always`.
Telemetry and the update prober are disabled.

The negative-control helper is shared inside this demo directory so both
distributions must pass the same tests. No helper from another demo is needed.
Keep the [comparison and tested versions](README.md#k0s-stretch-goal-a-second-tested-offline-bootstrap)
available for detailed questions.

## Likely questions

**Is this really zero egress if the host still has Wi-Fi?**

For the node and pods under this tested internal bridge configuration, yes:
structural assertions and negative IP/DNS probes verify the boundary. It is
not a physical air gap or a hostile privileged-container sandbox. Host bridge
services, a host proxy/router, added networks or host compromise are remaining
leak paths. A disconnected receiving machine is the stronger demonstration.

**What about Docker's embedded DNS?**

An internal bridge alone is not the whole DNS story. Docker is given a
loopback-only upstream, the node resolver is deliberately local, and the
embedded resolver is explicitly probed. Pods use a separate non-loopback
placeholder upstream so CoreDNS does not forward back into itself.

**Why not just use NetworkPolicy?**

It does not stop the node's kubelet/containerd pulls. We deny application pod
egress too, but the outer internal bridge is the node-wide boundary. The
diagnostic pod is deliberately outside that policy to test the outer barrier.

**Why no offline Helm install?**

The requirement is an automatically deployed **Helm-rendered manifest**.
`helm template` avoids a remote chart and Helm-release lifecycle dependency.
k3s's AddOn controller applies the local file; it is not a Helm release.
In the k0s mode, its manifest deployer reconciles the rendered YAML instead.

**Why not `IfNotPresent` for whoami?**

`Never` makes missing local content fail immediately rather than attempting
a hidden registry fallback. System add-ons use their distribution defaults,
with content supplied by the official archive.

**Can I use ARM?**

whoami is multi-arch, but this bundle, k3s binary and archive are amd64. A port
must change and verify all architecture-specific artifacts and repeat the
negative tests. Do not merely change the workload platform.

**Where do time and certificates come from?**

The container shares the host clock. Correct it before isolation. Real
restricted sites need a trusted local time source and a plan for credential
issuance, rotation and expiry; no online NTP is used here.

**What went wrong during development?**

An internal bridge has no default route; k3s needed an explicit node address.
A loopback resolver made CoreDNS loop; its pod resolver now uses an unreachable
non-loopback placeholder. The nearly-full test host also hit default
percentage-based disk pressure. Demo-only kubelet thresholds are explicit and
documented. These are useful preparation lessons, not hidden failures.
The k0s stretch also exposed an entrypoint DNS rewrite that assumed a default
gateway and kube-router's need for a Service-IP route. Neither was fixed by
giving the node an internet connection.

**Will this survive an upgrade?**

Not automatically. Produce and review a complete new version-matched bundle,
test it against the same isolation boundary, and rehearse backup/recovery.
Offline operation is a supply-chain workflow, not a one-time image pull.

## Failure and cleanup choreography

If privileges, downloads or verification fail, say so and use the captured
rehearsal transcript. Never replace a failure with prerecorded success output
without labeling it. Preserve local evidence, not generated secrets.

After questions:

```bash
./scripts/cleanup.sh
```

This removes both demo distributions' labeled nodes and internal networks.
Use `--purge` only when the local bundle/evidence is no longer needed. The
cleanup script removes only labeled runtime resources and their anonymous
volumes, never all Docker containers/images or host firewall rules.
