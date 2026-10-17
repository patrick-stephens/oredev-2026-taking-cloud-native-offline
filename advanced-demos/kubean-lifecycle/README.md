# Kubean cluster lifecycle from localrelease

| Spectrum level | Demo app | Headline tooling | Status |
|----------------|----------|------------------|--------|
| 4 | httpd | kubean (Kubespray), VMs | ✅ tested |

Offline cluster install and upgrade from an offline bundle

[Offline spectrum](../../docs/offline-spectrum.md) · [Top-level README](../../README.md)

Kubernetes itself has a lifecycle. This demo uses Kubean's Kubespray-based
cluster operations to install a cluster on real Ubuntu VMs from Kubean's
release-published offline artifacts, then upgrade it to a newer supported
Kubernetes minor using a second localrelease. It is intentionally not a
container-in-container substitute for node operating systems.

**Offline spectrum: level 4.** See the shared
[offline spectrum](../../docs/offline-spectrum.md). The connected phase
assembles and checksums the selected Kubean localrelease files, pulls the
official Apache httpd 2.4 image, and boots two KVM/libvirt VMs. The air-gapped
phase keeps the private lab route in place but installs guest-local iptables
rules that reject non-RFC1918 egress, then verifies that public IPv4/IPv6
probes fail while the private artifact services still work. Nginx serves staged
files as static HTTP, and the OCI registry serves images on the isolated
libvirt network.

## Architecture

```text
CONNECTED (host has Internet)
  GitHub Kubean v0.34.2 release ──> localrelease (Kubernetes 1.34.7) ─┐
  GitHub Kubean v0.39.2 release ──> localrelease (Kubernetes 1.35.5) ─┤
  Docker Hub httpd:2.4 ───────────> saved image + resolved digest ─────┤
  registry + Nginx images ────────> saved service images ──────────────┘
                                  artifacts/kubean-lifecycle-bundles.tar.gz

AIR-GAPPED (no Internet from target VMs or demo pods)
                    isolated libvirt network 192.168.56.0/24
  Kubean management K8s ────────┬──── SSH ──> cp1 (Ubuntu VM)
  (operator/job images cached)  │             worker1 (Ubuntu VM)
                                ├──── HTTP ──> Nginx :8080 (OS pkgs/binaries)
                                ├──── OCI  ──> registry :5000 (K8s + httpd images)
                                └──── verify -> httpd Service :30080

  Install: localrelease v0.34.2; Kubernetes 1.34.7
  Upgrade: localrelease v0.39.2; Kubernetes 1.35.5
```

The Kubean management cluster is separate from the two-node target cluster. It
must have Kubean v0.39.2 and the matching `spray-job` images cached before
egress is restricted. The target VMs use a dedicated libvirt network for
control and artifact traffic. Their public egress is blocked inside each guest
before any install or upgrade operation, while private `192.168.56.0/24`
artifact and SSH traffic remains available.

## Tested with

Test date: **2026-10-17**.

| Component | Pin / observed version | Status |
|---|---|---|
| Host kernel / OS | Linux amd64, Ubuntu 24.04-based host | Observed |
| Docker Engine and CLI | 29.9.1 | Observed |
| Docker Compose | v5.6.0 | Observed |
| QEMU / KVM | QEMU 8.2.2; `/dev/kvm` readable/writable | Two Ubuntu VMs booted and completed install/upgrade |
| libvirt / virt-install | libvirt 10.0.0; virt-install 4.1.0; `qemu:///system` | Private-network routing and guest-local egress blocking verified |
| Ubuntu guest cloud image | Jammy cloud image dated `20261004`; SHA-256 `012d81fade7e8ff4428fc35dfeee711d66d1f47d5ea9c5c8ced96a85b959835c` | Pinned to official image checksum |
| Kubean base localrelease | v0.34.2; Kubespray commit `a254f5ea687dcfaf1ce8485742363a924aa9eb60`; Kubernetes 1.34.7 | Installed successfully on both VMs |
| Kubean upgrade localrelease/operator | v0.39.2; Kubespray commit `d5190f60715730ce91110334adf3d5596f4f5431`; Kubernetes 1.35.5 | Upgrade completed successfully to both nodes |
| Kubean Helm chart | v0.39.2 | Running in the management cluster |
| Apache httpd | `docker.io/library/httpd:2.4`; digest `sha256:c842ac797bd1fe8b3cd26d002ac9d948aa2814097544600600b35aef42e6785a` | Verified before and after upgrade through NodePort |
| Local artifact services | `registry:2.8.3`; `nginx:1.27.5-alpine` | Started and verified from manager, guests, and target pods |
| Image import tools | Podman 4.4.4; bundled static Skopeo 1.16.1 | Imported and verified all Kubean, httpd, and BusyBox images |

