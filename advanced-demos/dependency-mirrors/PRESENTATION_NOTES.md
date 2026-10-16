# Presentation notes: dependency mirrors

## Story

The team has already mirrored every container image, but its next build still
reaches for PyPI, npm, a Go module proxy and Debian. The image is present; its
build inputs are not. Acquire and freeze those inputs while connected, then
remove the build network and compare the successful vendored builds with a
deliberately cold npm cache.

## Key beats

1. **Frame the hidden assumption.** Point out that an image mirror says nothing
   about `pip install`, `npm ci`, `go build` or `apt install` executed in a
   Dockerfile.
2. **Connected acquisition.** Walk through `wheels/`, npm's content cache,
   Go's `vendor/`, and exact `.deb` files. Emphasize that each goes into the
   same tarball, but base images are transferred separately.
3. **Air-gapped proof.** Show the four `docker build --network none` commands
   and the no-index/offline/vendor/local-dpkg install flags in the Dockerfiles.
   The app-level smoke tests run with Docker network `none` as well.
4. **Negative control.** The same Express Dockerfile fails when its local cache
   is empty. Read the `ENOTCACHED` diagnostic: offline mode does not silently
   fall back to the public registry.
5. **Optional registry contrast.** Run
   `./scripts/run-verdaccio-stretch.sh`: pre-acquired npm tarballs are published
   to an internal-only Verdaccio instance, and `npm ci --registry
   http://verdaccio:4873` consumes them with a fresh cache. Contrast a shared
   service with a file bundle; neither route uses Internet egress.
6. **Close honestly.** The host and daemon are not disconnected; the build
   network is. Base images, an OS snapshot and signed transfer are separate
   supply-chain concerns.

## Likely questions

- **Why use both a bundle and Verdaccio?** The four headline builds consume
  vendored artifacts with networking disabled. The optional registry exercise
  compares the shared-service workflow without weakening those builds.
- **Is an npm cache the same as a registry mirror?** No. It is package-manager
  cache content sufficient for this locked install, not a registry API or
  general package repository.
- **Does `--network none` disconnect Docker itself?** No. It isolates build
  steps from networks; the CLI still uses the local Docker daemon. We preload
  the base images and disable pulling so a missing image fails locally.
- **Will these wheels/debs work on ARM or Alpine?** Not necessarily. The
  wheelhouse is CPython/Linux amd64, the Go build uses its pinned base platform,
  and Debian packages target Bookworm. Regenerate each artifact set for the
  deployment platform/libc.
- **Where are package hashes and trust rooted?** pip/npm/Go's lock and checksum
  mechanisms and apt's repository metadata protect the connected download
  path. The demo does not sign the final tarball; a real transfer should add a
  signed manifest, provenance and independent verification.
- **Can the connected step be repeated deterministically?** Python, Node and Go
  libraries are pinned. Debian resolves from the repository state at download
  time; preserving its `.deb` files preserves that acquisition, but a pinned
  repository snapshot is needed for deterministic future reacquisition.
- **What changes for a production build?** Pin base-image digests, repository
  snapshots, toolchain versions and target platforms; scan artifacts; emit an
  SBOM/provenance record; and verify a signed bundle before importing it.
- **Is Verdaccio reachable from outside Docker?** No. The optional script
  creates an internal Docker network, publishes no host port, and removes the
  service, network, volume and temporary credentials on completion.

## Presenter controls

- Run `DEMO_SLEEP_SECONDS=2 ./scripts/run-demo.sh` for a compact narration beat
  between phases.
- Set `DEMO_SLEEP_SECONDS=0` for a rehearsal or automated check.
- Keep `artifacts/contrast-build.log` available to inspect the full npm cache
  miss after the final banner.
- `./scripts/cleanup.sh` clears generated artifacts and only this demo's image
  tags; leave the pinned base images cached to make a repeat fast.
- `./scripts/run-verdaccio-stretch.sh` runs the optional npm mirror exercise
  after a connected artifact-acquisition run.
