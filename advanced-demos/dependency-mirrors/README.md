# Dependency mirrors: build with the network removed

Images are only half the offline problem. A normal container build may still
download wheels, npm tarballs, Go modules or OS packages after its base image
has been mirrored. This demo makes those build-time inputs explicit: it first
acquires them while connected, bundles them, and then builds four small apps
with Docker's build network set to `none`.

**Offline spectrum: level 3 — dependency-complete builds from a pre-staged
artifact bundle.** The base images and Docker engine must already be present on
the offline builder. This is not a demo of bootstrapping Docker or acquiring
the initial artifact bundle with no connection.

## Architecture

```text
CONNECTED                                      AIR-GAPPED
Docker Hub -> pinned base images ────────────> local Docker image store
PyPI       -> wheels/ ─┐
npm        -> npm cache├-> dependency-mirrors.tar.gz -> Docker build --network none
Go proxy   -> vendor/  │                              ├─ Flask / pip --no-index
Debian     -> .deb files┤                             ├─ Express / npm --offline
npm lock   -> tarballs ┘                             ├─ Go / -mod=vendor
                                                     ├─ jq / dpkg -i
                                                     └─ optional internal Verdaccio
```

Each air-gapped `RUN` step has BuildKit's network disabled (`--network none`),
and every base image is pulled before that phase. Runtime smoke-test containers
also use `--network none`. The optional registry exercise is the deliberate
exception: its client can reach Verdaccio over a Docker `--internal` network,
but an external TCP egress probe must fail. This scopes the proof to containers;
the host and Docker daemon are not physically disconnected.

## Prerequisites

- Linux amd64, Bash, Docker Engine/CLI with BuildKit, GNU `tar`, `find`, `grep`,
  `wc`, and `clear` for interactive phase transitions.
- An internet-connected first run with access to Docker Hub, PyPI, npm, the Go
  module proxy and Debian Bookworm package repositories.
- Disk space for the pinned base images, downloaded caches, and image builds.
- No Kubernetes cluster is used. A demo image tag is reserved per app; run one
  copy of this demo at a time on a Docker engine.

The dependency artifact bundle does **not** include the Docker base images.
Transfer those separately (or save/load them with Docker) before running the
build phase on a disconnected host. Source code and lockfiles likewise travel
with this demo directory.

## Tested with

Tested on **2026-10-16**, Linux amd64:

| Tool/input | Pinned or observed version |
|---|---|
| Docker Engine and CLI | 29.9.0 |
| Python artifact/build image | `python:3.12.8-slim-bookworm` |
| Flask | 3.1.0 |
| pip in the Python image | 24.3.1 |
| Node artifact/build image | `node:22.13.1-bookworm-slim` |
| npm in the Node image | 10.9.2 |
| Express | 4.22.3 |
| Go artifact/build image | `golang:1.23.5-bookworm` |
| Go module | `github.com/fatih/color` 1.18.0 |
| Debian utility image | `debian:bookworm-slim` |
| C utility / Debian packages | `jq` 1.6 (`jq` / `libjq1` `1.6-2.1+deb12u2`; `libonig5` `6.9.8-1`) |
| Optional npm mirror | `verdaccio/verdaccio:6.2.3` |

Image tags are pinned in [`config/base-images.env`](config/base-images.env);
application libraries are pinned in their requirements/lock/module files.
The tested Debian package versions are preserved as exact `.deb` files in the
bundle. The script resolves them from the configured Bookworm repositories
when connected; the host apt command is not used.

## Run the demo

From this directory:

```bash
./scripts/run-demo.sh
```

The orchestrator prints `=== PHASE 1: CONNECTED ===`, downloads the pinned
toolchain images and dependency artifacts, and writes
`artifacts/dependency-mirrors.tar.gz`. After a short narration pause, it clears
an interactive terminal and moves to `=== PHASE 2: AIR-GAPPED ===`. Set
`DEMO_SLEEP_SECONDS=0` to skip the pause during automation; the default is two
seconds.

### Connected artifacts

- **pip:** `pip download --only-binary=:all: -r requirements.txt` runs inside
  the same pinned Python/Linux image used for the build. This deliberately
  avoids host-Python wheel tags. These wheels target Linux amd64 and CPython
  3.12; changing Python ABI, architecture, libc or platform needs a matching
  wheelhouse (or an explicit pip `--platform`, `--python-version`,
  `--implementation` and `--abi` strategy).