The Kubean release archives are the upstream, release-generated localrelease
inputs; `prepare-bundle.sh` assembles the required amd64/Ubuntu 22.04 subset,
verifies each selected release asset against that release's `sha256sum.txt`,
and creates a transport tarball with its own SHA-256 manifest. It does not
rebuild Kubespray or claim a locally compiled Kubean release. The Kubean asset
checksum file is fetched over HTTPS; it is not a detached signature.

## Prerequisites

- Linux amd64 host with Docker Engine/CLI, the Docker Compose plugin,
  QEMU/KVM, libvirt system service, and permission to use `/dev/kvm` and
  `qemu:///system`.
- `curl`, `awk`, `sha256sum`, `tar`, `find`, `sort`, `xargs`, `virsh`,
  `virt-install`, `qemu-img`, `ssh`, and `ssh-keygen`.
- A connected management Kubernetes cluster with `kubectl` and Helm. The
  management cluster is not a target node. Install Kubean v0.39.2 and preload
  the v0.34.2 and v0.39.2 `spray-job` images while connected; its API endpoint
  must remain reachable from the demo host. K3d is a suitable local manager,
  provided its NetworkPolicy implementation is enabled.
- Podman 4.4.4 and the release-bundled static Skopeo 1.16.1 for Kubean's
  upstream `import_images.sh` helper. File and OS-package artifacts are
  unpacked into the Nginx document tree instead; MinIO Client is not used by
  this demo.
- Ubuntu cloud-image download and access to GitHub Releases and Docker Hub
  during the connected phase. Plan for tens of GB of storage: the generated
  transfer archive is about **5.8 GiB**, the saved service/workload images add
  about **0.2 GiB**, and extraction/import requires additional working space.
  In this verified run the host had **271 GiB free** at start; a practical
  floor is roughly **20–25 GiB free** for the demo directory plus local image
  cache, with more headroom strongly recommended.
- Each target VM gets 2 vCPU, 4 GiB RAM, and a dynamically allocated 32 GiB
  qcow2 overlay. This is a lab layout, not HA: one control-plane/etcd node and one
  worker.

The local Nginx and registry use unauthenticated plain HTTP on a private lab
subnet. Do not reuse this setup as a production repository service.

## Run the demo

Run from this directory:

```bash
./scripts/run-demo.sh
```

This is the single-terminal orchestrator. It prints the connected phase,
assembles the localrelease bundle, starts the target VMs with KVM/libvirt,
loads the local Nginx/registry services, stages and imports the offline
artifacts, applies the Kubean install, deploys and verifies httpd, proves the
target NetworkPolicy blocks pod egress, runs the Kubean upgrade, and rechecks
the upgraded cluster and workload.

Before running it, place a working management-cluster kubeconfig at
`.state/manager.kubeconfig` or export `MANAGER_KUBECONFIG=/path/to/file`.

To exercise only the KVM guest boot and connected-to-air-gapped network
transition without downloading the multi-gigabyte Kubean bundles, run:

```bash
./scripts/run-demo.sh --vm-smoke
```

