# Offline vulnerability scanning with transported databases

| Spectrum level | Demo app | Headline tooling | Status |
|----------------|----------|------------------|--------|
| 3 | node (old tag) | trivy, grype | 🚧 WIP |

Vulnerability scanning with bundled, offline vulnerability databases

[Offline spectrum](../../docs/offline-spectrum.md) · [Top-level README](../../README.md)

This demo scans a deliberately old, CVE-bearing container image with Trivy and
Grype after moving each scanner's vulnerability database and an OCI image layout
into an environment that has no external route. The local registry, import tool,
and scanner containers share a Docker `--internal` network. The scanners can
reach the local registry, but cannot reach a vulnerability feed or the public
internet.

## Offline spectrum

Level 3 in the shared [offline spectrum](../../docs/offline-spectrum.md). The
scanner data and image are prepared as a portable archive, then used with
outbound networking blocked at the Docker network layer. This demonstrates
offline image scanning and DB transport, not offline provisioning of the Docker
engine or operating system. Those prerequisites must already be installed and
available on the target host.

## Architecture

```text
CONNECTED host
  Trivy DB ─┐
  Grype DB ─┼──> artifacts/offline-vuln-scan-bundle.tar.gz
  scanner binaries ─┤          (DBs + binaries + OCI layout)
  candidate image ──┘
                                  │ extract
AIR-GAPPED Docker internal network (--internal)
  Skopeo ──> registry:5000 <── Trivy / Grype
                   no external egress
```

The archive is extracted before the air-gapped phase. A pinned registry and
tools container are also pulled in CONNECTED phase and retained in the local
Docker image cache. No external port is published for the registry.

## Prerequisites

- Linux amd64 or arm64, Bash 4+, Docker Engine/CLI with permission to use the
  daemon, and an interactive terminal for presenter pauses (optional).
- `curl`, GNU `tar`, `sha256sum`, `jq`, `timeout`, `date`, `du`, `cut`, and
  `tail` on the host.
- CONNECTED access to GitHub release downloads, Docker Hub, GHCR/Quay as used by
  pinned tool images, Trivy's DB repositories, and Grype's DB endpoint. A proxy
  may be required in restricted networks.
- Disk for the vulnerability databases, OCI image, Docker images and registry;
  budget at least 8 GB for the first run. The compressed transport archive is
  about 760 MiB in the tested run while the unpacked databases total several GB.
- Ports are not exposed by the registry. The demo reserves its named Docker
  network and container, and refuses collisions with resources not labelled as
  belonging to this demo.

The scanner binaries are downloaded directly and verified against release
checksums. Skopeo (`quay.io/skopeo/stable:v1.20.0`), the registry
(`registry:2.8.3`) and the minimal scan runtime (`alpine:3.22.1`) are pinned by
tag and pre-pulled while connected. To reproduce in a fully disconnected
environment, transport those Docker images through the site's approved image
import process too.

## Run the demo

From the repository root:

```bash
cd advanced-demos/offline-vuln-scan
./scripts/run-demo.sh
```

The orchestrator creates two explicitly labelled phases and pauses for
presenter narration between them in an interactive terminal. Use
`DEMO_AUTO_ADVANCE=1 ./scripts/run-demo.sh` to skip prompts in automated runs.
It uses short sleeps between banners and clears an interactive terminal between
phases.

### CONNECTED phase

The script verifies release checksums, downloads the pinned scanner binaries,
fetches both vulnerability databases, and records their metadata. It tests the
candidate images `node:16-alpine`, `python:3.9-slim`, and `nginx:1.21-alpine`
against both downloaded databases. It selects the first tag with nonzero
findings from both tools. If no candidate qualifies, it exits with an error
rather than claiming a successful demonstration.

It pulls the selected image and runs Skopeo with `copy --all` to export it to an
OCI layout. The archive at
`artifacts/offline-vuln-scan-bundle.tar.gz` contains the complete Trivy cache
tree, the complete Grype DB cache directory, both verified scanner binaries,
the OCI layout, Grype config, and `metadata.txt`. The metadata records the
tested image and connected finding counts; the script also prints the Trivy DB
publication/update timestamp and Grype DB schema/path.

### AIR-GAPPED phase

The archive is extracted into a staging directory. The script starts a
`--internal` Docker network, imports the image into the local registry, then
scans `registry:5000/demo/scan-target:offline` with each bundled database. The
scan containers have only the internal network attached. It asserts both tools
report at least one finding.

Finally, it explicitly runs Trivy DB download and Grype DB update commands from
inside that same network. Both commands must fail; an unexpected update success
fails the demo. The registry is left running for inspection until cleanup.

Expected highlights (exact dates, selected image, and counts are emitted by the
script and captured in the tested-with record below):

```text
=== PHASE CONNECTED: download tools, databases, and image ===
Trivy DB published/updated at: <timestamp>
Grype schema: <schema>
Selected image: node:16-alpine

=== PHASE AIR-GAPPED: internal registry, scanners, and update failures ===
Internal network: offline-vuln-scan-internal (Internal=true)
Offline findings: Trivy=92; Grype=145
Trivy forced update: expected non-zero exit
Grype forced update: expected non-zero exit
```

