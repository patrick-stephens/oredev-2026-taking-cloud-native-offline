# Kubean cluster lifecycle from localrelease

| Spectrum level | Verification app | Target | Status |
|---|---|---|---|
| 4 | Official Apache httpd | Two KVM/libvirt Ubuntu VMs | Install and upgrade exercised locally |

[Offline spectrum](../../docs/offline-spectrum.md) · [Repository README](../../README.md)

An offline fleet needs more than cached application images: the node OS packages,
container runtime, CNI, Kubernetes binaries, and upgrade inputs must all cross the
boundary together. This demo installs Kubernetes 1.34.7 using Kubean v0.34.2's
release-published localrelease, verifies httpd, and upgrades the control plane
and one worker to Kubernetes 1.35.5 from Kubean v0.39.2's localrelease.
The target nodes are VMs, not containerized substitutes for node operating systems.

## Architecture and boundary

```text
CONNECTED
  GitHub releases: Kubean v0.34.2 + v0.39.2
  Docker Hub: official httpd:2.4 + busybox:1.37.0
  Registry/Nginx/Podman toolbox images
                |
                v
  artifacts/kubean-lifecycle-bundles.tar.gz + included SHA256SUMS
  Ubuntu cloud image + pre-provisioned Kubean management cluster

AIR-GAPPED: public traffic rejected, private lab network available
  Management Kubernetes (Kubean operator + cached spray-job images)
       | SSH                            | API
       v                                v
  cp1: 192.168.56.11 <--------------> worker1: 192.168.56.12
       |      Ubuntu 22.04 / containerd / Calico      |
       +---------> 192.168.56.1:8080 Nginx <----------+
       +---------> 192.168.56.1:5000 registry <-------+
                             |
                httpd NodePort :30080
```

The target VMs retain an IPv4 default route: Linux needs an initial route before
locally originated Service traffic can undergo DNAT. Disconnecting their NAT
NICs and removing that route broke Service/NodePort connectivity in testing.
Instead, a guest-local systemd service installs IPv4/IPv6 OUTPUT and FORWARD
filters before network startup. Only loopback, IPv4 DHCP, the lab subnet
`192.168.56.0/24`, and the target Kubernetes range `10.233.0.0/16` are allowed.
Other private ranges, including the NAT gateway's DNS proxy, are not allowlisted.
IPv6 egress is denied except loopback; this is an IPv4-only lab.

The manager uses a separate enforced NetworkPolicy. The orchestrator derives
its private API endpoint `/32`s from EndpointSlices, accounting for Service DNAT.
The policy otherwise assumes K3d pod/service CIDRs `10.42.0.0/16` and
`10.43.0.0/16`. Adapt and retest it for a different manager.

## Tested with

Test date: **2026-10-17**. See validation status below for the distinction
between the exercised lifecycle and a fresh rerun of the hardened orchestrator.

| Component | Exact tested version |
|---|---|
| Host | Ubuntu 24.04-based Linux amd64 |
| Docker Engine / Compose | 29.9.1 / v5.6.0 |
| QEMU / libvirt / virt-install | 8.2.2 / 10.0.0 / 4.1.0 |
| Ubuntu guests | 22.04.5 LTS, kernel 5.15.0-198-generic |
| Ubuntu cloud image | Jammy `20261004`; SHA-256 `012d81fade7e8ff4428fc35dfeee711d66d1f47d5ea9c5c8ced96a85b959835c` |
| Manager | K3d v5.9.0, K3s v1.35.5+k3s1, Calico v3.31.5 |
| Kubean operator/chart | v0.39.2 |
| Base localrelease | v0.34.2, Kubernetes 1.34.7, containerd 2.2.3 |
| Base Kubespray commit | `a254f5ea687dcfaf1ce8485742363a924aa9eb60` |
| Upgrade localrelease | v0.39.2, Kubernetes 1.35.5, containerd 2.3.5 |
| Upgrade Kubespray commit | `d5190f60715730ce91110334adf3d5596f4f5431` |
| Spray-job Ansible / Jinja | ansible-core 2.16.19 / Jinja 3.1.6 |
| Importer | Podman 4.4.4, bundled static Skopeo 1.16.1 |
| Artifact services | registry:2.8.3, nginx:1.27.5-alpine |
| Probe image | docker.io/library/busybox:1.37.0 |
| App | docker.io/library/httpd:2.4; resolved digest recorded in bundle |