- **npm:** `npm ci --cache ...` fills a content-addressed cache from the
  committed package lock. It also exports exact locked tarballs from that cache
  for the optional registry exercise, without running package lifecycle hooks
  while packing. `npm ci` requires the lock to match `package.json`.
- **Go:** `go mod download` resolves the pinned module, then `go mod vendor`
  writes the complete source tree used by the offline build.
- **apt:** `apt-get update` then `apt-get download jq libjq1 libonig5` fetches
  the jq executable and its non-base shared-library dependencies. The Debian
  base already supplies libc. No repository metadata or apt server is included.
- **Bundle:** one tarball contains `pip/`, `npm-cache/`, `go/`, `debs/` and
  `verdaccio/`. The generated cache and bundle are ignored by Git.

To move the dependency artifacts to another copy of this demo, transfer the
tarball into its `artifacts/` directory and unpack it:

```bash
mkdir -p artifacts
tar -xzf artifacts/dependency-mirrors.tar.gz -C artifacts
```

The target builder also needs the exact base images locally. Save them from the
connected Docker engine and import them on the target:

```bash
docker save -o dependency-mirrors-base-images.tar \
  python:3.12.8-slim-bookworm node:22.13.1-bookworm-slim \
  golang:1.23.5-bookworm debian:bookworm-slim \
  verdaccio/verdaccio:6.2.3
docker load -i dependency-mirrors-base-images.tar
```

With source, extracted artifacts and images present, run only the isolated
phase on the disconnected builder:

```bash
./scripts/run-demo.sh --air-gapped
```

This mode checks the local artifacts and image store without pulling or
acquiring anything, then performs the builds with `--network none`.

### Air-gapped proof and expected output

The build contexts are staged from the app sources plus the acquired artifact
directories. The four Docker builds explicitly use
`docker build --network none --pull=false`; there are no package-manager
network fallbacks in their Dockerfiles:

```text
pip install --no-index --find-links /deps/wheels
npm ci --offline --cache /deps/npm-cache
GOPROXY=off GOSUMDB=off go build -mod=vendor
dpkg -i /deps/debs/*.deb
```

Each image then gets a smoke test in a runtime container with
`--network none`: Flask and Express return their local `/healthz` payload, the
Go CLI prints its greeting, and jq parses a local JSON string.

Finally, the orchestrator builds the **same Express Dockerfile** using an
intentionally empty npm cache. That build is required to fail; a recognized
`ENOTCACHED`/cache-miss diagnostic is printed and retained at
`artifacts/contrast-build.log`. If it succeeds, or fails for an unrelated
reason, the script itself fails rather than claiming a successful proof.

`--network none` is Docker/BuildKit's isolation mechanism: `RUN` processes have
no network interface other than loopback. Docker still talks to its local
daemon, and the host is not firewalled. An image missing from the local store
will fail with `--pull=false` instead of being fetched during the proof.

## Vendored artifacts vs mirror servers

| Approach | Example | Strengths | Trade-offs / choose it when |
|---|---|---|---|
| Bundle a wheelhouse/cache/vendor tree | This demo; `pip --no-index`, npm offline cache, `go mod vendor` | Portable, immutable transfer unit; does not need an in-cluster or LAN service; smallest runtime dependency graph | Must rebuild and distribute bundles as inputs change; caches can be platform-specific; npm cache is not a general-purpose registry |
| Language registry mirror | Verdaccio for npm; a simple private pip index | Familiar package-manager UX, shared across many builds, policy/scanning and retention can be centralized | Requires a reachable service, storage, TLS/auth and its own lifecycle; a mirror is still a network dependency and must be available in the isolated zone |
| OS package mirror/cache | apt-mirror or apt-cacher-ng | Supports normal apt workflows and many clients; apt-cacher-ng can be a pull-through cache | Needs repository metadata, retention and service configuration; a cold cache still needs upstream access; a cache server is not a substitute for validating package signatures |

Pick a bundle for a bounded, auditable release or a truly disconnected build
worker. Pick a registry/mirror service for a connected enclave with many
concurrent consumers and an operational owner. A hybrid commonly stages a
verified mirror snapshot into the enclave and serves it locally.

### Optional Verdaccio stretch goal

The connected phase also packs the exact npm tarballs from the committed lock
into `artifacts/verdaccio/packages/` and includes them in the dependency bundle.
After the normal demo has finished, run:

```bash
./scripts/run-verdaccio-stretch.sh
```

