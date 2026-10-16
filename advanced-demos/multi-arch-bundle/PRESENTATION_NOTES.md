# Presentation notes: multi-architecture bundle

## Story

An edge rollout can have the right image name and still be stranded: an
amd64-only cache is not a usable cache for an ARM device. Show the distinction
between having a tag and having the complete manifest index, then remove the
registry's uplink and run the ARM64 workload from its staged image.

## Key beats

1. **Frame the failure mode.** The public BusyBox `stable` tag resolves to an
   index. Its amd64 child is not a substitute for the arm64 child. Ask the
   audience what an ARM edge node gets if only the host architecture was
   mirrored.
2. **Connected acquisition.** Point out the
   `skopeo copy --multi-arch all` and the OCI layout. Read the printed
   per-platform child digests; identify `stable` as a moving tag.
3. **Build a real ARM64 workload.** Show that Buildx emits a
   `linux/arm64` static Go image rather than retagging an amd64 binary.
4. **Stage before the cut.** zot holds the BusyBox index and the app. Docker
   has pulled both BusyBox architectures while it can still reach local zot.
5. **Make the outage tangible.** The script disconnects zot from its external
   bridge and confirms the registry/client share only an internal network. The
   bounded Docker Hub request must fail; zot's local index request must work.
6. **Prove the outcome.** Compare offline index descriptors to the connected
   evidence, then show amd64 `x86_64`, arm64 `aarch64`, and the server's HTTP
   self-test with `--network none`.
7. **Close honestly.** The Docker host is not physically unplugged, and QEMU
   is not native ARM performance. The k3d multi-arch agent stretch is
   `# UNTESTED`.

## Presenter controls

- Run `DEMO_SLEEP_SECONDS=2 ./scripts/run-demo.sh` from this directory.
- Set `DEMO_SLEEP_SECONDS=0` for a fast rehearsal.
- Keep the default pauses and the clear between phases for a live talk.
- The script leaves zot on an internal-only network and leaves evidence in
  `artifacts/`; run `./scripts/cleanup.sh` after questions.
- If the pinned binfmt handler had to be registered, cleanup unregisters that
  handler. The script never reports the arm64 proof as passed if execution
  fails.

## Likely questions

**Why use BusyBox?** It is the official Docker Library image, small enough for
a quick index-and-runtime check, and its `stable` reference resolves to a
multi-platform index.

**Why not both `--all` and `--multi-arch all`?** Skopeo v1.20.0 rejects the
combination. `--multi-arch all` alone copies every child platform; Skopeo's
host-matching behavior is `--multi-arch system`.

**Does an index prove every layer is present?** No. The script also pulls the
two child images from local zot before isolation and runs them offline. A
production process should additionally verify immutable digests and signatures.

**Is the Docker host offline?** No. zot and its Skopeo client lose external
egress through the internal-only network; the actual workload containers use
`--network none`. This is a network-isolation proof at the container layer.

**Is the custom server really ARM64?** Buildx builds the target for arm64, the
image metadata is checked, and Docker runs it with `--platform linux/arm64`.
The self-test makes an HTTP request to the server over loopback and checks the
body. On this amd64 host that requires QEMU/binfmt; it is not a benchmark.

**Why not show k3d?** The multi-arch k3d agent-node extension is outside the
verified baseline and remains `# UNTESTED`; no cluster result is implied.
