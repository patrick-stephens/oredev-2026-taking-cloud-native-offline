# Presentation notes: Kubean cluster lifecycle offline

## Story

An air-gapped fleet still has a cluster lifecycle: the Kubernetes distribution,
node packages, images, and upgrade inputs all need to move into the enclave
before the first node is installed. Show the lifecycle boundary, not just a
workload that happens to keep running after disconnecting a container.

This demo was exercised end to end on 2026-10-17: bundle preparation,
artifact staging, registry import, Kubean install to Kubernetes 1.34.7,
httpd verification, target default-deny egress proof, and upgrade to
Kubernetes 1.35.5.

## Key beats

1. **Make the artifact contract visible.** Show the v0.34.2 and v0.39.2
   release inputs, their verified checksums, the corresponding Kubernetes
   versions (1.34.7 and 1.35.5), and the captured digest for the official
   `httpd:2.4` image.
2. **Show why VMs matter.** The target is a real Ubuntu control-plane VM and
   worker VM. Kubean reaches them over SSH and provisions OS packages before
   deploying Kubernetes.
3. **Draw the boundary.** At the AIR-GAPPED banner, keep the private lab route
   but install guest-local iptables rules that reject non-RFC1918 egress.
   Demonstrate failed public IPv4/IPv6 TCP probes while the static Nginx file
   service, registry, and libvirt-isolated control plane remain reachable.
4. **Install from the older localrelease.** Apply the v0.34.2
   LocalArtifactSet, Cluster, and ClusterOperation. Verify both nodes report
   Kubernetes 1.34.7, then deploy the Apache workload from the local registry.
5. **Upgrade with the newer localrelease.** Apply v0.39.2 metadata and the
   upgrade ClusterOperation for Kubernetes 1.35.5. Explain why the control
   plane must move before its worker; then verify the same httpd deployment
   still responds through the private NodePort.
6. **Close on limits.** The cached operator image and local package/image
   services remain dependencies; an air gap means no upstream access, not no
   internal network.

## Live-demo pacing

- For a bundle-free KVM/network smoke, run `./scripts/run-demo.sh --vm-smoke`.
  It restores guest connectivity for the connected probe, then installs the
  guest-local egress filters and verifies the air gap. This does not run
  Kubean or the httpd checks.
- Connected download/bundle assembly: allow for the first run's large image
  and package downloads; prepare and checksum the archive before the talk if
  time is limited.
- VM boot and cluster install: budget several minutes and keep Kubean operation
  logs visible. Do not fake or skip readiness waits.
- Upgrade: budget several minutes; watch the Kubean `ClusterOperation` and
  confirm the workload before and after.
- Keep the expected-response check simple: `curl
  http://192.168.56.12:30080/` should return Apache's default page.
- Reset with `scripts/cleanup.sh` only after capturing logs or metrics needed
  for discussion.

## Likely questions

**Is the Kubean bundle really complete?**  
The selected release set contains the release's binary files, container
images, supported Ubuntu 22.04 OS packages, and LocalArtifactSet metadata.
The README uses the upstream OCI-image import helper and documents static
staging for files/packages. It also calls out the separate management-cluster
image cache. Production promotion should verify provenance and signed
metadata under local policy.

**Why does this demo use Nginx rather than MinIO?**  
Kubean's upstream file and OS-package import helpers publish into MinIO's S3
API, while this demo serves the same staged object paths from static Nginx.
That substitution avoids a MinIO runtime dependency while preserving the
upstream file paths. Image artifacts still use the local OCI registry;
LocalArtifactSet metadata tells the operator which component versions are
available.

**Why not use containers for the target?**  
The lifecycle includes a node OS, package manager/repositories, container
runtime, SSH access, and Kubernetes bootstrap/upgrade. A containerized node
doesn't prove those host-level dependencies.

**Why Kubean rather than KubeKey?**  
KubeKey exports and consumes an `artifact.tgz` through CLI install/upgrade
commands. Kubean provides operator-managed `Cluster` and `ClusterOperation`
resources and release LocalArtifactSets. Choose based on whether declarative
Kubernetes API-based lifecycle management is useful to the platform team.

**Does an upgrade update all nodes at once?**  
Kubean invokes Kubespray's `upgrade-cluster.yml`; control-plane sequencing and
worker upgrade behavior are handled by that playbook. This topology has one
worker, so the worker transition is observable. Production upgrades need
backups, workload disruption controls, a tested rollback, and review of the
exact playbook's batching semantics.

**What stays online?**  
The management cluster and demo host remain running. Target VM private routing
stays available, but guest-local iptables rules reject public egress; Kubean
jobs are restricted to the management cluster's private CIDRs and the libvirt
isolated subnet; local Nginx and registry remain available. The host itself is
not physically disconnected.

**What is the biggest caveat?**
The management Kubernetes cluster is still a prerequisite rather than something
the demo bootstraps from zero. Also, the validated upgrade path skips Kubespray's
network role because the bundled Calico reconciliation task misrenders the
existing immutable IPPool `blockSize` as a string; the cluster still upgrades
correctly because Calico is already healthy and unchanged.
