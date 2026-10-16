# Taking cloud-native offline: a signed deployment bundle

A **single-terminal** demo of the offline software supply chain:

1. On a connected build host, download the popular Bitnami **nginx chart** and
   Docker Hub's official **`nginx:latest`** image.
2. Sign an inventory that authenticates **every image layer, manifest, config,
   chart dependency and deployment value**, then create a transport archive.
3. Receive that archive in an isolated target, verify using an **independently
   trusted public key**, import into a local zot registry, and deploy with Helm.
4. Confirm the pod is Ready and serves nginx's welcome page **without internet**.

The application bundle is about 61 MiB for the tested nginx release. Kubernetes
and the tools are **pre-provisioned infrastructure**, not hidden dependencies
downloaded during verification.

## Architecture and trust boundary

```text
CONNECTED BUILD SIDE                      AIR-GAPPED TARGET

Docker Hub: nginx:latest                   Pre-provisioned kind node
Bitnami: nginx chart + common dependency    (default internet routes removed)
          |                                           |
          v                                           |
Skopeo -> images/nginx/                                |
Helm   -> charts/nginx-22.0.11.tgz                      |
          |                                           |
SHA-256 inventory: metadata.json                       |
          |                                           |
Cosign sign-blob (PRIVATE KEY stays here)               |
          |                                           |
          +---- bundle.tar.gz -- removable media ----> safe extraction
                                                      |
TRUSTED PUBLIC KEY ---- independent channel ----------> Cosign verify-blob
                                                      + all file hashes
                                                      |
                                             verified Skopeo import
                                                      |
                                             zot localhost:5001
                                                      |
                                             local chart + Helm
                                                      |
                                             nginx@sha256:...
                                             1/1 Ready + HTTP 200
```

For the conference, both sides live on one host; the wrapper models transport
by passing the archive to an isolated target. **No target operation downloads
from the internet.** Skopeo, zot, Helm, kubectl, containerd and the deployed
workload run in the node's network namespace (or its pods). Cosign verification
runs with Docker `--network none`. The host only orchestrates Docker and stays
connected; it is not itself a physically air-gapped machine.

### What is signed, and why not just trust the bundled key?

Cosign cannot `sign` an unpushed Skopeo `dir:` image reference. Instead,
`sign-blob` signs **metadata.json**, whose authenticated file inventory includes
the image manifest **and every layer/config blob**, the chart archive (including
its packaged `common` dependency), deployment values and public key. Checking
only the manifest would not detect tampered layer bytes; the complete inventory
does. SHA-256 hashes without a verified signature would not establish trust.

The public key inside the archive is for portability, **not a trust anchor**.
An attacker could replace both payload and bundled key. Verification therefore
requires `--trusted-key /trusted/cosign.pub`, supplied outside the archive.
The wrapper uses the original build-side key file to model independent delivery.
For a real transfer, enroll that key or check its fingerprint through a separate
authenticated channel **before** receiving the archive.

The deployed image is addressed by the authenticated **digest**, not a mutable
`latest` tag. Import also checks that zot preserved the exact manifest digest.
This prevents a registry tag change from silently changing the deployed content.

## Prerequisites and assumptions

- **Native Linux amd64** host, a Linux amd64 Docker engine with working kind
  support, Docker access without sudo, and at least **4 CPUs, 6 GiB available RAM
  and 6 GiB free disk space**. kind uses a privileged disposable node container.
- Bash 4+, GNU `tar`, coreutils (`timeout`, `sha256sum`, `sort`, `stat`,
  `realpath`, etc.), `jq`, `awk`, `grep`.
- Host **Helm 3.12+ or Helm 4** and **kind v0.31.0**. Helm must be a native,
  standalone Linux amd64 executable, not a shell/snap wrapper: preparation copies
  it into the target. kubectl is supplied by the kind node image.
- Port **127.0.0.1:5001** free. kind also allocates a loopback API server port.
  Do not run concurrent copies; the resource names are reserved for this demo.
- Initial connected-side access to Docker Hub/Bitnami OCI, GHCR and Quay.
  Anonymous Docker Hub requests must not be rate-limited.
