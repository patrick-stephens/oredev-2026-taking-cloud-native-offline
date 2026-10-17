# Multi-architecture OCI bundle, verified offline

| Spectrum level | Demo app | Headline tooling | Status |
|----------------|----------|------------------|--------|
| 2–3 | BusyBox (+ custom arm64 build) | Skopeo `--multi-arch all`, Buildx, QEMU | Docker/QEMU baseline verified; k3d stretch `# UNTESTED` |

Architecture-portable bundles (amd64 + arm64)

[Offline spectrum](../../docs/offline-spectrum.md) · [Top-level README](../../README.md)

An edge site running ARM hardware cannot use an amd64-only image cache. A tag
that looks present may resolve to a manifest index whose arm64 child was never
copied. This demo captures the official BusyBox `stable` image as a complete
OCI layout, imports the index and its platform images into local zot, then
removes zot's internet route. Offline, it checks the preserved index and runs
both architecture-specific BusyBox images, including arm64 through QEMU.

It also builds a tiny static HTTP server with Buildx for `linux/arm64`, pushes
it to zot while connected, and runs an HTTP loopback self-test with Docker
networking disabled after isolation.

**Offline spectrum: levels 2–3.** See the shared
[offline spectrum](../../docs/offline-spectrum.md). Multi-platform artifacts
are staged in a local OCI registry and consumed with external egress removed.
The Docker host and daemon remain online; this is not a physically disconnected
host or a cold-start image-store bootstrap.

## Architecture

```text
CONNECTED
Docker Hub busybox:stable
     │ skopeo copy --multi-arch all
     ▼
OCI layout (index + amd64/arm64 child manifests and blobs)
     │ skopeo copy --multi-arch all
     ▼
zot:5000/library/busybox:stable ── docker pull per platform ──► local Docker store

golang:1.23.5-alpine3.21 ── Buildx --platform linux/arm64 ──► static web image
                                                                    │ push
                                                                    ▼
                                                              local zot

AIR-GAPPED
                internal-only Docker network
          ┌──────────────────────────────────────────┐
          │ zot + short-lived Skopeo client           │
          │ local index: linux/amd64 + linux/arm64    │
          └──────────────────────┬───────────────────┘
                                 │ uplink disconnected
Docker local image store ────────┼── BusyBox amd64 (network=none)
                                 ├── BusyBox arm64 under QEMU (network=none)
                                 └── static arm64 HTTP self-test (network=none)
```

## Prerequisites

- Linux amd64, Bash, Docker Engine and Buildx with a running `default` builder.
- Docker permissions to create networks, volumes, containers, and images.
- `jq`, `curl`, `clear`, `sleep`, `sed`, `grep`, and `sha256sum` on the host
  (plus standard GNU core utilities such as `id`, `cp`, and `rm`).
- Host port `127.0.0.1:5055` available; enough Docker storage for the registry
  image, tool images, BusyBox platform images, and BuildKit cache.
- Connected access to Docker Hub, GHCR, and Quay for the first phase. Anonymous
  Docker Hub rate limits or corporate proxy policy may affect the pull.
- For emulation, the script first checks for a working arm64 binfmt handler. If
  absent, it attempts to register arm64 with the pinned
  `tonistiigi/binfmt:qemu-v8.1.5` image using `--privileged`. If that is
  prohibited, the script reports the arm64 proof as untested and fails rather
  than claiming success. Run `scripts/cleanup.sh` to unregister a handler
  installed by this demo.

The demo uses plain HTTP only between local Docker clients and zot. It does not
configure Docker daemon-wide insecure registries, TLS, or authentication.

## Tested with

Tested on **2026-10-17**, Linux amd64:

| Component | Version / reference |
|---|---|
| Docker Engine and CLI | 29.9.1 |
| Docker Buildx | v0.38.0 |
| BuildKit for the `default` builder | v0.34.0 |
| Skopeo | `quay.io/skopeo/stable:v1.20.0` |
| zot | `ghcr.io/project-zot/zot-linux-amd64:v2.1.15` |
| QEMU/binfmt installer | `tonistiigi/binfmt:qemu-v8.1.5` |
| Go build stage | `golang:1.23.5-alpine3.21` |
| Registry-verified app image | Official `docker.io/library/busybox:stable` |
| k3d stretch investigation | k3d v5.9.0; k3s `v1.35.5+k3s1` (not a passing demo test) |

`busybox:stable` is deliberately a moving tag, not a reproducible pin. Each run
captures the resolved index in `artifacts/upstream-index.json`; its raw-file
SHA-256 is recorded in `artifacts/busybox-source-digest.txt`. Use the registry's
immutable index digest in a production release and verify it independently.
The source index observed on the tested run was
`sha256:73aaf090f3d85aa34ee199857f03fa3a95c8ede2ffd4cc2cdb5b94e566b11662`.
Its Linux child manifest digests were:

- `linux/amd64`: `sha256:b7f3d86d6e84fc17718c48bcde1450807faa2d56704205c697b4bd5df7b9e29f`
- `linux/arm64`: `sha256:bd44eb136a95dcc8dc58995e43abc40a413f2e8e3d4a2aae6bccbe94686acb05`

