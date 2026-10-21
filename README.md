# Taking cloud-native offline

Companion demos for the talk: running cloud-native workloads in air-gapped, restricted, and on-prem environments.

## Why

This project explores how to keep cloud-native systems secure, resilient, sovereign, and portable when internet access is constrained or absent. It treats disconnected operation as a design capability, not an emergency exception. The rule of thumb is: “if it runs in a Faraday cage, it runs anywhere.” Every demo documents its external dependencies and transfer boundaries: no hidden assumptions.

## Demo index

| # | Path | Spectrum level | Demo app | Headline tooling | One-line purpose |
|---|------|----------------|----------|------------------|------------------|
| LIVE-1 | [live-demos/1-pull-through-cache-zot](live-demos/1-pull-through-cache-zot/README.md) | 1 | nginx | [zot](https://github.com/project-zot/zot), [skopeo](https://github.com/podman-container-tools/skopeo), [helm](https://github.com/helm/helm) | Keep serving images while the upstream registry is unreachable |
| LIVE-2 | [live-demos/2-offline-bundle-cosign](live-demos/2-offline-bundle-cosign/README.md) | 3–4 | postgres | [skopeo](https://github.com/podman-container-tools/skopeo), [cosign](https://github.com/sigstore/cosign), [helm](https://github.com/helm/helm), [zot](https://github.com/project-zot/zot) | Signed bundle → verify → import → deploy a stateful workload offline |
| ADV-01 | [advanced-demos/zarf-package-lifecycle](advanced-demos/zarf-package-lifecycle/README.md) | 3–4 | [podinfo](https://github.com/stefanprodan/podinfo) | [zarf](https://github.com/zarf-dev/zarf), [k3d](https://github.com/k3d-io/k3d) | One-file packages (images + charts + git) with SBOM, deployed disconnected |
| ADV-02 | [advanced-demos/spegel-p2p](advanced-demos/spegel-p2p/README.md) | 3 | redis | [spegel](https://github.com/spegel-org/spegel), [k3d](https://github.com/k3d-io/k3d), [registry:2](https://hub.docker.com/_/registry) | Nodes fetch images from each other with the central registry down |
| ADV-03 | [advanced-demos/oras-oci-referrers](advanced-demos/oras-oci-referrers/README.md) | 3 | alpine | [oras](https://github.com/oras-project/oras), [zot](https://github.com/project-zot/zot), [syft](https://github.com/anchore/syft), [cosign](https://github.com/sigstore/cosign) | OCI 1.1 artifact graph (SBOM, policy, model, signature) travels offline intact with key-based verification |
| ADV-04 | [advanced-demos/ratify-notation-policy](advanced-demos/ratify-notation-policy/README.md) | 3 | [go-httpbin](https://github.com/mccutchen/go-httpbin) | [ratify](https://github.com/notaryproject/ratify), [notation](https://github.com/notaryproject/notation) | Deploy-time signature verification with locally bundled trust roots |
| ADV-05 | [advanced-demos/offline-vuln-scan](advanced-demos/offline-vuln-scan/README.md) | 3 | node:16-alpine | [trivy](https://github.com/aquasecurity/trivy), [grype](https://github.com/anchore/grype) | Vulnerability scanning with bundled, offline vulnerability databases |
| ADV-06 | [advanced-demos/k3s-airgap](advanced-demos/k3s-airgap/README.md) | 3 | whoami | [k3s](https://github.com/k3s-io/k3s), [k0s](https://github.com/k0sproject/k0s) | Offline k3s/k0s bootstrap: never-online nodes running seeded images |
| ADV-07 | [advanced-demos/offline-gitops-flux](advanced-demos/offline-gitops-flux/README.md) | 3 | [podinfo](https://github.com/stefanprodan/podinfo) | [flux](https://github.com/fluxcd/flux2), [gitea](https://github.com/go-gitea/gitea), git bundle | Full GitOps loop (push → reconcile → deploy) inside the boundary |
| ADV-08 | [advanced-demos/dependency-mirrors](advanced-demos/dependency-mirrors/README.md) | 3 | flask + express + go + apt pkg | [pip](https://github.com/pypa/pip), [npm](https://github.com/npm/cli), go mod vendor, apt, [Verdaccio](https://verdaccio.org/) | Zero-network builds for language and OS dependencies |
| ADV-09 | [advanced-demos/multi-arch-bundle](advanced-demos/multi-arch-bundle/README.md) | 2–3 | busybox (+ custom arm64 build) | [skopeo](https://github.com/podman-container-tools/skopeo) --all, [buildx](https://github.com/docker/buildx), [QEMU](https://github.com/qemu/qemu) | Architecture-portable bundles (amd64 + arm64) |
| ADV-10 | [advanced-demos/apko-melange-offline](advanced-demos/apko-melange-offline/README.md) | 2–3 | tiny static Go server | [apko](https://github.com/chainguard-dev/apko), [melange](https://github.com/chainguard-dev/melange) | Minimal images built from local APK packages |
| ADV-11 | [advanced-demos/harbor-dragonfly-preheat](advanced-demos/harbor-dragonfly-preheat/README.md) | 1–2 | jenkins | [harbor](https://github.com/goharbor/harbor), [dragonfly](https://github.com/dragonflyoss/dragonfly) | Enterprise registry hub + P2P preheat for large fleets |
| ADV-12 | [advanced-demos/kubean-lifecycle](advanced-demos/kubean-lifecycle/README.md) | 3–4 | httpd | [kubean](https://github.com/kubean-io/kubean) ([Kubespray](https://github.com/kubernetes-sigs/kubespray)), VMs | Offline cluster install and upgrade from an offline bundle |

## Where to start

Follow the recommended path: LIVE-1 → LIVE-2 → ADV-05 → ADV-01 → then any.

## Requirements

- Docker-capable Linux host
- Approximately 15 GB free disk space
- Each demo README lists its own additional tools and pinned versions

To pre-cache the host tools, container images and downloads for every demo,
run `./scripts/provision-host.sh` (it can be re-run safely). Use
`--only adv-01,adv-02` or `--skip adv-12` to limit the scope, and `--list` to
see demo IDs. `adv-12` (Kubean) alone needs about 60–80 GB.

The provisioner only makes changes on **Ubuntu x86_64**. On another OS, use
`./scripts/provision-host.sh --dry-run` (requires Bash 4.3 or newer) to print
the required commands, their Ubuntu package equivalents, the packages missing
from your current PATH, and the planned per-demo actions. This mode does not
install packages, download files, invoke Docker, or run demo scripts; it can be
combined with `--only`, `--skip`, and `--no-system-packages`. Use the output to
adapt provisioning for your OS. It is a plan, not a compatibility check:
downloaded binaries and demo images still target Linux amd64.

## Cleanup

Provisioning caches are stored in the individual demo directories; there is no
single `artifacts/` directory to remove. After stopping a demo, use its
`scripts/cleanup.sh` if available to remove demo resources (some cleanup
scripts require confirmation, such as Kubean's `--yes`). Check that script's
usage first.

To remove the provisioned files, inspect and delete the relevant demo-local
`artifacts/`, `.tools/`, and `.state/` directories. **Review `.state/` before
removing it:** it can contain VM disks, credentials, or evidence as well as
downloaded caches. Do not remove these directories while a demo is running or
before its cleanup script has removed its resources.

Container images remain in the shared Docker image store, and the provisioner
does not keep an inventory of which images it added. Remove only images you
have identified as belonging to these demos; avoid broad commands such as
`docker system prune -a`, which can delete unrelated images and build cache.
Helm, kind, kubectl, and any packages installed on the host are also left in
place; the provisioner does not track whether they were already installed.

## Self-contained demos

Demos are self-contained — every demo duplicates its own helper scripts so it can be used independently.

## Ask an agent about the demos

The repository includes a [demo-guide skill](.github/skills/demo-guide/SKILL.md)
for agents that support Agent Skills. Ask about a demo, its tools, architecture,
or offline requirements, or invoke `/demo-guide` in clients that support skill
slash commands. For example:

- "Which demo should I start with?"
- "How does LIVE-2 verify its offline bundle?"
- "What does Spegel do in the P2P demo?"
- "Which parts of the Flux demo still need network access?"

The skill guides answers back to the demo documentation and source without
running demos or changing your environment.