The tested httpd reference resolved to
`sha256:c842ac797bd1fe8b3cd26d002ac9d948aa2814097544600600b35aef42e6785a`.
Preparation deliberately resolves the current official stable 2.4 image and
records its digest rather than silently claiming a mutable tag is immutable.

## Prerequisites and disk budget

- Linux amd64, Docker/Compose, QEMU/KVM, libvirt system connection, and
  permission to use `/dev/kvm` and `qemu:///system`.
- Bash, curl, jq, flock, awk, sha256sum, tar, find, sort, xargs, virsh,
  virt-install, qemu-img, ssh, ssh-keygen, kubectl, and Helm.
- Two VM allocations of 2 vCPU, 4 GiB RAM, and 32 GiB sparse qcow2 each.
  The single control-plane/etcd node is not an HA topology.
- A **dedicated, already provisioned management cluster** with an enforcing CNI.
  The demo restricts all pods in its `kubean-system` namespace.
- Unused `192.168.56.0/24` and `10.233.0.0/16` ranges.
- Plan for **at least 60 GiB free**, preferably **80 GiB or more**, including
  Docker's storage. The earlier 20–25 GiB estimate was too small: measured
  usage was about **12 GiB artifacts + 11 GiB extraction + 18 GiB state**,
  before shared Docker image/cache storage. The transfer archive alone was
  about **6.0 GiB**, including the cached Podman toolbox.

No MinIO or host-global Podman installation is needed. The importer runs the
upstream helper inside a disposable privileged Podman container, mounting the
release's compatible static Skopeo binary. Its registry configuration changes
remain inside that container, not on the host.

## CONNECTED: prepare the manager and transfer inputs

From this demo directory, configure a distinct management kubeconfig:

```bash
export MANAGER_KUBECONFIG=/absolute/path/to/management.kubeconfig
helm repo add kubean-io https://kubean-io.github.io/kubean-helm-chart/
helm repo update kubean-io
helm upgrade --install kubean kubean-io/kubean --version v0.39.2 \
  --kubeconfig "$MANAGER_KUBECONFIG" \
  --create-namespace --namespace kubean-system
```

Preload both spray-job images and BusyBox into **every manager node** before
applying the manager policy. For the tested K3d manager:

```bash
docker pull ghcr.io/kubean-io/spray-job:v0.34.2
docker pull ghcr.io/kubean-io/spray-job:v0.39.2
docker pull docker.io/library/busybox:1.37.0
k3d image import --cluster kubean-manager \
  ghcr.io/kubean-io/spray-job:v0.34.2 \
  ghcr.io/kubean-io/spray-job:v0.39.2 docker.io/library/busybox:1.37.0
```

The installed operator/admission images must also already be cached.
Use your runtime's equivalent load method for a non-K3d manager.

### Single-terminal lifecycle

```bash
./scripts/run-demo.sh
```

The orchestrator boots the VMs, explicitly restores connected egress for the
positive public probe, prepares the bundle, and then crosses the AIR-GAPPED
boundary. It never implicitly reopens egress in an offline/resume mode.
`DEMO_PAUSE_SECONDS=0` removes the short presenter pauses.

Other modes:

```bash
./scripts/run-demo.sh --prepare-only        # connected bundle assembly only
./scripts/run-demo.sh --vm-smoke            # VM connectivity/isolation only; no bundle download
./scripts/run-demo.sh --offline             # use staged/cached inputs; never download
./scripts/run-demo.sh --verify-only         # running upgraded cluster: verify, no lifecycle operation
./scripts/run-demo.sh --offline --reconcile-upgrade
```

`--offline` requires already booted VMs and a provisioned/cached manager.
For another host, transfer this directory, the pinned Ubuntu cloud image,
and the bundle; provision/boot the VMs while still connected before the boundary:

```bash
mkdir -p artifacts
tar -xzf artifacts/kubean-lifecycle-bundles.tar.gz -C artifacts
(cd artifacts && sha256sum --check SHA256SUMS)
./scripts/kvm.sh up
# Disconnect external access logically by starting the offline workflow.
./scripts/run-demo.sh --offline
```

Do not run `prepare-bundle.sh`, `kvm.sh connect-egress`, or an unprepared
`kvm.sh up` after declaring AIR-GAPPED.

### Repeat-run guarantees

- A file lock prevents simultaneous orchestrators sharing state.
- Manager preflight rejects overlapping lifecycle operations.
- Existing target versions are inspected before deciding to install. Empty
  targets install; base/mixed targets resume the upgrade; upgraded targets
  skip the base install. Unsupported versions/inventories fail explicitly.