The zot index retained these same child digests in the verified run.

Image references used by the scripts are centralized in
[`config/versions.env`](config/versions.env). Docker and Buildx are host tools;
the versions above are the observed versions on the tested machine.

## Run the demo

From this directory, use one terminal:

```bash
./scripts/run-demo.sh
```

The orchestrator prints the **CONNECTED** banner, pulls pinned tooling, copies
the full BusyBox index into an OCI layout, imports it to zot, builds and pushes
the arm64 web image, and pulls both BusyBox child platforms into Docker's local
image store. It then clears an interactive terminal, detaches zot from its
uplink, verifies the egress block, re-reads the registry index, and runs the
offline checks.

The default narration pause is two seconds. Set `DEMO_SLEEP_SECONDS=0` to skip
the pauses during automation. Generated OCI content and evidence are under
`artifacts/`; the registry's persisted content is in the
`multi-arch-bundle-zot-data` Docker volume.

### CONNECTED phase

The orchestrator executes the supported all-platform copy:

```bash
skopeo copy --multi-arch all \
  docker://docker.io/library/busybox:stable \
  oci:artifacts/busybox-layout:stable
```

Skopeo v1.20.0 rejects `--all` and `--multi-arch` when supplied together
(`Cannot use --all and --multi-arch flags together`). The requested
`--all --multi-arch all` spelling is therefore not executable with the pinned
tool. `--multi-arch all` has the intended effect: copy every platform instance.
The script uses that option for both the upstream-to-OCI and OCI-to-zot copies.

Skopeo runs in a container that shares zot's network namespace. The registry
and its client initially have an ordinary bridge uplink. The source index is
saved before copying, so the script can print each Linux architecture's child
manifest digest. The OCI layout is then copied to zot, and Buildx builds the
separate static web server for arm64. Before isolation, Docker pulls the
amd64 and arm64 BusyBox variants and the arm64 app from local zot. This
pre-staging is deliberate: Docker's host-side image store is not on the
container's internal network.

### AIR-GAPPED phase

The script disconnects zot from the ordinary bridge. It asserts that zot is
attached only to the Docker network created with `--internal`, then attempts
one bounded upstream Skopeo inspection. Success is treated as an egress leak
and fails the demo; the expected failure is retained in
`.state/upstream-probe.log`.

Skopeo then reads zot's BusyBox index through `localhost:5000` in the shared
network namespace. The script checks that both `linux/amd64` and `linux/arm64`
descriptors remain, and prints their per-architecture digests. It finally
runs the locally pulled images without container networking:

```bash
docker run --pull=never --rm --network none --platform linux/amd64 \
  localhost:5055/multi-arch-bundle/busybox:amd64 uname -m

docker run --pull=never --rm --network none --platform linux/arm64 \
  localhost:5055/multi-arch-bundle/busybox:arm64 uname -m

docker run --pull=never --rm --network none --platform linux/arm64 \
  localhost:5055/multi-arch-bundle/arm64-web:demo --self-test
```

Expected key output:

```text
=== PHASE 1: CONNECTED ===
Upstream BusyBox stable linux/amd64 and linux/arm64 descriptors:
  linux/amd64 sha256:...
  linux/arm64 sha256:...
...
=== PHASE 2: AIR-GAPPED ===
zot is attached only to the internal Docker network: multi-arch-bundle-internal
Expected blocked upstream request (Skopeo output follows):
...
Air-gapped zot BusyBox linux/amd64 and linux/arm64 descriptors:
  linux/amd64 sha256:...
  linux/arm64 sha256:...
Offline BusyBox linux/amd64: x86_64
Offline BusyBox linux/arm64: aarch64
HTTP 200: hello from the offline ARM64 web server
ARM64 static web server self-test: PASS
PASS: both BusyBox architectures are in the offline zot index; amd64 and emulated arm64 run without container networking.
```

Exact digest values and network error wording depend on the live `stable` tag
and Docker environment. A missing platform, successful upstream probe, or
failed workload causes a non-zero exit; the script does not turn these into
success-shaped fallbacks.

## Manifest-list gotchas

- **Tags move.** The `stable` tag can later resolve to a different index and
  different per-architecture digests. The registry may retain an old copy
  while clients believe the tag means the latest upstream build. Record and
  deploy immutable index digests when release identity matters; verify child
  manifest digests as part of promotion.
- **`all` is not `same`.** In Skopeo v1.20.0, `--multi-arch all` copies every
  instance referenced by the index. `--multi-arch system` selects the variant
  matching the machine running Skopeo (the host-only behavior often called
  “same”); `index-only` copies the index without staging every child. `same`
  is not a valid value for this Skopeo version.
- `--all` is a compatibility shorthand for copying all images in a list, but
  it cannot be combined with `--multi-arch` in the pinned Skopeo release. This
  demo uses `--multi-arch all` alone. Do not replace it with `system` when the
  destination must serve edge nodes with a different CPU architecture.