This still requires a working connected Internet path at first, then restores
guest connectivity, installs the guest-local egress filters, and proves the air
gap. It does not install Kubean or run the httpd workload.

To prepare only the transfer archive:

```bash
./scripts/run-demo.sh --prepare-only
```

The archive is `artifacts/kubean-lifecycle-bundles.tar.gz`. To move it to a
disconnected host, copy the archive and this demo directory, then unpack it
under `artifacts/` and verify the included manifest:

```bash
mkdir -p artifacts
tar -xzf artifacts/kubean-lifecycle-bundles.tar.gz -C artifacts
(cd artifacts && sha256sum --check SHA256SUMS)
```

### Connected preparation and service loading

1. `scripts/prepare-bundle.sh` downloads and verifies:
   - Kubean v0.34.2: LocalArtifactSet metadata, amd64 file/image lists and
     archives, and Ubuntu 22.04 OS packages. Its release `version.yml` pins
     Kubernetes 1.34.7.
   - Kubean v0.39.2: the same asset set, with Kubernetes 1.35.5.
   - `httpd:2.4` from the official Docker Hub image and the registry/Nginx
     service images.
2. Boot the management Kubernetes cluster and install the Kubean v0.39.2 Helm
   chart while still connected:

   ```bash
   export KUBECONFIG=/path/to/management.kubeconfig
   helm repo add kubean-io https://kubean-io.github.io/kubean-helm-chart/
   helm repo update kubean-io
   helm install kubean kubean-io/kubean --version v0.39.2 \
     --create-namespace --namespace kubean-system
   ```

   Wait until the Kubean operator pod is Ready, then pull and preload both
   `ghcr.io/kubean-io/spray-job` images (`v0.34.2`, `v0.39.2`) into every
   management-cluster node while connected. For K3d:

   ```bash
   MANAGER_CLUSTER_NAME=your-k3d-cluster-name
   docker pull ghcr.io/kubean-io/spray-job:v0.34.2
   docker pull ghcr.io/kubean-io/spray-job:v0.39.2
   k3d image import --cluster "$MANAGER_CLUSTER_NAME" \
     ghcr.io/kubean-io/spray-job:v0.34.2 \
     ghcr.io/kubean-io/spray-job:v0.39.2
   ```

   Use the equivalent image-load method for another cluster runtime. The
   operation manifests refer to these exact tags; do not rely on a pull
   during the air-gapped phase.
3. Start the two target VMs using the connected phase of `run-demo.sh`.
   `scripts/kvm.sh up` downloads and checksum-verifies the pinned Ubuntu Jammy
   cloud image, creates two qcow2 overlays, and attaches each VM to the
   libvirt NAT network and a dedicated isolated `192.168.56.0/24` network.
   Cloud-init provisions a demo SSH key; generated state is ignored by Git.
4. Load the service images from the transfer bundle and start the local file
   and registry services only after the isolated libvirt network exists:

   ```bash
   docker image load --input artifacts/artifact-services.tar
   mkdir -p .state/files/kubean
   docker compose -f config/services.compose.yaml up -d --pull never
   ```