- `--reconcile-upgrade` reruns the upgrade playbook at the current target
  version, including the network role. It is not a downgrade or a reset.
- Each operation has a generated unique name. Earlier failures and their Jobs
  are retained; a failed operation is not silently deleted/retried.
- The policy probe uses a separate namespace. Its positive baseline never
  removes the workload namespace's default-deny policy.
- `--verify-only` does not reinstall or upgrade anything, but reapplies the demo
  isolation/policies and workload manifest and creates/deletes temporary probes.
- API/SSH errors, version mismatches, unexpected HTTP bodies, image failures,
  and missing prerequisites fail the run rather than count as isolation proof.

## AIR-GAPPED: step-by-step lifecycle

The orchestrator implements the following sequence:

1. Install/enable the guest-local firewall service and probe both VMs for
   blocked public IPv4/IPv6 access. Private routing and SSH remain available.
2. Verify the transfer SHA256SUMS, load saved service/toolbox images with no
   pull, start local Compose services, and wait for HTTP readiness.
3. Run `scripts/stage-artifacts.sh`: unpack both releases, verify nested OS
   checksums, check every listed static URL, and publish versioned Ubuntu
   package repositories under `/kubean/ubuntu/<release>/`.
4. Run `scripts/import-images.sh`: import both releases plus httpd/BusyBox
   into `192.168.56.1:5000`. Check the upstream helper's failure list and all
   registry manifests; the helper's exit status alone is not sufficient.
5. Apply/verify manager policy. A cached BusyBox probe must reach local SSH,
   registry, and file services but fail public HTTP.
6. For an empty target, run `configure-guest-apt.sh v0.34.2`, register the
   LocalArtifactSet, inventory, SSH Secret, Vars, and Cluster; launch the
   install ClusterOperation and wait for **Succeeded**.
7. Obtain the target kubeconfig privately from Kubean's post-hook ConfigMap
   (or recover the existing admin config over private SSH). Check exactly two
   Ready nodes at 1.34.7 for a new install.
8. Deploy `config/httpd.yaml`, require two available replicas and an Apache
   `It works!` body through `192.168.56.12:30080`.
9. Prove the target's egress policy with a separate probe: private local HTTP
   works before policy, public HTTP fails, and the same private HTTP fails
   after default-deny is applied. Exec/API failures are not accepted as proof.
10. Switch guest apt to v0.39.2, register its LocalArtifactSet/Vars, run the
    full upgrade operation, and require **Succeeded**.
11. Check both nodes at **v1.35.5**, httpd's two available replicas and response,
    policy enforcement, and VM isolation again.

The operator and Cluster/ClusterOperation CRs are cluster-scoped; its Secrets,
ConfigMaps, Jobs, and policies use `kubean-system`. Keep manager and target
kubeconfigs separate. Generated keys/kubeconfigs remain ignored under `.state/`.

### Calico correction: full network role, no skipped tags

The pinned v0.39.2 spray-job uses ansible-core 2.16.19 with native Jinja
rendering disabled. Its Calico task reads the immutable IPPool block size
as an integer but re-templates it as the string `"26"` before JSON encoding.
Calico rejects that payload.

`config/upgrade-operation.yaml` now has a guarded shell pre-hook that changes
only that task's final JSON expression: cast the existing block size to an
integer immediately before serialization. It verifies that the expected pinned
source expression occurs exactly once and fails if the source has changed.
This patches only the disposable Job filesystem, not a release archive, image,
or the live IPPool. **The network role remains enabled.**

Globally enabling `ANSIBLE_JINJA2_NATIVE=True` was tested and rejected: it also
coerces `1.35` version keys and breaks Kubespray's etcd lookup. The narrow
serialization correction avoids that broader behavior change.

Regression check, entirely offline using the cached spray-job image:

```bash
docker run --rm --network none -v "$PWD/tests:/tests:ro" \
  --entrypoint ansible-playbook ghcr.io/kubean-io/spray-job:v0.39.2 \
  -i localhost, /tests/calico-pool-types.yml
```

It asserts the original coercion is reproducible and the corrected JSON
contains integer `26`, not string `"26"`.

## Expected transcript

Abbreviated **representative expected output**, not a saved log or a claim of
a new clean-room run. Names, timings, and progress lines vary. On a fresh
target:

