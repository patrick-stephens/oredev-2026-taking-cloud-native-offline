# Step zero: install Kubernetes without the internet

| Spectrum level | Demo app | Headline tooling | Status |
|----------------|----------|------------------|--------|
| 3–4 | whoami | k3s | 🚧 WIP |

Official k3s air-gap install: never-online node running seeded images

[Offline spectrum](../../docs/offline-spectrum.md) · [Top-level README](../../README.md)

An advanced companion demo for **Taking cloud-native offline**. A fresh k3s
node boots on an internal-only Docker network, imports the official air-gap
archive plus `traefik/whoami:v1.12.0`, and auto-deploys locally Helm-rendered
manifests. The node never has an internet-connected network, even during setup.
The Docker host is the connected preparation station, not the Kubernetes node.

The **k0s stretch goal is also runnable** through the same orchestrator:
`./scripts/run-demo.sh --k0s`. See [the k0s comparison](#k0s-stretch-goal-a-second-tested-offline-bootstrap)
for its separate bundle, measured results and distribution-specific differences.

**Offline spectrum: level 3.** See the shared [offline spectrum](../../docs/offline-spectrum.md).
This demonstrates a disconnected platform bootstrap; it does not claim that
every day-two dependency is solved.

This follows the official [k3s air-gap, manually deploy images procedure](https://docs.k3s.io/installation/airgap).
There is no registry, online installer script, host Kubernetes context, remote
chart, or implicit workload pull.

## Architecture

```text
CONNECTED: Docker host / preparation station
  GitHub k3s release ---- binary + image archive + SHA256 checksums
  get.helm.sh ----------- pinned Helm + checksum
  Docker Hub ----------- rancher/k3s + traefik/whoami
             |
       artifacts/ (checksummed transfer bundle)
             |
AIR-GAPPED: docker load + docker create --pull never
  +---- Docker internal bridge: no external routing, no IPv6 --------+
  | privileged rancher/k3s node; no published ports; no proxy env   |
  |   /bin/k3s                      verified downloaded binary      |
  |   agent/images/*.tar[.zst]      automatic containerd import     |
  |   server/manifests/whoami.yaml  k3s AddOn auto-deploy controller |
  |                                                               |
  |   CoreDNS + local-path-provisioner (official seeded images)     |
  |   offline-demo: whoami Pod + ClusterIP Service + deny-egress     |
  |   default: network-proof Pod (official seeded BusyBox)          |
  |   offline-demo: unseeded Pod --> Docker Hub --> FAIL            |
  +---------------------------------------------------------------+
         ^ docker exec: API, HTTP checks, inventory and diagnostics
```

whoami is the **application**, not nginx. Version `v1.12.0` was the current
stable [upstream release](https://github.com/traefik/whoami/releases/tag/v1.12.0)
on the test date. Its multi-architecture distribution is useful for real
fleets; this demo deliberately transfers only **linux/amd64**. The additional
BusyBox diagnostic uses an image already included in the official k3s archive.

## Tested with

Test date: **2026-10-16**, native Linux amd64, kernel `7.0.0-38-generic`,
rootful Docker with cgroup v2.

| Component | Pinned / tested version |
| --- | --- |
| k3s binary and official air-gap archive | `v1.37.1+k3s1` |
| Node image | `rancher/k3s:v1.37.1-k3s1` |
| Application | `docker.io/traefik/whoami:v1.12.0` |
| Helm (downloaded, not the host installation) | `v4.3.1` |
| Docker client / Engine | `29.9.0` / `29.9.0` |
| Docker's containerd / runc | `v2.4.2` / `1.5.2` |
| Bash / curl / jq | `5.2.21` / `8.5.0` / `1.7` |
| ShellCheck (validation only) | `0.9.0` |
| Seeded diagnostic / intentionally unseeded reference | `rancher/mirrored-library-busybox:1.37.0` / `library/busybox:1.37.0` |

Observed registry digests (also recorded automatically in the bundle):

```text
rancher/k3s:    sha256:ca7f37d993d82ef0dcdcfecb2e0e2618ea541dbaffc620c8cedebe01a82acd0d
traefik/whoami: sha256:c4717a8d1f0134a7444e24f881160e033991f23027c6c5a9a3f8fd22e70d1d44
```

Downloaded tools and image references are version-pinned in
[common.sh](scripts/common.sh). System prerequisites are not installed or
upgraded by the demo. Tags are not cryptographically immutable: retain and
review the recorded digests when regenerating a bundle. Official binary/image
checksums and Helm's published checksum are checked while connected; generated
bundle checksums detect transfer corruption, not a malicious preparation host.

### Measured results

- **Complete connected-to-air-gapped rehearsal: 40 seconds**, including the
  default two-second phase pauses; downloaded artifacts and Docker images were
  warm, but the node and its containerd store were recreated from scratch.
- **Final offline-only rehearsal: 35 seconds**, including pod-level checks and
  the default pauses, again with a fresh node. First-use download time is connection-dependent; allow
  several minutes rather than promising the warm-cache timing.
- Transfer bundle: approximately **630 MiB** on the tested engine.
- Verified: one Ready node; healthy CoreDNS and local-path-provisioner;
  automatic import of eight official images and whoami; whoami Running with
  `imagePullPolicy: Never`; an actual whoami HTTP response; local service DNS
  and HTTP from a pod; failed external IP/DNS probes from node and pod; and
  `ErrImagePull` / `ImagePullBackOff` for an absent image.
- Bash syntax, ShellCheck and strict Helm chart lint passed.
- Repeated cleanup passed and removed the node, network and all four of the
  node image's anonymous volumes.

## Prerequisites

- A disposable **Linux amd64** machine/VM with rootful Docker and permission to
  run privileged containers. Budget 2 CPUs, 4 GiB RAM and at least 4 GiB free
  Docker storage. Docker Desktop, rootless Docker, nested restricted CI and
  ARM hosts are not validated.
- Bash 4+, curl, jq, GNU coreutils (`timeout`, `sha256sum`, `date`, etc.), tar,
  grep, awk and `clear`. No separately installed kubectl, Helm, zstd, Compose
  or registry is required.
- Connected preparation: access to GitHub release assets, `get.helm.sh`,
  Docker Hub authentication and layer distribution endpoints. Docker Hub
  rate limits must permit the two pulls.
- The host must support Kubernetes networking, mounts, cgroups and iptables.
  The demo uses `--privileged`, `--cgroupns=host` and a writable cgroup mount.
  **Do not run untrusted images or this demo on a production/shared-trust host.**
- Run one instance per Docker engine. Fixed container/network names are
  `taking-offline-k3s-airgap`; deletion is guarded by a demo ownership label.
  Docker chooses a free bridge subnet; pod/service CIDRs are k3s defaults
  (`10.42.0.0/16`, `10.43.0.0/16`). Avoid overlaps with host/VPN routes.

## One terminal: full rehearsal

From the repository root:

```bash
cd advanced-demos/k3s-airgap
./scripts/run-demo.sh
```

The orchestrator clears an interactive terminal between phases, prints phase
banners, and pauses for two seconds for narration. Redirected output retains
every phase. For unattended testing without pauses:

```bash
DEMO_PAUSE_SECONDS=0 ./scripts/run-demo.sh
```

Every run replaces only this demo's node, including its anonymous data volumes,
and recreates its internal network. It does not reuse a previously online node
or cached containerd state. Artifacts are reused and rechecked; connected image
tags are pulled and exported again. Failures exit nonzero and retain the node
and a local diagnostic log; there is no success-shaped fallback.

### Phase 1: CONNECTED -- collect the complete transfer set

```bash
./scripts/run-demo.sh --prepare-only
```

[prepare.sh](scripts/prepare.sh) downloads the matching `k3s` binary,
`k3s-airgap-images-amd64.tar.zst` and `sha256sum-amd64.txt` from the official
release. It checks the two official checksum entries, checks/downloads Helm,
pulls the node and whoami images for amd64, then:

- `docker save` exports the node image for the receiving Docker engine.
- A separate `docker save` exports whoami for **k3s containerd**, not for the
  host engine; these are different image stores.
- `helm template` renders the local, dependency-free chart. There is no
  `helm repo add`, dependency update or Helm release inside Kubernetes.
- Checksums and image identities are written to the ignored
  [artifacts/](artifacts/) directory.

To use a physically disconnected receiving host, transfer **this entire demo
directory including its generated artifacts**, for example via approved
removable media. The receiving host needs Docker and the listed system
utilities preinstalled. Do not transfer a running node or its credentials.

### Phases 2-4: AIR-GAPPED -- boot, deploy and prove the boundary

On the receiving host, or on the same host after preparation:

```bash
./scripts/run-demo.sh --offline
```

This path never invokes curl, an image pull, a remote Helm dependency or an
online installer. It verifies checksums, loads the node archive locally, then
creates the **stopped** container on `docker network create --internal`.
Before its first start, `docker cp` places:

```text
artifacts/k3s                              -> /bin/k3s
artifacts/k3s-airgap-images-amd64.tar.zst    -> /var/lib/rancher/k3s/agent/images/
artifacts/whoami.tar                       -> /var/lib/rancher/k3s/agent/images/
artifacts/whoami.yaml                      -> /var/lib/rancher/k3s/server/manifests/whoami.yaml
```

No `ctr images import` or manual application of the whoami Deployment is used.
k3s auto-imports both archives and its embedded AddOn controller applies the
rendered manifest. The application uses the exact imported reference with
`imagePullPolicy: Never`, preventing even a tag freshness request.

The script then verifies:

1. Exactly one node becomes Ready; CoreDNS and local-path-provisioner roll out.
2. `k3s ctr images ls -q` includes whoami and the official pause image.
3. The `whoami` AddOn exists; its Deployment rolls out; its pod returns HTTP.
4. The node has exactly one network, marked internal with IPv6 disabled, and
   has no published ports.
5. Node probes to `1.1.1.1:80`, public DNS at `1.1.1.1`, and Docker's
   `127.0.0.11` DNS cannot reach/resolve upstream.
6. A diagnostic pod **outside the deny-egress namespace** resolves the local
   Kubernetes service and reaches whoami by service DNS, but fails external
   HTTP and external DNS. This exercises the CNI path rather than relying on
   the application NetworkPolicy alone.
7. A pod using **unseeded** `docker.io/library/busybox:1.37.0` with
   `imagePullPolicy: Always` produces a genuine registry resolution/pull
   failure. The same BusyBox version exists under Rancher's *different*
   repository name: image reference identity matters.
8. The unseeded reference is still absent from containerd and whoami remains
   available. Failed probes, pull events and inventories are saved under
   [.state/](.state/), excluded from git.

### Expected output

The following is illustrative; node addresses, pod names and timings vary.
The scripts print actual command output, not these examples.

```text
=== PHASE 1: CONNECTED - acquire, verify and render ===
k3s-airgap-images-amd64.tar.zst: OK
k3s: OK
=== PHASE 2: AIR-GAPPED - verify bundle and create a node that has never been online ===
=== PHASE 3: AIR-GAPPED - wait for auto-import, node Ready and manifest auto-deploy ===
node/offline-k3s condition met
offline-k3s   Ready   control-plane   ...   v1.37.1+k3s1
docker.io/rancher/mirrored-pause:3.10.2
docker.io/traefik/whoami:v1.12.0
deployment "whoami" successfully rolled out
Hostname: whoami-...
=== PHASE 4: AIR-GAPPED - prove external IP, DNS and an unseeded image cannot work ===
Expected blocked probe: external-ip (exit 1)
PASS: local DNS and service work; pod external IP and DNS fail.
... Failed to pull image "docker.io/library/busybox:1.37.0" ...
... Error: ErrImagePull ...
PASS: Ready node, auto-imported images, auto-deployed whoami, blocked IP/DNS and failed unseeded pull.
Total runtime: ... seconds (exit 0)
```

## k0s stretch goal: a second tested offline bootstrap

Use the same entry point; k3s remains the default:

```bash
./scripts/run-demo.sh --k0s

# Or split preparation from the disconnected receiving side:
./scripts/run-demo.sh --k0s --prepare-only
./scripts/run-demo.sh --k0s --offline
```

The k0s path is independently preparable: it does **not** download k3s or need
the k3s transfer bundle. Its files are under [artifacts/k0s/](artifacts/k0s/),
and evidence is under [.state/k0s/](.state/k0s/). Transfer the whole demo
directory with that generated bundle to a disconnected receiving host, as for
k3s. Both modes share only helpers and small chart/probe manifests **inside
this demo directory**; neither imports anything from another demo.

### Tested with and measured results

Test date: **2026-10-16**, native Linux amd64, kernel `7.0.0-38-generic`,
rootful Docker with cgroup v2. Host utilities and Helm match the table above,
except Docker had been updated to **client/Engine `29.9.1`** for this rehearsal.
Docker's containerd remained `v2.4.2` and runc `1.5.2`.

| Component | Pinned / observed version |
| --- | --- |
| k0s binary and official amd64 air-gap bundle | `v1.36.4+k0s.1` |
| Node image | `docker.io/k0sproject/k0s:v1.36.4-k0s.1` |
| Nested containerd reported by the node | `2.3.5` |
| Application / rendering tool | whoami `v1.12.0` / Helm `v4.3.1` |
| Additional seeded diagnostic image | `docker.io/rancher/mirrored-library-busybox:1.37.0` |
| Intentionally unseeded image | `docker.io/library/busybox:1.37.0` |

Observed node-image digest:

```text
sha256:1105df6665d2bc0278e64258698f7f5c2fba19cbe7525dbf4457dc2c6c69f230
```

The full connected-to-offline rehearsal took **119 seconds**, with cached
downloads, a fresh node/containerd store and the default narration pauses.
The final offline-only repeat took **79 seconds**, including manifest-owner
and no-default-route assertions. First-use download
time varies; the k0s transfer bundle occupies approximately **1016 MiB**.
The original k3s offline path also passed regression testing after sharing the
negative-control helper (62 seconds while rehearsing alongside k0s).

Verified: one Ready node with no DiskPressure; healthy CoreDNS, kube-router
and kube-proxy; automatically imported platform/workload archives; a whoami
Deployment managed by `k0s`, using `Never`, with a real HTTP response;
node and pod egress failures alongside successful local service DNS/HTTP;
and a genuine unseeded `ErrImagePull` / `ImagePullBackOff`. ShellCheck and
Bash syntax and strict Helm lint passed. Repeated cleanup removed both
distributions' nodes, networks and all six associated anonymous volumes.

### CONNECTED: acquire the k0s transfer set

[prepare-k0s.sh](scripts/prepare-k0s.sh) downloads the matching release binary,
`k0s-airgap-bundle-v1.36.4+k0s.1-linux-amd64.tar` and `sha256sums.txt`.
It verifies the official checksum entries, downloads/checks Helm, exports the
node image for host Docker, and renders the **same local whoami chart**.

The official k0s bundle is used unchanged; no registry is started. Unlike the
k3s release archive, it does not include the Rancher BusyBox reference used
by our common diagnostic manifest, so preparation explicitly pulls and exports
that pinned diagnostic alongside whoami into `workloads.tar`. Both image
references are recorded in the checksummed inventory.

### AIR-GAPPED: bootstrap a controller that also runs workloads

[run-k0s.sh](scripts/run-k0s.sh) creates a new stopped privileged container on
its own internal bridge, `taking-offline-k0s-airgap`, with no ports, proxy
environment or additional network. The downloaded binary replaces
`/usr/local/bin/k0s`; the archives are copied into `/var/lib/k0s/images/`.
k0s's OCI bundle reconciler imports them on the worker side automatically.
No manual `ctr images import` is used.

The rendered whoami YAML goes into
`/var/lib/k0s/manifests/whoami/whoami.yaml`. k0s's manifest deployer reconciles
that immediate-child-directory **stack**; the script does not manually apply
the application. It checks the Deployment's managed fields for the `k0s`
manager. The deliberately named stack is k0s manifest-deployer terminology,
not a Git branch or a Helm release.

[k0s.yaml](config/k0s.yaml) selects kube-router, SQLite-backed Kine for this
single node, an explicit API address, and an offline worker profile with the
same resolver and demo-only disk thresholds as k3s. `--single` enables the
worker and permits scheduling application pods. A controller-only k0s node
is **not** sufficient: it does not run these workloads or import worker images.
System image pull policy is explicitly `Never`; the negative-test Pod still
explicitly uses `Always` to exercise a real attempted pull.

Telemetry is disabled in the config; the update prober and metrics-server are
disabled on the command line. The default standalone networking components
are seeded from the official bundle.

### Why the internal-network setup differs

The tested k0s Docker entrypoint normally applies a DNS rewrite based on the
host gateway. An internal network has no default gateway route, so that
rewrite failed during initial rehearsal. `K0S_ENTRYPOINT_DNS_FIXUP=0` keeps
our explicit loopback-only node resolver intact instead. Cgroup nesting
rewrites are disabled because this demo explicitly uses the host cgroup
namespace and writable mount; do not apply these settings blindly to rootless
or private-cgroup deployments.

Host-networked kube-router contacts the API through its ClusterIP. On a node
without a default route, this initially failed before Service DNAT could take
effect, preventing CNI address allocation. Our small
[entrypoint wrapper](scripts/k0s-entrypoint.sh) adds **only**
`10.96.0.0/12 dev eth0`, then invokes the image's original entrypoint via tini.
This is a cluster-Service route, **not an internet default route**. The
orchestrator asserts that the default IPv4 route remains absent.

k0s pod/service CIDRs are explicitly `10.244.0.0/16` and `10.96.0.0/12`;
the wrapper must match the Service CIDR. Avoid overlap with host/VPN routes.
The same internal-bridge limits, host-side leak paths and DNS assumptions
documented below apply to both modes.

### Side-by-side differences

| Concern | k3s default demo | k0s comparison |
| --- | --- | --- |
| Node command | `k3s server` | `k0s controller --single --profile offline` |
| Image auto-import | `/var/lib/rancher/k3s/agent/images/` | `/var/lib/k0s/images/`, worker-side OCI reconciler |
| Automatic deployment | flat `server/manifests/whoami.yaml`, AddOn | `manifests/whoami/whoami.yaml`, manifest stack |
| Local rendering | same dependency-free Helm chart | same dependency-free Helm chart |
| CNI / service handling | flannel with k3s defaults | kube-router and kube-proxy |
| Extra diagnostic content | Rancher BusyBox already in archive | explicitly seeded Rancher BusyBox |
| System pull policy | distribution defaults with seeded content | configured `default_pull_policy: Never` |
| Internal-network adjustment | explicit node/advertise IP and interface | explicit API/node IP, no DNS rewrite, Service-only route |

Expected final lines:

```text
PASS k0s: Ready node, auto-imported images, auto-deployed whoami, blocked IP/DNS and failed unseeded pull.
Total k0s runtime: ... seconds (exit 0)
```

Inspect locally with `docker exec taking-offline-k0s-airgap k0s kubectl get pods -A`
and `docker exec taking-offline-k0s-airgap k0s ctr images ls`. A healthy
`Ready` node alone is insufficient: the script waits for CNI, kube-proxy,
CoreDNS and whoami, then exercises the actual Service path. If kube-router
crashes or pods remain `ContainerCreating` with `no IP ranges specified`,
check its API connectivity and the Service-only route before changing images.

**Limits:** tested only as a disposable single controller-worker, with default
kube-router networking. No multi-node k0s, Calico, HA, upgrade/recovery or k0sctl
workflow was tested. The earlier VM fallback remains untested for either mode.
CONNECTED additionally needs the k0s GitHub release and node-image endpoints;
the AIR-GAPPED path introduces no public endpoint, registry or chart access.
Cleanup below removes **both** distributions' labeled nodes and networks.

References: [k0s air-gap installation](https://docs.k0sproject.io/stable/airgap-install/),
[k0s in Docker](https://docs.k0sproject.io/stable/k0s-in-docker/) and
[manifest deployer](https://docs.k0sproject.io/stable/manifests/).

## Isolation choice and remaining leak paths

The primary barrier is Docker's **internal-only bridge**, not a permissive
RFC1918 OUTPUT allowlist. No host firewall is modified. The node has no default
internet route; an explicit node IP, advertise address and `eth0` flannel
interface avoid k3s's default-route autodetection requirement.

There is also an egress-deny NetworkPolicy in the application namespace.
NetworkPolicy does **not** constrain kubelet/containerd image pulls, host
processes or host-network pods; the external bridge boundary covers those
paths in this demonstration.

DNS deserves its own boundary:

- The node's resolver points at unused loopback, not the host resolver.
- Docker is explicitly given `--dns 127.0.0.1`; its embedded DNS must not
  silently forward to a public/host upstream. A direct stub probe checks this.
- The separate kubelet resolver uses `192.0.2.1`, an unreachable TEST-NET
  placeholder. Using loopback for **CoreDNS's own** resolver causes a forwarding
  loop and CrashLoopBackOff. CoreDNS can answer cluster-local names; external
  lookups fail. There is no real DNS service at the placeholder address.
- Proxy environment variables are explicitly cleared.

**Limits:** the host still has internet. `--internal` is not a VM boundary or a
defense against a privileged malicious workload: the node can reach services
on the bridge's host interface, and a host-side proxy/router, changed firewall,
extra attached network, or a privileged escape could bypass the model.
No Docker socket is mounted and no ports are published, but the host can
intentionally access/control the node. Publishing host ports later creates
another local access path and must be reviewed separately.

The zero-internet-egress assertion applies to this node and its pods under the
tested Docker bridge configuration, not all host activity or all possible
protocols under a compromised host. Structural checks plus node/pod IP and DNS
negative controls verify this boundary; this is not a packet-capture audit of
the Docker host. For a stronger physical air gap, transfer the bundle to a
disconnected host/VM and disable its external NICs.

## Troubleshooting

| Symptom | Action |
| --- | --- |
| Container start denied, mount/cgroup/iptables errors | Use a disposable rootful Linux Docker VM. Do not remove privilege/cgroup requirements and call that a pass. Inspect the retained node log. |
| `no default routes found` | Keep the explicit node IP and flannel interface in the orchestrator. Do not attach an internet network to fix autodetection. |
| CoreDNS CrashLoopBackOff / forwarding loop | Keep the separate node and pod resolver files; do not point CoreDNS at itself. |
| Bundle checksum failure | Do not boot it. Re-transfer the damaged file; for a bad cached download, remove only that file from the bundle and rerun connected preparation. |
| `ErrImageNeverPull` on whoami | Inspect auto-import logs, exact image reference and architecture. Loading an image into host Docker alone does not seed containerd. |
| `DiskPressure` or images vanish later | Free Docker storage. This disposable demo uses 1 GiB node/image free-space eviction thresholds and 99/98% image GC thresholds because default percentage thresholds can evict pods on large, nearly-full hosts. These are not production recommendations. |
| API/rollout timeout | Check CPU/RAM, host route overlaps and logs. Timeouts are bounded and treated as failures. |
| Clock skew / certificate validity | Correct the host clock before isolation. Containers share the host clock; k3s does not supply offline NTP. Real sites need trusted local time service. |
| An external probe succeeds | Treat it as a bug: stop, retain evidence, check attached networks, DNS/proxy configuration and host routing. Do not present the result as air-gapped. |

Useful local inspection:

```bash
docker logs --tail 100 taking-offline-k3s-airgap
docker exec taking-offline-k3s-airgap k3s kubectl get pods -A
docker exec taking-offline-k3s-airgap k3s ctr images ls
docker exec taking-offline-k3s-airgap k3s kubectl -n kube-system get addons whoami
docker exec taking-offline-k3s-airgap k3s kubectl -n offline-demo describe pod unseeded
docker network inspect taking-offline-k3s-airgap
```

### Known limitations and VM alternative

- This is one disposable server, not an HA/control-plane recovery or upgrade
  demo. Traefik, ServiceLB and metrics-server are disabled; their images may
  remain in the unmodified official archive.
- There are no `.cache.json` conditional-import shortcuts. Every new node
  imports the supplied archives, independently of the host image cache.
- There is no host port mapping or exported kubeconfig. On an internal bridge,
  the node itself may lack a route to Service CIDRs; the application is checked
  by pod IP from the node and by Service DNS from the diagnostic pod.
- All download, privilege, kernel and DNS assumptions were tested only on the
  platform above. Initial rehearsals caught missing default-route selection,
  a CoreDNS loop and percentage-based disk pressure; the shipped path fixes
  these rather than ignoring failures.
- Native Docker steps are tested. The following VM fallback is **not tested**:

```bash
# UNTESTED: Vagrant/VirtualBox alternative, on a host supporting virtualization.
# CONNECTED: install VirtualBox/Vagrant and create a disposable Ubuntu amd64 VM.
mkdir k3s-airgap-vm
cd k3s-airgap-vm
vagrant init ubuntu/jammy64
vagrant up --provider=virtualbox
vagrant ssh
# UNTESTED: install rootful Docker and the prerequisite utilities inside the VM
# using their official instructions; copy this demo into the VM's local disk.
# Run scripts/run-demo.sh --prepare-only inside the VM while NAT is available.
# Shut down the VM; in VirtualBox disconnect its NAT/external adapters.
# Boot via the VirtualBox console (vagrant ssh may now be unavailable).
# UNTESTED: run scripts/run-demo.sh --offline from the copied demo.
# Keep the directory on the VM disk, not a VirtualBox shared filesystem.
```

Pin and record the chosen Vagrant box/version and VM tooling before promoting
this alternative; the fallback is a runbook, not an additional tested result.

## Cleanup

```bash
./scripts/cleanup.sh
./scripts/cleanup.sh         # safe to repeat
./scripts/cleanup.sh --purge # also remove this demo's bundle and local evidence
```

Default cleanup removes both distributions' labeled containers, their anonymous
volumes (including generated keys/tokens), and their labeled internal networks. It
keeps downloads and evidence for another rehearsal. Purge removes only this
demo's two generated directories. Host Docker image cache entries are retained;
there is deliberately no global prune, firewall rewrite or daemon restart.

No keys, certificates, tokens or kubeconfigs belong in source control.
Generated bundle/evidence paths and credential extensions are covered by the
demo's [.gitignore](.gitignore). Node credentials remain in disposable Docker
volumes until cleanup; treat local logs as potentially sensitive.

## Where network is still required

**Before isolation:** provision the host OS, Docker, kernel features and host
utilities; download the k3s release, node image, whoami image and Helm; establish
trust in publishers and carry artifacts across the boundary.

**During AIR-GAPPED:** local Docker control, Kubernetes API, CNI networking,
cluster DNS and HTTP are intentionally used. No internet, public registry,
public DNS, online Helm repository, installer endpoint or NTP is needed.
Failed external probes/pulls are deliberate negative tests, not allowed
fallback traffic.

**Afterward:** upgrades, patched images, OS packages, vulnerability databases,
trust/revocation material and renewed credentials require an explicit new
connected acquisition/transfer process or equivalent on-prem services. This
demo does not solve those operational flows.

## Future tooling

**Talos and Image Factory:** move preparation earlier, into reproducible node
boot assets. A schematic plus a Talos version identifies customized boot/ISO/
installer assets with selected official system extensions and kernel options.
Generate and retain those assets while connected, then transfer them.
The public factory is itself an online dependency; the local `imager` workflow
can build custom assets after all required inputs are prepositioned.

This is not a promise that arbitrary application images are automatically baked
into every factory image. Kubernetes/container images, extensions, installers,
upgrade paths and any registry mirror/image-cache mechanism still need an
explicit offline inventory and verification. See the official
[Talos boot assets and Image Factory guide](https://docs.siderolabs.com/talos/v1.14/platform-specific-installations/boot-assets)
and [Image Factory](https://factory.talos.dev/).

**k0s comparison (implemented and tested above):** both distributions publish
release-matched bundles. For a configuration-specific inventory, k0s also offers
`k0s airgap list-images --all` and `k0s airgap bundle-artifacts`. The runnable
comparison intentionally uses the unmodified official bundle, not an
unrehearsed custom minimal inventory. Reducing that inventory is future work.

The next useful additions are reproducible, digest-locked transfer inventories,
signed verification at the receiving boundary, local time/identity services,
and rehearsed upgrade/recovery bundles -- not a hidden internet fallback.