5. Stage file and OS-package contents under Nginx's document root and use
   Kubean's upstream helper only for OCI images. The release's file and OS
   helpers upload to MinIO's S3 API and are **not compatible with Nginx**.
   Instead, unpack their payloads while preserving paths under the upstream
   `kubean` bucket:

   ```bash
   for version in v0.34.2 v0.39.2; do
     mkdir -p ".work/$version"/{files,images,os-pkgs}
     tar --strip-components=1 -xzf "artifacts/kubean/$version/files-amd64-$version.tar.gz" -C ".work/$version/files"
     tar --strip-components=1 -xzf "artifacts/kubean/$version/images-amd64-$version.tar.gz" -C ".work/$version/images"
     tar --strip-components=1 -xzf "artifacts/kubean/$version/os-pkgs-ubuntu2204-$version.tar.gz" -C ".work/$version/os-pkgs"
     (cd ".work/$version" && sha256sum --check os-pkgs/os-pkgs.sha256sum.txt)

     mkdir -p ".work/$version/files/payload" ".work/$version/os-pkgs/payload"
     tar -xzf ".work/$version/files/offline-files.tar.gz" -C ".work/$version/files/payload"
     tar -xzf ".work/$version/os-pkgs/os-pkgs-amd64.tar.gz" -C ".work/$version/os-pkgs/payload"
     if [[ -d ".work/$version/files/payload/offline-files/files.m.daocloud.io" ]]; then
       cp -a ".work/$version/files/payload/offline-files/files.m.daocloud.io/." \
         ".work/$version/files/payload/offline-files/"
     fi
     cp -a ".work/$version/files/payload/offline-files/." .state/files/kubean/
     cp -a ".work/$version/os-pkgs/payload/resources/." .state/files/kubean/
   done
   ```

   Check every listed binary URL against the staged hostname/path layout and
   fetch representative files from the private endpoint:

   ```bash
   for version in v0.34.2 v0.39.2; do
     while IFS= read -r url; do
       path="${url#https://}"
       path="${path#http://}"
       [[ -s ".state/files/kubean/$path" ]] || {
         echo "Missing staged file: $version $url" >&2
         exit 1
       }
       curl --fail --silent --show-error "http://192.168.56.1:8080/kubean/$path" -o /dev/null
     done < "artifacts/kubean/$version/files-amd64.list"
   done
   ```

   Also request a representative Ubuntu package file from the OS tree and
   confirm Kubean's configured apt repository URL resolves to that tree. The
   precise static URL/layout mapping was validated in this sandbox; do not
   continue if those checks fail in your environment.

   Import the images from each extracted images directory using the
   release-provided helper:

   ```bash
   for version in v0.34.2 v0.39.2; do
     (cd ".work/$version/images" && REGISTRY_SCHEME=http \
       REGISTRY_ADDR=192.168.56.1:5000 ./import_images.sh)
   done
   ```

   This upstream helper requires Podman 4.4.4 and Skopeo. It configures the
   connected host's Podman insecure-registry
   settings; use a dedicated demo host and restore/remove that setting after
   importing.
6. Add the Apache image to the local registry without changing Docker's global
   insecure-registry configuration:

   ```bash
   skopeo copy --dest-tls-verify=false \
     docker-archive:artifacts/httpd-offline.tar \
     docker://192.168.56.1:5000/library/httpd:2.4
   ```

7. Verify the local services are reachable from both VMs on the isolated
   network, and preload the spray-job images in the management cluster. Keep
   the management context and the target cluster's kubeconfig distinct.

### Air-gapped install and upgrade runbook

The sequence below is the same flow exercised in the verified run on
2026-10-17. `scripts/run-demo.sh` automates it end to end; keep this section as
the manual breakdown for presenter control or troubleshooting.

1. Start the two VMs, then install the guest-local egress filters before any
   cluster operation. `run-demo.sh` does this for VMs that were started in its
   connected phase. Verify independently:

   ```bash
   for node in cp1 worker1; do
     address=192.168.56.11
     [[ "$node" == worker1 ]] && address=192.168.56.12
     ssh -i .state/ssh/id_ed25519 "vagrant@$address" 'ip route show default'
     ssh -i .state/ssh/id_ed25519 "vagrant@$address" 'ip -6 route show default'
     ssh -i .state/ssh/id_ed25519 "vagrant@$address" 'timeout 5 bash -c "</dev/tcp/1.1.1.1/443"' && exit 1
     # IPv4 default route remains present for the private lab, IPv6 default route is absent,
     # and the public IPv4 probe must fail while local 192.168.56.0/24 access still works.
   done
   ```