This starts Verdaccio 6.2.3 and its npm client on a dedicated Docker network
created with `--internal`; there is no published host port, and the Verdaccio
configuration has no upstream uplink. The client publishes only the
pre-acquired package tarballs, then performs a clean
`npm ci --registry http://verdaccio:4873` with a fresh cache and verifies the
Express app in a separate `--network none` container. The npm configuration
uses `--replace-registry-host=always` so lockfile tarball URLs are fetched from
the local registry. The Docker network's `Internal` flag is checked before
publishing or installing.

The script generates a throwaway password and bcrypt htpasswd record at
runtime, uses it only for authenticated publishing, and removes both
credential files, the registry container, internal network and storage volume
on exit. No credential, registry data or secret is committed. The
`verdaccio/verdaccio:6.2.3` image must be pulled while connected and transferred
with the other base images for a fully disconnected rehearsal. This is a
local-registry connectivity demo, not a `docker build --network none` build:
the four headline image builds above remain strictly network-none.

## Troubleshooting

- **`no such image` / base image not found:** pull the exact tags in
  `config/base-images.env` while connected, or transfer them with `docker save`
  and `docker load`. `--pull=false` is intentional.
- **pip says no matching distribution:** the wheelhouse was generated for a
  different Python ABI, architecture, libc or platform. Regenerate it with the
  pinned Python image; do not remove `--no-index`.
- **`npm ci` complains about the lock or missing cache entries:** keep
  `package.json` and `package-lock.json` in sync, and rerun the connected cache
  acquisition with the pinned Node/npm image. Do not replace `npm ci` with an
  unlocked install.
- **Go reports a missing vendor package:** rerun `go mod download && go mod
  vendor` in the pinned Go image and include the refreshed `vendor/` in the
  bundle.
- **`dpkg -i` reports unresolved dependencies:** the base-image ABI and Debian
  package set do not match. Download the complete dependency closure from the
  same Bookworm repository snapshot, or add the missing `.deb` and test again.
- **Negative control fails without a cache-miss diagnostic:** inspect
  `artifacts/contrast-build.log`; the script intentionally treats unrelated
  failures as failed verification.
- **Verdaccio rejects a publish:** check the pinned Verdaccio image and
  `config/verdaccio.yaml`; rerun after its exit handler removes the stretch
  container/network/volume and temporary credentials.
- **A cleanup image removal is blocked:** remove the running container that
  references this demo's tagged image, then run `scripts/cleanup.sh` again.

## Known limitations

- Tested only on Linux amd64 with the stated image tags. Wheel tags, native
  modules, Go target architecture and Debian packages are not portable across
  arbitrary operating systems/architectures.
- Docker image tags are explicit but not content-addressed digests. For a
  long-lived supply-chain release, resolve and pin digests and verify them
  during transfer.
- Debian package selection tracks the configured Bookworm repository state at
  acquisition time. The `.deb` files make that specific build repeatable, but
  the script does not pin a dated Debian snapshot or sign a separate manifest.
- The npm cache is a local content cache rather than a distributable registry.
  It exercises `npm ci --offline`; the optional Verdaccio stretch demonstrates
  the registry API without replacing the core proof.
- The online phase requires each upstream registry/repository to be reachable.
  Artifact integrity relies on normal package-manager lock/hash/signature
  verification; the demo does not add an independent signed bundle manifest.

## Where network is still required

Network access is required to pull the initial base images and to acquire or
refresh dependencies in the connected phase. This demo does not mirror Docker
images into its tarball, provision the Docker engine, resolve dependencies
absent from its lockfiles, or establish trust in a transferred artifact bundle.
The Debian download follows live Bookworm repository metadata on each connected
run. In production, pin image digests and an OS repository snapshot, verify
signatures/checksums out of band, and transfer the exact bundle and source into
the isolated build zone.

## Future tooling

Expect more first-class, reproducible dependency snapshots: OCI artifacts or
signed bundles that carry software bills of materials, provenance and
verification metadata alongside packages; snapshot-capable package proxies;
and build systems that make network access an explicit policy rather than a
default. For npm, a local Verdaccio service can expose a registry endpoint
(`npm ci --registry http://verdaccio:4873`) and centralize multiple projects'
package requests; the optional stretch demonstrates this on an internal-only
network. For apt, apt-cacher-ng or an immutable repository snapshot offers the
equivalent shared workflow. A running mirror adds a network hop and must itself
be staged into the disconnected environment.

## Cleanup

```bash
./scripts/cleanup.sh
```

This removes only this demo's generated `.work/`, `artifacts/` and specifically
tagged demo images, plus any labelled Verdaccio container, internal network and
volume left by an interrupted stretch run. It does not remove the pinned base
images, modify Docker's global configuration, or touch other demos.