- An index existing in a registry is not proof that all child manifests and
  layers were copied. The demo checks descriptors in the offline index and
  actually executes the arm64 image after isolation.
- A digest identifies exact manifest content, not a platform-neutral tag.
  Inspect the platform object (`os`, `architecture`, and where relevant
  `variant`) alongside the child digest.

## Troubleshooting

- **`exec format error`:** arm64 binfmt registration failed or the kernel lacks
  QEMU user-mode support. Review the script output; it tries the pinned
  privileged installer once. Do not count the runtime test as passed unless
  the image executes and reports `aarch64`.
- **Privileged binfmt installer is denied:** run this demo on a host where the
  Docker daemon permits the registration, or leave the arm64 execution marked
  `# UNTESTED`. The registry-index checks alone do not prove execution.
- **Port 5055 is occupied:** free `127.0.0.1:5055` before starting. The port is
  fixed so Docker can pull the local images before zot's uplink is removed.
- **Skopeo rejects `--multi-arch`:** use the pinned Skopeo image in
  `config/versions.env`; this flag is not supported by every older Skopeo.
  Do not add `--all` beside it: v1.20.0 rejects that combination.
- **Missing arm64 descriptor in zot:** inspect
  `artifacts/upstream-index.json` and `artifacts/connected-zot-index.json`.
  Confirm the OCI layout was copied with both multi-arch options and that zot
  accepted the OCI index.
- **Docker cannot pull from local zot:** ensure port 5055 is free and local
  Docker allows HTTP registries on `localhost`. The script does not change
  daemon configuration.
- **BusyBox rate limit or registry timeout:** retry from a network that can
  reach Docker Hub, or authenticate Skopeo using an approved auth file. This
  standalone demo intentionally does not copy personal credentials into its
  containers.
- **A failed run left resources behind:** inspect the recorded zot log under
  `.state/`, then run the cleanup script before retrying.

## Known limitations

- **# UNTESTED — k3d multi-architecture agent workload.** The k3d v5.9.0
  investigation confirmed that an ARM64 k3s image can be supplied to
  `k3d node create` using a separate platform-specific image tag. With
  `K3D_FIX_DNS=false`, the agent briefly registered and reported
  `kubernetes.io/arch=arm64`, but its kube-proxy then exited because this
  amd64 sandbox's QEMU/kernel combination reports
  `iptables: Failed to initialize nft: Protocol not supported`. The agent
  never reached stable Ready or ran a workload, so the mixed-cluster stretch
  remains untested. The verified portability proof is Docker's
  `--platform linux/arm64` execution under QEMU/binfmt. Repeat the k3d test on
  native ARM64 nodes or a host whose kernel supports the required iptables
  operations before promoting this stretch.
- zot is an amd64 local registry container. Its server architecture is
  independent from the architectures represented in its OCI catalog.
- QEMU user-mode emulation proves that this arm64 binary starts and behaves
  correctly on the tested amd64 host; it is not a performance measurement or
  a substitute for native ARM hardware testing.
- Docker's host and daemon remain connected. `--internal` isolates zot and its
  Skopeo client, and `--network none` isolates the tested workloads, but this
  is not a physical network disconnect or a host-wide firewall.
- The ARM64 Go app is built from a pinned toolchain image tag but that tag is
  not digest-pinned. BuildKit may also reuse its local cache. For a release,
  pin builder digests and record provenance/SBOMs.
- The `stable` alias is resolved live during CONNECTED. This demonstrates
  registry/index behavior, not long-term reproducibility or trust in a
  separately transferred bundle.

## Where network is still required

The CONNECTED phase needs internet access to pull the pinned Skopeo, zot,
binfmt (only if needed), and Go builder images, and to resolve BusyBox
`stable`. It needs network access to push/pull from the local zot endpoint
before isolation. After the uplink is removed, the client can still access
zot over loopback in their shared network namespace, but it cannot reach
Docker Hub. Docker's local image store and the Docker daemon are on the host;
the demo does not disable the host's own network or firewall.

In a real air-gapped site, transfer the verified OCI layout and required
runtime/tool images into the zone through an approved process, verify their
digests/signatures there, and configure a locally reachable registry. This
demo's first connected phase is the acquisition/staging step, not a claim that
the first image can be obtained without a network.

## Future tooling

OCI indexes are already a useful portability boundary, but offline promotion
is moving toward immutable, signed, policy-checked artifact sets. Expect
registry tooling to make multi-platform closure, digest pinning, SBOMs,
provenance and signatures easier to export and verify together. Build systems
are also improving cross-platform builds without emulation, while runtime
teams are making platform selection and node scheduling more explicit. For
edge fleets, the useful next step is a signed promotion record that binds the
index digest to the exact approved child digests and the target architecture
set—not a mutable tag alone.

## Cleanup

```bash
./scripts/cleanup.sh
```

Cleanup removes this demo's labeled zot container, networks and volume,
generated artifacts, its uniquely named local image tags, and an arm64 QEMU
handler only if this demo installed it. Pinned tool and builder images remain
cached. It does not change Docker daemon configuration or remove unrelated
images, networks, or volumes.