2. Apply the v0.34.2 localartifactset to the Kubean management cluster. Then
   install the demo inventory, Vars ConfigMap, Cluster CR, and SSH Secret.
   Generate the Secret from the demo SSH key; the key file is deliberately
   not in Git:

   ```bash
   MANAGER_KUBECONFIG=/path/to/management.kubeconfig
   SSH_KEY="$PWD/.state/ssh/id_ed25519"
   kubectl --kubeconfig "$MANAGER_KUBECONFIG" -n kubean-system create secret generic \
     kubean-lifecycle-ssh --type=kubernetes.io/ssh-auth \
     --from-file=ssh-privatekey="$SSH_KEY" --dry-run=client -o yaml |
     kubectl --kubeconfig "$MANAGER_KUBECONFIG" apply -f -
   kubectl --kubeconfig "$MANAGER_KUBECONFIG" apply -f artifacts/kubean/v0.34.2/localartifactset.cr.yaml
   kubectl --kubeconfig "$MANAGER_KUBECONFIG" apply -f config/hosts.yaml
   kubectl --kubeconfig "$MANAGER_KUBECONFIG" apply -f config/vars-v1.yaml
   kubectl --kubeconfig "$MANAGER_KUBECONFIG" apply -f config/cluster.yaml
   ```

   The generated SSH key is provisioned into both guest VMs using cloud-init.
   Confirm the manager's Kubean job can reach SSH on both
   `192.168.56.11` and `.12`, Nginx on port 8080, and the local registry on
   port 5000. `config/vars-v1.yaml` points Kubespray at those local endpoints
   and selects Kubernetes 1.34.7.
   After preloading the controller and both job images, block manager pod
   egress before launching the first operation:

   ```bash
   kubectl --kubeconfig "$MANAGER_KUBECONFIG" apply -f config/manager-egress-policy.yaml
   kubectl --kubeconfig "$MANAGER_KUBECONFIG" apply -f config/install-operation.yaml
   ```

   The manager policy assumes K3d's `10.42.0.0/16` pod and
   `10.43.0.0/16` service CIDRs. If the Kubernetes API endpoint is outside
   those ranges, add its private endpoint CIDR to the policy before applying
   it. Confirm the CNI enforces NetworkPolicy.

3. Watch the Kubean operation and verify the target API through the kubeconfig
   written by Kubean's `kubeconfig.yml` post-hook (or retrieve
   `/etc/kubernetes/admin.conf` from `cp1` into ignored `.state/`). Set
   `KUBECONFIG` to the **target** cluster (not the management cluster) for the
   following checks:

   ```bash
   export KUBECONFIG=/path/to/target.kubeconfig
   kubectl get nodes -o wide
   kubectl apply -f config/httpd.yaml
   kubectl -n lifecycle-demo rollout status deploy/httpd --timeout=180s
   kubectl -n lifecycle-demo get pods -o wide
   curl --fail http://192.168.56.12:30080/
   ```

   Expected: two Ready nodes at Kubernetes v1.34.7, two Ready httpd pods, and
   Apache's default `It works!` response over the private network.

4. Prove workload pods cannot egress to the public network. The manager
   namespace policy was already applied using the management kubeconfig;
   apply the separate target-cluster policy after deploying httpd:

   ```bash
   kubectl --kubeconfig "$KUBECONFIG" apply -f config/target-egress-policy.yaml
   ```

   A NetworkPolicy object alone is not proof of enforcement. Confirm the
   management and target CNIs enforce policy; the guest-local iptables filter
   is the independent host-level egress barrier.

5. Register and run the upgrade operation. It changes the shared Kubean Vars
   ConfigMap from 1.34.7 to 1.35.5 and advertises the v0.39.2 localartifactset.
   `upgrade-cluster.yml` upgrades the control plane before its worker; with this
   one-worker topology that worker is the single node transitioned to the new
   bundle. Kubernetes requires the control-plane step first:

   ```bash
   kubectl --kubeconfig "$MANAGER_KUBECONFIG" apply \
     -f artifacts/kubean/v0.39.2/localartifactset.cr.yaml
   kubectl --kubeconfig "$MANAGER_KUBECONFIG" apply -f config/vars-v2.yaml
   kubectl --kubeconfig "$MANAGER_KUBECONFIG" apply -f config/upgrade-operation.yaml
   ```