### Tested with

Tested 2026-10-16 on Linux amd64:

| Component | Tested version / result |
| --- | --- |
| Docker Engine | 29.9.0 |
| Trivy | 0.76.0 |
| Grype | 0.120.1 |
| Trivy vulnerability DB `UpdatedAt` | 2026-10-16T01:13:54.947090392Z |
| Grype DB schema | v6.1.10; cache file `grype-db/6/vulnerability.db` |
| Skopeo container | `quay.io/skopeo/stable:v1.20.0` |
| Registry container | `registry:2.8.3` |
| Scan runtime container | `alpine:3.22.1` |
| Selected image | `node:16-alpine` (Alpine 3.18.3) |
| Connected findings | Trivy 92; Grype 145 |
| Air-gapped findings | Trivy 92; Grype 145 |

The first candidate, `node:16-alpine`, qualified, so the other candidates were
not needed. Its Alpine base is end-of-life; Trivy warns that vulnerability
coverage may be incomplete. The counts are exact for the image and DB snapshots
used on the test date, not a promise about future mutable-tag pulls. The
unattended rehearsal completed successfully in **286 seconds (4m 46s)** on
this host; timings vary with registry/download bandwidth and disk throughput.

## Policy decision and Ratify relationship

Both scanners can return machine-readable JSON. A CI gate can use Trivy's
`--exit-code 1 --severity HIGH,CRITICAL` or Grype's `--fail-on high` to turn
findings into a nonzero policy decision. Keep the report and bundle digest as
build evidence. This is conceptually related to the Ratify demo: Ratify evaluates
policy around image trust and attached artifacts at admission, while this demo
shows that vulnerability policy evaluation itself also depends on bringing
current-enough vulnerability data into the isolated environment.

## Where network is still required

- The connected preparation needs network access to scanner release assets,
  vulnerability DB endpoints, and the image registry/CDNs. Image manifests may
  refer to multiple layer hosts.
- The target host needs Docker, the scanner runtime image, registry image, and
  Skopeo image available locally before becoming disconnected. This flow
  pre-pulls them in CONNECTED phase, but does not bundle all Docker image layers
  into its archive.
- This isolates containers on one Docker engine with an internal network; it
  does not prove that the host itself lacks internet access, nor does it defend
  against a privileged container, host networking, daemon compromise, or an
  accidental second network attachment. Review the network attachments and keep
  the scanner containers unprivileged.
- A scanner can only identify vulnerabilities represented in its bundled
  database. The data gets stale: Grype's default DB age validation rejects
  databases older than five days. Updating the archive on a schedule is
  operationally necessary; don't disable age validation to disguise staleness.
- The demo does not use a Kubernetes NetworkPolicy or claim that Docker's
  `--internal` setting replaces cluster egress policy.

## Troubleshooting

- **Checksum or release download fails:** verify connected GitHub access and
  proxy handling. The script stops before producing an archive if checksum
  verification fails.
- **No candidate has findings in both tools:** a tag can move, and vulnerability
  data changes. The script tries all three candidates; it will not substitute
  fabricated success. Inspect the reports under `.work/`, then choose a
  currently vulnerable candidate from the listed candidates and update the
  candidate list before retrying.
- **Docker Hub rate limit or pull failure:** authenticate Docker before running
  the connected phase, or use an approved mirror. Do not change the recorded
  image tag without recording the new selected tag and counts.
- **DB rejected as stale:** rerun CONNECTED preparation to refresh the database
  bundle, then rerun the demo. Grype's default maximum database age is five
  days.
- **Registry import fails:** check Docker's disk space and that the pulled
  Skopeo and registry images match the pinned tags. The target registry uses
  plain HTTP only on the internal network.
- **Update check does not fail:** the script treats an update success as a
  failure of the isolation proof. Confirm the scanner container is attached
  only to the named `Internal=true` network and that the registry is not
  accidentally attached elsewhere.

## Cleanup

```bash
./scripts/cleanup.sh
```

This removes the demo's labelled registry container and internal network, but
retains the archive and bundle for another rehearsal. To remove this demo's
generated databases, registry data, staging files, and archive too:

```bash
./scripts/cleanup.sh --purge
```

Cleanup never removes Docker images pulled by the demo; remove those individually
if desired.

## Future tooling

The useful next step is treating scanner databases like other versioned,
attestable supply-chain artifacts: publish immutable, signed bundles with
generation timestamps, checksums, provenance, and an explicit freshness
policy. In Kubernetes, an offline scanner service or scheduled Job could mount
a read-only DB bundle and scan imported images; cluster egress policy should
make unintended feed access observable. The important design question remains
whether the operational cadence and transport path can deliver updates before
the database expires.

## Known limitations

- This demo targets Linux amd64 and arm64, uses mutable image tags for the
  vulnerability sample, and doesn't pin downloaded image content to a
  published digest in the human-readable metadata.
- The scanner binaries are checksum-verified, but the demo does not verify
  Docker image signatures for its pinned support images.
- No CronJob or Kubernetes cluster is created. The Docker internal network is
  the tested egress-control mechanism.
- If the Docker engine or host has privileged access to external resources, the
  internal network doesn't isolate the host.