```text
=== PHASE 1: CONNECTED - boot VMs and prove upstream connectivity ===
Connected check: cp1 has a default route and reaches 1.1.1.1:443.
Connected check: worker1 has a default route and reaches 1.1.1.1:443.
Bundle: .../artifacts/kubean-lifecycle-bundles.tar.gz
=== PHASE 2: AIR-GAPPED - apply VM isolation before loading local artifacts ===
Manager egress: local SSH/HTTP allowed; public HTTP blocked.
=== PHASE 3: AIR-GAPPED - install only when the target is empty ===
kubean-lifecycle-install-<suffix>: Succeeded
cp1       Ready   control-plane   ...   v1.34.7
worker1   Ready   <none>          ...   v1.34.7
=== PHASE 4: AIR-GAPPED - verify official httpd and actual policy enforcement ===
httpd: 2/2 available; private NodePort returns It works!
Target egress: local HTTP reachable before policy, blocked after policy; public HTTP blocked.
=== PHASE 5: AIR-GAPPED - upgrade with the full network role enabled ===
kubean-lifecycle-upgrade-<suffix>: Succeeded
=== PHASE 6: AIR-GAPPED - verify final version, workload, and isolation ===
cp1       Ready   control-plane   ...   v1.35.5
worker1   Ready   <none>          ...   v1.35.5
httpd: 2/2 available; private NodePort returns It works!
Lifecycle verification complete: both nodes Ready at the expected version; httpd and isolation checks passed.
Demo runtime: <measured seconds> seconds (exit 0)
```

On a repeated run, expect `Existing target state: upgraded` and
`Skipping base install: target state is upgraded.` The upgrade phase is skipped
unless requested explicitly; this is **verification of existing state**, not
a second fresh install.

## Validation status and runtime

- Release checksums, static URLs, registry tags, two-node offline install,
  pre/post-upgrade httpd responses, and target/manager egress checks were
  exercised on 2026-10-17.
- The first successful upgrade used `--skip-tags=network`. The correction above
  replaced that broad bypass: a full-network reconciliation succeeded in
  **3m23s**, with `Calico | Configure calico network pool` reporting `ok`.
  Calico node images then reported **v3.31.7**.
- The hardened `--offline --reconcile-upgrade` invocation succeeded in
  **558s (9m18s)**, including checksum verification, service loading, staging,
  imports, state detection, full-network reconciliation, httpd, and policy probes.
- `--verify-only` succeeded in **130s (2m10s)**. Bundle preparation including
  the Podman toolbox succeeded in **189s (3m09s)**.
- A worker cold boot changed its boot ID, automatically activated the firewall
  service, and recovered Ready status, private HTTP, and blocked public probes.
  The initial libvirt reboot left the domain powered off; an explicit start
  was required. This was tested as cold-boot persistence, not seamless reboot.
- A new empty-disk installation of the hardened orchestrator was **not** run:
  approval to reset the cluster for another install was unavailable.
  Resume/reconciliation tests are not represented as clean-room installs.
  After validation, the demo VMs, services, generated data, and local manager
  were removed with explicit user approval.
- Earlier measured major steps: cached bundle preparation 166s, staging 118s,
  import 41s, successful install 16m02s, successful initial upgrade 3m31s.
  Their sum is **24m58s**, excluding VM boot, probes, narration pauses, failed
  attempts, and debugging. No exact total fresh-orchestrator runtime was
  captured for that earlier sequence. The script prints actual elapsed time
  for every subsequent invocation.

## Troubleshooting

- **No KVM/libvirt permission:** check `/dev/kvm` and the system libvirt ACLs;
  do not run the whole demo as root.
- **Connected probe fails on an existing VM:** `up` does not remove the demo
  firewall. Only in CONNECTED, use `kvm.sh connect-egress` then check again.
- **Service/NodePort unreachable despite Ready nodes:** retain the IPv4
  default route. Do not revert to NAT disconnection as an isolation shortcut.
- **Manager kubeconfig post-hook times out:** check private API EndpointSlice
  addresses; the policy must allow the post-DNAT endpoint, not only Service CIDR.
- **Apt tries public mirrors:** run `configure-guest-apt.sh` for the selected
  release. It disables external source files and uses a versioned flat local
  repository. Missing InRelease/Release and initial compressed-index 404s are
  expected for this trusted lab subset; final Packages.gz and apt update must work.
- **Importer reports library errors:** use the bundled static Skopeo 1.16.1,
  not the incompatible dynamically linked Skopeo 1.19.0.