6. Wait for the Kubean operation to complete, then verify both nodes and the
   already-running httpd workload again:

   ```bash
   kubectl get nodes -o wide
   kubectl -n lifecycle-demo rollout status deploy/httpd --timeout=180s
   kubectl -n lifecycle-demo get pods -o wide
   curl --fail http://192.168.56.12:30080/
   ```

   Expected: the control plane and worker report Kubernetes v1.35.5, the httpd
   deployment remains Ready, and the private NodePort still returns Apache's
   default page. Probe a public IP from a demo pod as a negative test; it must
   fail under the enforced egress policies. Do not report PASS if the cluster
   operation, workload, or isolation check fails.

## Comparison with ADV-06 (k3s air-gap)

The [`k3s-airgap`](../k3s-airgap/) demo demonstrates importing a pre-staged
k3s binary and images into a constrained, single-node container environment.
It is quick to repeat and isolates Docker networking well, but it does not
exercise VM operating systems, SSH bootstrap, OS package repositories, or a
Kubernetes distribution's upgrade workflow.

This Kubean demo targets full VMs and stages OS packages, static binaries,
container images, and Kubean's LocalArtifactSet metadata. It exercises a
two-node control-plane/worker inventory and a Kubean/Kubespray upgrade. It
requires much more storage and a separate Kubean management cluster. Neither
demo replaces a production environment's change control, backup, rollback,
repository signing, or hardware validation.

## KubeKey alternative

KubeKey also supports offline installs and upgrades. Its workflow centers on
creating an `artifact.tgz` from a KubeKey manifest (`kk create manifest`,
`kk artifact export`) and supplying it with `--with-artifact` to install or
upgrade commands. Kubean's workflow instead uses release-specific offline
files/images/OS package archives, a static HTTP file service, an image
registry, `LocalArtifactSet` resources, and declarative
`Cluster`/`ClusterOperation` objects managed by its operator. KubeKey can be
more direct when an operator/API lifecycle controller is not wanted; Kubean
fits teams standardizing on declarative Kubernetes cluster operations. The
artifact formats and manifests are not interchangeable.

## Where network is still required

- Internet is required in CONNECTED to fetch the pinned Kubean release
  archives, the pinned Ubuntu Jammy cloud image, the current stable httpd 2.4 image, and
  local service images.
- The operator/management cluster must be installed and its chart, controller,
  and both versioned spray-job images cached before the air-gapped run. The
  demo does not bootstrap an unprovisioned management cluster from zero.
- In AIR-GAPPED, target VMs keep their private lab route but reject public
  egress. Management Kubean jobs may reach only the target subnet, the
  management cluster's internal pod/service CIDRs, Nginx, and the local OCI
  registry. The manager host itself may retain physical Internet connectivity;
  restrict its pod egress with an enforcing NetworkPolicy and use the VM public
  probe failure as the host-level proof.
- Nodes can reach each other and the local artifact services; “air-gapped”
  here means no Internet/upstream access, not no network at all.

## Future tooling

Kubean's release localrelease archives already package OS dependencies,
binaries, images, and LocalArtifactSet metadata. The next operational step is
to automate promotion between signed, policy-checked release bundles, generate
an SBOM/provenance record for each transfer, and use immutable digest
references rather than mutable registry tags. A production workflow should
also validate rollback bundles, repository metadata/signatures, and package
compatibility against each exact node OS image before approving a fleet
upgrade.

## Troubleshooting

- **KVM/libvirt access denied:** confirm `/dev/kvm` is readable/writable and
  the account is authorized to use the libvirt system connection. Do not work
  around this by running the demo as root.
- **Libvirt network cannot start:** confirm `192.168.56.0/24` is not already
  assigned on the host or another VM network.