- No proxy inside the kind node or its tools; no existing process acting as an
  internet proxy on the demo network. This is route-based outage simulation,
  not a hostile multi-tenant or hardware-enforced air gap.
- Docker, kind, Helm, the base OS and pre-staged tool images are part of the
  trusted computing base. The application signature does not attest these tools.

Pinned tool images (Skopeo and Cosign **need not be installed on the host**):

| Tool | Image |
| --- | --- |
| Skopeo | `quay.io/skopeo/stable:v1.20.0` |
| Cosign | `ghcr.io/sigstore/cosign/cosign:v2.4.3` |
| zot | `ghcr.io/project-zot/zot-linux-amd64:v2.1.15` |
| Kubernetes | `kindest/node:v1.35.0` |
| Helm chart | `oci://registry-1.docker.io/bitnamicharts/nginx:22.0.11` |

These are version tags, not immutable tool-image pins. For production, pin
verified tool digests and attest your bootstrap environment too.

## One command, one terminal

From the **demo-bundle directory**:

```bash
cd demo-bundle
./run-demo.sh
```

To first demonstrate tamper rejection and then deploy the untouched bundle:

```bash
./run-demo.sh --tamper
```

Each phase clears the interactive terminal and prints a banner. Press Enter at
phase boundaries so the audience can read the evidence before the next clear.
No second terminal, manual internet toggle, port-forward, or existing Kubernetes
context is needed. The wrapper cleans up its cluster, registry and storage on
success, failure, Ctrl-C or termination.

For a timed, unattended rehearsal:

```bash
time DEMO_AUTO_ADVANCE=1 ./run-demo.sh --tamper
```

The wrapper enforces a **six-minute total elapsed-time budget including cleanup**.
Presenter pauses count toward it. Tool-image downloads and initial kind node
extraction are the variable costs: pre-stage the images before the talk:

```bash
docker pull quay.io/skopeo/stable:v1.20.0
docker pull ghcr.io/sigstore/cosign/cosign:v2.4.3
docker pull ghcr.io/project-zot/zot-linux-amd64:v2.1.15
docker pull kindest/node:v1.35.0
```

## Walk through the phases manually

These commands all run in the **same terminal** and leave the target alive
until explicit cleanup:

```bash
cd demo-bundle
./scripts/build-bundle.sh
./scripts/prepare-target.sh
./scripts/verify-import.sh --trusted-key "$PWD/keys/cosign.pub"
./scripts/cleanup.sh
```

### 1. Connected build: download, inventory, sign, archive

```bash
./scripts/build-bundle.sh
```

The first run creates `keys/cosign.key`, `keys/cosign.pub` and a randomly
generated `keys/password`. The key directory is private, generated files are
gitignored, and the password/private key are **never added to the archive**.
Subsequent builds reuse this temporary demo identity and verify the keypair
matches; they do not silently rotate the trust anchor.

The equivalent download/signing operations are:

```bash
helm pull oci://registry-1.docker.io/bitnamicharts/nginx --version 22.0.11
skopeo copy --override-os linux --override-arch amd64 \
  docker://docker.io/nginx:latest dir:images/nginx
cosign sign-blob --yes --tlog-upload=false --key keys/cosign.key \
  --output-signature metadata.sig metadata.json
```

The scripts run Cosign/Skopeo in containers, so no host install is required.
Signing also runs with no network. The random key password is passed through
the environment, not printed or put in the command line.

Archive layout:

```text
bundle.tar.gz
  charts/nginx-22.0.11.tgz       # includes the common chart dependency
  images/nginx/manifest.json
  images/nginx/<config/layer blobs>
  images/nginx/version
  keys/cosign.pub               # public key ONLY
  values.yaml                  # official-image compatibility settings
  metadata.json                # source, platform, resolved digest, file hashes
  metadata.sig                 # detached signature of metadata.json
```

Expected (image digests vary as `latest` changes):