- **Kubeadm health-check times out:** inspect Job/pod events first. An earlier
  15s health check completed just after its deadline. Do not bypass preflight
  or automatically retry a failed operation without understanding partial state.
- **Calico string blockSize error:** inspect the generated operation's
  entrypoint and guarded pre-hook. The workaround is pinned to the exact
  v0.39.2 task; do not expand it into unguarded source rewrites.
- **A node stays cordoned after a failed upgrade:** Kubespray preserves the
  pre-existing scheduling state on retry. Inspect history, then explicitly
  uncordon only a node known to have been cordoned by the failed demo run.
- **Public probe succeeds:** stop. Check guest firewall service/rules and
  manager CNI enforcement. A NetworkPolicy object existing is not sufficient.

## Where network is still required

Internet is needed in CONNECTED for releases, the cloud image, current httpd,
and service/toolbox/management images. Preparation uses upstream-published
localrelease archives, not a local rebuild of Kubespray. The SHA256SUMS fetched
over HTTPS are integrity checks, not detached release signatures.

AIR-GAPPED still needs local SSH, Kubernetes APIs, node-to-node traffic, and
local registry/package/file services. The host is not physically disconnected:
host-side Docker loading/importing is restricted by workflow and local URLs,
not a host-wide firewall. The manager's node-level image pulls are outside
pod NetworkPolicy, hence **all management images must be cached first**.
The local service containers have a non-masquerading published-port bridge as
well as a Docker `internal` network; neither is claimed as host-wide isolation.
The guest firewall and enforced pod policies are the demonstrated barriers.
Private trusted endpoints could relay traffic if deliberately reconfigured;
this is a reproducible lab, not a hostile-network enclave proof.

## Known limitations and future tooling

- The manager is a prerequisite; bootstrapping its OS/cluster from scratch,
  HA, rollback, backups, and production disruption budgets are not demonstrated.
- Registry/package services are unauthenticated HTTP and apt is `trusted=yes`
  on a private lab subnet. Use signing, authentication, TLS, and approval
  controls in a real enclave.
- The upgrade's pinned Calico source correction should disappear once a
  compatible upstream release is available and tested. It does not change
  the immutable IPPool size or disable network reconciliation.
- Future workflows should promote signed, policy-checked bundles with
  SBOM/provenance, immutable image references, OS compatibility checks, and
  validated rollback artifacts rather than rely on mutable tags.

### Comparison with ADV-06 and KubeKey

The [k3s air-gap demo](../k3s-airgap/) is a quicker container-based exercise in
pre-staging a Kubernetes binary and images. This Kubean demo additionally
exercises VM OS packages, SSH bootstrap, runtime/CNI dependencies, and a
control-plane/worker minor-version upgrade, at a much higher storage cost.

KubeKey is an alternative: its CLI exports an `artifact.tgz` from a manifest
and consumes it with `--with-artifact` for install/upgrade. Kubean instead
combines release-specific file/image/package archives with LocalArtifactSets
and operator-managed Cluster/ClusterOperation resources. Choose based on
whether declarative Kubernetes API-based fleet lifecycle management is useful;
the artifacts and manifests are not interchangeable.

## Cleanup

Destructive: obtain confirmation before resetting a target whose state matters.

```bash
./scripts/cleanup.sh --yes
```

This removes the demo VMs/network, local artifact services, state, working
trees, and bundles. Root-owned generated registry files are removed using the
cached Nginx image in a network-disabled container with only generated
directories mounted. Shared Docker images and the separate management cluster
are retained. Preserve required operation logs before cleanup.
The script removes the named demo Cluster, inventory, Vars, and SSH
Secret if the manager kubeconfig is available; stale target kubeconfigs must
not be reused for replacement VM disks.
If the manager itself was created just for this demo and deletion is explicitly
approved, remove it separately with `k3d cluster delete kubean-manager`, using
a K3d binary outside the state directory that cleanup removes. Never delete a
shared management cluster or unrelated namespaces.

## References

- [Kubean v0.39.2 offline deployment](https://github.com/kubean-io/kubean/blob/v0.39.2/docs/en/usage/airgap.md)
- [Kubean SSH deployment](https://github.com/kubean-io/kubean/blob/v0.39.2/docs/en/usage/sshkey_deploy_cluster.md)
- [Kubean upgrades](https://github.com/kubean-io/kubean/blob/v0.39.2/docs/en/usage/upgrade.md)
- [KubeKey offline installation](https://github.com/kubesphere/kubekey/blob/main/docs/en/installation/offline.md)