- **`sha256sum` mismatch:** remove only the affected file under
  `artifacts/kubean/<tag>/` and rerun `scripts/prepare-bundle.sh`; investigate
  the download before transferring it.
- **Kubean image/file not found:** confirm both the correct release archive
  sets were imported, that `localartifactset.cr.yaml` was applied, and that
  v0.34.2/v0.39.2 spray-job images are cached in the management cluster.
- **Ubuntu apt package unavailable:** check the Nginx Ubuntu 22.04 OS-package
  import, `ubuntu_repo` in the Vars ConfigMap, and the local package-service
  address before allowing any upstream fallback.
- **Image pull failure:** verify the local registry contains
  `192.168.56.1:5000/library/httpd:2.4` and the containerd mirror settings in
  the Kubean Vars ConfigMap. The nodes must use HTTP only to this private lab
  registry.
- **Public IPv4 or IPv6 probe succeeds from a target VM:** stop; the phase is
  not air-gapped. Inspect the guest-local iptables filter and the CNI's
  NetworkPolicy enforcement before continuing.
- **NetworkPolicy object exists but public access works:** the manager CNI
  may not enforce policies or the management pod/service CIDRs may be wrong.
  Keep the target VM NAT adapters disconnected regardless.

## Known limitations

- KVM VM startup, cloud-init/SSH provisioning, guest-to-guest connectivity,
  guest-local egress blocking, bundle staging/import, Kubean install, target
  policy enforcement, and Kubean upgrade were executed successfully.
- `./scripts/run-demo.sh --vm-smoke` is the repeatable, bundle-free path for
  demonstrating those checks; run `./scripts/cleanup.sh` afterward.
- The management Kubernetes cluster itself is still a prerequisite; this demo
  assumes it already exists and that Kubean v0.39.2 plus both `spray-job`
  images are present before `run-demo.sh` starts.
- The v0.39.2 upgrade required a bounded workaround: `config/upgrade-operation.yaml`
  adds `--skip-tags=network` because the bundled Kubespray/Calico reconciliation
  path rendered the existing immutable IPPool `blockSize` as a string and
  failed even though the network configuration was unchanged. The control-plane
  and worker Kubernetes upgrades still completed successfully with the existing
  healthy Calico deployment left in place.
- Bundle assembly downloads the release archives from GitHub rather than
  rebuilding Kubespray artifacts from source. Verify release provenance with
  your organization's signing and approval process before production use.
- The Nginx and registry endpoints are unauthenticated HTTP from the lab
  clients. They are bound to the libvirt bridge address and the demo
  Compose network is Docker `internal`; this is not a secure repository
  deployment pattern.
- The libvirt isolated CIDR, K3d pod/service CIDRs, OS image, and containerd mirror
  settings are deliberately fixed for a reproducible lab; adapt and re-test
  them for another virtualization provider or Kubernetes CNI.

## Cleanup

```bash
./scripts/cleanup.sh
```

Cleanup destroys only the VMs and private network created by this demo, stops
this demo's Compose services, and removes generated secrets, state, and bundle
files. It leaves shared Docker images and any external management cluster
untouched. To retain the localrelease files for another run, copy the ignored
`artifacts/` directory before cleanup.

## References

- [Kubean v0.39.2 offline usage](https://github.com/kubean-io/kubean/blob/v0.39.2/docs/en/usage/airgap.md)
- [Kubean v0.39.2 SSH cluster deployment](https://github.com/kubean-io/kubean/blob/v0.39.2/docs/en/usage/sshkey_deploy_cluster.md)
- [Kubean v0.39.2 cluster upgrade](https://github.com/kubean-io/kubean/blob/v0.39.2/docs/en/usage/upgrade.md)
- [KubeKey offline installation](https://github.com/kubesphere/kubekey/blob/main/docs/en/installation/offline.md)
- [KubeKey cluster upgrade](https://github.com/kubesphere/kubekey/blob/main/docs/en/installation/upgrade-cluster.md)