```text
1 / CONNECTED: pull chart and image; sign the complete inventory
Pulled: registry-1.docker.io/bitnamicharts/nginx:22.0.11
Copying blob sha256:...
Wrote signature to file /bundle/metadata.sig
BUNDLE: .../demo-bundle/bundle.tar.gz
TRUST OUT OF BAND: copy keys/cosign.pub separately to the target.
```

Use `tar -tzf bundle.tar.gz` to inspect the transport contents. To take it to a
separate, already-prepared offline host, transfer this archive and the demo
scripts/configurations, but **do not copy the private key/password**. Deliver
the trusted public key independently. This is an **application bundle**, not a
bootable OS/Kubernetes distribution; the target's tooling/Kubernetes must
already be provisioned, as with a real managed air-gapped cluster.

### 2. Pre-provision infrastructure, then declare the target offline

```bash
./scripts/prepare-target.sh
```

This is infrastructure preparation, **not part of offline verification**:

- Preload missing tool/node images while connected.
- Create a single-node kind cluster on its own Docker network using only the
  local node image. kind's packaged control-plane, CNI, DNS, pause and storage
  images supply Kubernetes' bootstrap dependencies.
- Copy the host Helm executable into the target.
- Remove the node's default IPv4 route; require there is no default IPv6 route.
  The change is entirely inside the disposable node's namespace:

```bash
docker exec offline-bundle-demo-control-plane ip -4 route del default
```

The node keeps its local Docker-network address, so Kubernetes, pod networking
and the host's loopback management mappings continue working. Unlike attaching
a different network, this does not invalidate API certificates or node IPs.
No host routes, firewall rules, daemon configuration or existing kubeconfig
are changed. A private kubeconfig is stored under the gitignored `.state/`.

Expected:

```text
2 / TARGET: provision Kubernetes, then cut its internet route
OFFLINE: target has no IPv4/IPv6 default route; host networking is unchanged.
NAME                                STATUS   ROLES
offline-bundle-demo-control-plane   Ready    control-plane
Infrastructure is pre-staged; all following supply-chain steps are offline.
```

Do **not** run this preparation step on a genuinely offline host expecting it
to download dependencies. Pre-provision first, or independently transport the
tool/node images using `docker save` / `docker load`.

### 3. Receive, safely extract, authenticate and check every file

```bash
./scripts/verify-import.sh --trusted-key "$PWD/keys/cosign.pub"
```

The script refuses a target with a default route or unexpected network
attachment, and refuses missing local tools instead of downloading them.

Before extraction it rejects unsafe archive names, traversal, duplicate
members, links, device/special files and payloads over **1 GiB**. Extraction
uses a private temporary directory without restoring archive ownership or
elevated permissions. Archive scans/extraction also have bounded timeouts. Then:

```bash
cosign verify-blob --offline --insecure-ignore-tlog \
  --key /trusted/cosign.pub --signature metadata.sig metadata.json
```

Verification has **no network** and mounts only the extracted archive and the
independent public key read-only. The private key/password are not accessible.
Every payload hash must match, and the signed file set must equal the actual
file set: missing files and unsigned extras are rejected. Only then can the
script start the registry, import content or execute Helm templates.

Expected:

```text
3 / AIR GAP: receive the archive and verify its signed inventory
Verified OK
VERIFIED: publisher signature (no network or transparency-log lookup).
VERIFIED: all chart, values, public-key and image files match the signed inventory.
```

Cosign prints a warning about skipping transparency-log verification. This is
intentional: the key-based demo signs with `--tlog-upload=false` and explicitly
trusts the enrolled key. It demonstrates authenticity/integrity **without**
Fulcio, Rekor or OIDC access. It does not provide transparency-log inclusion,
trusted timestamps, keyless identity verification or offline key revocation.

### 4. Local registry import, still offline

The script starts zot with [registry/config.yml](registry/config.yml), which has
**no upstream proxy/sync**. zot shares the node's isolated network namespace
and listens on `localhost:5001`; Skopeo and the node's containerd see exactly
that same loopback endpoint. kind maps it to host loopback for optional
inspection. It is not the unrelated `localhost` of a Kubernetes pod.

A direct Skopeo Docker Hub request must fail with a recognized network error:

```text
4 / IMPORT: start a local-only zot and load the verified image
Proving a direct Docker Hub request is impossible from the target...
... connect: network is unreachable
```

Authentication failures, rate limits and missing images are not accepted as
outage proof. The actual offline import is:

```bash
skopeo copy --preserve-digests --dest-tls-verify=false \
  dir:images/nginx docker://localhost:5001/nginx:latest
```

Every blob comes from the bundle, not a remote registry or daemon image store.
The imported raw manifest must still hash to the authenticated image digest.

```text
IMPORTED: localhost:5001/nginx:latest (sha256:...)
```

### 5. Helm deployment and an HTTP response

The chart and values are copied into the isolated node. Helm runs there using
the node's kubeconfig:

```bash
helm upgrade --install offline-nginx /offline-bundle/nginx.tgz \
  --namespace offline-bundle --create-namespace \
  -f /offline-bundle/values.yaml \
  --set image.registry=localhost:5001 \
  --set image.digest=sha256:<authenticated-manifest-digest> \
  --wait --timeout 90s
kubectl -n offline-bundle get pods -o wide
kubectl -n offline-bundle exec deployment/offline-nginx -- \
  curl -fsS http://127.0.0.1:8080/
```

The first deployment uses a fresh kind node with **no preloaded nginx image**;
containerd must pull it from zot. `imagePullPolicy: Always` also requires the
registry on repeats, although existing layers can then be reused. The script
checks the actual Deployment image digest, available replica, HTTP welcome
page and continued absence of a default route.

```text
5 / DEPLOY: local Helm chart, verified digest, no external pulls
NAME                            READY   STATUS    RESTARTS
offline-nginx-...                1/1     Running   0
PASS: signature, every payload hash and imported image digest verified offline.
PASS: Helm deployed the official nginx image by authenticated digest; pod is Ready.
PASS: HTTP returned Welcome to nginx!; target still has no default route.
```

**Chart compatibility matters:** `bitnami/nginx` expects Bitnami paths, its
entrypoint and a Bitnami-specific log-preservation init container. Merely
overriding the registry does not work with Docker Hub's official nginx image.
The authenticated [values.yaml](values.yaml) disables that default init
container, bypasses the Bitnami entrypoint and supplies a minimal nginx config.
nginx runs as UID/GID **101**, listens on **8080**, writes temporary state only
to `/tmp`, keeps a **read-only root filesystem** and drops capabilities.

`global.security.allowInsecureImages=true` disables the chart's vendor-image
allowlist, **not** our cryptographic verification. Helm prints a substitution
warning as expected. Optional Git-cloning and metrics containers stay disabled,
so there are no extra application images or chart dependencies to fetch.
This compatibility override is a demonstration, not a general replacement for
all of the vendor chart's features.

### 6. Cleanup and repeatability

The wrapper automatically runs:

```bash
./scripts/cleanup.sh
```

Manual cleanup is safe to repeat. Registry/container/volume/network ownership
is checked before removal, and the cluster's container ID must match the
locally recorded demo identity. Unrelated projects are not touched.

The bundle, temporary signing identity and preloaded tool images are retained.
Everything generated is gitignored. To discard the demo identity after the
talk, first clean up, then delete only these named local files:

```bash
rm -f keys/cosign.key keys/cosign.pub keys/password
```

The next build generates a new identity; previously enrolled keys must be
updated deliberately. Do not use this local demo key/password pattern for
production signing; use managed keys or hardware-backed signing.

## Negative test: tampered image

With a prepared target:

```bash
./scripts/verify-import.sh --trusted-key "$PWD/keys/cosign.pub" --tamper
```

This modifies only the **temporary extracted image manifest**, not the signed
inventory, original bundle, source image or key. The publisher's inventory
signature is still valid, but the image file hash no longer matches it:

```text
Verified OK
TAMPER: modifying the transported image manifest, not the original archive.
REJECTED: authenticated SHA-256 mismatch: images/nginx/manifest.json
```

The command returns **42** before registry import or deployment. That is an
expected negative test, not a successful install. Altering a layer, chart or
deployment values is rejected by the same check. Altering the inventory itself
fails Cosign verification. Using a different key fails authentication.

`./run-demo.sh --tamper` expects exactly exit 42 for this test, then runs
verification/import/deployment against the unchanged archive. Any other
failure is surfaced rather than misreported as detected tampering.

## Security scope

- The signature authenticates **this publisher's captured bytes**, not the
  upstream publisher's identity or the absence of vulnerabilities. No upstream
  provenance, SBOM analysis or malware scanning is claimed.
- Hashes and the manifest digest prevent payload/tag substitution. They do not
  stop replay of an older correctly signed bundle; real environments also need
  version policy, trusted time, key rotation and revocation procedures.
- This is **verify-before-import**, not Kubernetes admission enforcement.
  Registry-native signatures are not pushed, and no admission controller
  automatically verifies future workloads. The script's verified digest is
  the deployment trust boundary.
- Registry HTTP without auth is deliberate for an isolated, short-lived demo.
  Host exposure is loopback-only, but peers on the Docker network can reach
  it. Production needs TLS, authentication, restricted writes and access policy.
- Route removal proves an ordinary target process cannot reach internet
  addresses; Docker DNS can still resolve names through the host. Privileged
  host/container administrators could restore routes or proxy traffic.
  The default-route and direct-request checks are evidence of the simulated
  outage, not a claim of a hardware-enforced physical air gap.

## Validation and troubleshooting

From the demo-bundle directory:

```bash
for script in run-demo.sh scripts/*.sh; do bash -n "$script"; done
shellcheck -x -P scripts run-demo.sh scripts/*.sh
DEMO_AUTO_ADVANCE=1 ./run-demo.sh --tamper
```

To inspect a manual run while it is still alive:

```bash
docker exec offline-bundle-demo-control-plane ip route
docker exec offline-bundle-demo-control-plane kubectl \
  --kubeconfig /etc/kubernetes/admin.conf -n offline-bundle get pods -o wide
docker logs --tail 30 offline-bundle-registry
```

For a Helm failure the script prints pods and Kubernetes events. Check port
5001 conflicts, available RAM/disk and kind compatibility. Docker Hub `429`
errors are connected-side rate limiting, not successful offline verification.
If interrupted with an uncatchable signal, run cleanup manually. A target
ownership mismatch requires investigation, not deleting an unrelated cluster.
For archive/key failures, re-transfer the signed archive and confirm the
independent trust anchor; **never skip verification to make deployment pass**.

### Recorded end-to-end results

Tested on 2026-10-16: Linux amd64, Docker 29.9.0, kind v0.31.0, Helm v4.3.0,
Kubernetes v1.35.0 and the pinned tools/chart above.

| Check | Result |
| --- | --- |
| Single-command build, negative test, isolated import, Helm deploy, cleanup | **39 seconds**, with tool/node images preloaded |
| Target direct Docker Hub access | Rejected with `network is unreachable` |
| Tampered transported image manifest | Rejected with exit 42, before import |
| Tampered layer, chart archive or deployment values | Each rejected with exit 42 |
| Altered signed inventory or different valid signing key | Cosign rejected authentication |
| Unsigned extra file, archive symlink or path traversal | Each rejected before registry startup |
| Private signing key and password | Absent from transport archive; gitignored |
| Inventory signature and all image/chart/value hashes | Verified with network disabled for Cosign |
| Imported manifest digest | Identical to authenticated bundle digest |
| Fresh-node Helm deployment | **1/1 Running**, official nginx image by digest |
| Application response | `Welcome to nginx!` |
| Target network after deployment | No default IPv4 or IPv6 route |
| Repeated preparation, import and Helm upgrade | Passed while target remained isolated |
| Wrapper in a real pseudo-terminal, including clears and banners | Passed; **39 seconds** including cleanup |
| Shell syntax and ShellCheck | Passed |

The six-minute target assumes pre-staged infrastructure images, a working kind
host and normal connected-side chart/image download bandwidth. Cold tool
downloads or presenter pauses can exceed it; rehearse on the talk machine.
