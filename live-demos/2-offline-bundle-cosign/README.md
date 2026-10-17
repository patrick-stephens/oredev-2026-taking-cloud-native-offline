# Taking cloud-native offline: a signed PostgreSQL bundle

| Spectrum level | Demo app | Headline tooling | Status |
|----------------|----------|------------------|--------|
| 3–4 | postgres | skopeo, cosign, helm, zot | 🚧 WIP |

Signed bundle → verify → import → deploy a stateful workload offline

[Offline spectrum](../../docs/offline-spectrum.md) · [Top-level README](../../README.md)

A **single-terminal** demonstration of an offline software supply chain:

1. CONNECTED: **package our own Helm chart**, capture the official PostgreSQL
   image and sign an inventory of every transported file.
2. AIR-GAPPED: verify with an independently trusted public key, import into
   local zot, and deploy the chart using the **authenticated image digest**.
3. Prove the pod is **Running/Ready**, its PVC **Bound**, and **psql connects
   using a password over TCP**. Reject a tampered image before importing it.

There is **no Bitnami chart or image dependency**. This avoids the
[2025 Bitnami catalog migration](https://github.com/bitnami/containers/issues/83267)
and demonstrates that `helm package` is useful for your own offline delivery.
The small [chart](chart/) wraps the official `postgres` image, uses an existing
Secret, and asks the default StorageClass for a PVC. It is not an HA database
operator or a production backup/upgrade solution.

## Architecture and trust boundary

```text
CONNECTED BUILD SIDE                         AIR-GAPPED TARGET

chart/ (self-authored, no dependencies)        Pre-provisioned kind node
  helm package -> charts/*.tgz                 (internet default routes removed)
Docker Hub: postgres:18.6-alpine3.23                        |
  skopeo copy -> images/postgres/                          |
                  |                                       |
SHA-256 inventory: metadata.json                          |
Cosign sign-blob (private key stays here)                  |
                  |                                       |
                  +-- bundle.tar.gz -- removable media --> safe extraction
                                                          |
TRUSTED PUBLIC KEY -- independent channel ----------------> verify-blob
                                                          + every file hash
                                                          |
                                                verified Skopeo import
                                                          |
                                                zot localhost:5001
                                                          |
                                             Helm -> PostgreSQL@sha256:...
                                             existing Secret + default-SC PVC
                                                          |
                                             Running/Ready, Bound, SQL result
```

For the talk, one Linux host models both machines. The host remains connected
and orchestrates Docker. Target Helm, kubectl, containerd, Skopeo and zot run
inside the isolated kind node's network namespace, or its pods. Cosign
verification runs with Docker `--network none`. No target step downloads
dependencies after the route is removed.

### What is signed

Cosign cannot directly `sign` an unpushed Skopeo `dir:` image. The unchanged
signing flow uses `cosign sign-blob` on `metadata.json`, whose file inventory
authenticates **all image manifests, layers/configs, the packaged chart,
deployment values and public key**. Signing only a manifest would not check
the transported layer bytes. The full file inventory does.

The bundled public key is portable, **not a trust anchor**: an attacker could
replace both payload and key. `--trusted-key` must come from an independent,
authenticated channel. The wrapper models this with the original build-side
public key, outside the archive.

The build selects a version tag but records the **resolved linux/amd64 manifest
digest**. Offline import preserves and checks that digest. Helm deploys
`localhost:5001/postgres@sha256:...`, not the tag; changing a registry tag cannot
silently change the deployed bytes. The digest takes precedence over
`image.tag` in the chart.

## Prerequisites and assumptions

- Native **Linux amd64**, Docker access without sudo and privileged kind support;
  at least 4 CPUs, 6 GiB available RAM and 6 GiB free disk.
- Bash 4+, GNU tar/coreutils (timeout, sha256sum, sort, stat, realpath), jq,
  awk and grep.
- Native standalone Linux amd64 **Helm 3.12+ or 4**, and **kind v0.31.0**.
  Preparation copies Helm into the target; kubectl comes from the node image.
- Free **127.0.0.1:5001**, plus an automatically allocated loopback Kubernetes
  API port. Do not run concurrent copies of this demo.
- Connected-side Docker Hub, GHCR and Quay access, without registry rate limits.
  No chart repository is needed: our chart has no dependencies.
- The target has a working **default StorageClass**; kind provides `standard`
  and its local-path helper image. Preparation waits for the provisioner.
- No internet proxy in the node or another process proxying internet access
  on the demo network. This is a route-based outage simulation, not a hostile
  multi-tenant or physically enforced air gap.

Skopeo and Cosign run as pinned containers, so neither needs a host install.
Tool image tags are version pins, not immutable digest/authenticity guarantees.
Docker, the node image and local tools remain part of the trusted computing base.

## One command, one terminal

From the repository root:

```bash
cd live-demos/2-offline-bundle-cosign
./run-demo.sh --tamper
```

Omit `--tamper` for the positive path only. Interactive phases use `clear`,
banners and Enter pauses; the wrapper removes its target on success, failure,
Ctrl-C or termination. No second terminal, port-forward or manual network
toggle is needed. For an unattended rehearsal:

```bash
time DEMO_AUTO_ADVANCE=1 ./run-demo.sh --tamper
```

The wrapper enforces **under six minutes including cleanup**. Presenter pauses
count. Pre-stage infrastructure images before the talk:

```bash
docker pull quay.io/skopeo/stable:v1.20.0
docker pull ghcr.io/sigstore/cosign/cosign:v2.4.3
docker pull ghcr.io/project-zot/zot-linux-amd64:v2.1.15
docker pull kindest/node:v1.35.0
```

## Step-by-step: CONNECTED

Run these from this directory, in the same terminal.

### 1. Package, capture, inventory and sign

```bash
./scripts/build-bundle.sh
```

Equivalent application operations (the script containerizes Skopeo/Cosign):

```bash
helm lint chart -f values.yaml --strict
helm package chart --destination charts
skopeo copy --override-os linux --override-arch amd64 \
  docker://docker.io/library/postgres:18.6-alpine3.23 dir:images/postgres
cosign sign-blob --yes --tlog-upload=false --key keys/cosign.key \
  --output-signature metadata.sig metadata.json
```

`helm package`, **not `helm pull`**, produces `offline-postgresql-0.1.0.tgz`.
The script constructs and signs the SHA-256 inventory before archiving:

```text
bundle.tar.gz
  charts/offline-postgresql-0.1.0.tgz
  images/postgres/{manifest.json,version,<config-and-layer-blobs>}
  keys/cosign.pub
  values.yaml
  metadata.json
  metadata.sig
```

The first build generates `keys/cosign.key`, `keys/cosign.pub` and
`keys/password` under a private, ignored directory. Subsequent builds reuse and
validate that keypair, not silently rotate it. **The private key and password
are never transported.** Database credentials are not in the bundle either.

Expected:

```text
1 / CONNECTED: package our chart, pull PostgreSQL, sign the complete inventory
1 chart(s) linted, 0 chart(s) failed
Successfully packaged chart ...
Wrote signature to file /bundle/metadata.sig
BUNDLE: .../live-demos/2-offline-bundle-cosign/bundle.tar.gz
TRUST OUT OF BAND: copy keys/cosign.pub separately to the target.
```

The tested archive is approximately **113 MiB**, with 15 authenticated files.
Digest values depend on captured bytes; do not copy a digest from these docs.

### 2. Pre-provision infrastructure, then remove internet access

```bash
./scripts/prepare-target.sh
```

This connected infrastructure step stages tools/node images, creates the kind
node and private kubeconfig, waits for storage, copies Helm, then runs:

```bash
docker exec offline-bundle-demo-control-plane ip -4 route del default
```

Only the disposable node's routes change, not the host's. The script checks
that **neither IPv4 nor IPv6 has a default route**, and the node has exactly
its owned Docker network. kind's packaged CNI, DNS, pause and storage images
are pre-provisioned infrastructure, not transported application dependencies.

```text
OFFLINE: target has no IPv4/IPv6 default route; host networking is unchanged.
```

## Step-by-step: AIR-GAPPED

### 3. Receive and authenticate

```bash
./scripts/verify-import.sh --trusted-key "$PWD/keys/cosign.pub"
```

A real target receives `bundle.tar.gz` and separately enrolls the trusted key.
Before extraction, the script rejects traversal, absolute/unsafe names,
duplicate entries, links, special files and archives expanding beyond **1 GiB**.
Archive scans/extraction have timeouts and use a private temporary directory.
Cosign then runs offline with read-only payload/key mounts:

```bash
cosign verify-blob --offline --insecure-ignore-tlog \
  --key /trusted/cosign.pub --signature metadata.sig metadata.json
```

Every file hash and the **exact file set** must match the authenticated inventory,
including the archived public key matching the independent one. Missing,
changed and unsigned extra files fail **before registry startup or Helm**.

```text
Verified OK
VERIFIED: publisher signature (no network or transparency-log lookup).
VERIFIED: all chart, values, public-key and image files match the signed inventory.
```

Skipping tlog verification is intentional for this key-based demo, which signs
with `--tlog-upload=false`. It provides publisher-key authenticity and payload
integrity, not Rekor inclusion, keyless identity, trusted timestamps or offline
revocation.

### 4. Import only verified bytes

The same script starts zot using [registry/config.yml](registry/config.yml)
with **no upstream sync**. Registry and Skopeo share the node's namespace:
`localhost:5001` is also the address seen by node containerd, not pod loopback.

A direct Hub request must fail with a recognized **network** error, not a
rate-limit/authentication error. Import then reads every blob from disk:

```bash
skopeo copy --preserve-digests --dest-tls-verify=false \
  dir:images/postgres docker://localhost:5001/postgres:18.6-alpine3.23
```

```text
Proving a direct Docker Hub request is impossible from the target...
... connect: network is unreachable
IMPORTED: localhost:5001/postgres:18.6-alpine3.23 (sha256:...)
```

### 5. Deploy, bind storage and authenticate to PostgreSQL

The script creates `offline-bundle` and a random target-side
`offline-postgresql-auth` Secret **before Helm**. It never packages credentials
or prints the password. An existing Secret is reused on upgrades: initializing
a PVC once means changing the environment password later does not rotate the
database password. If a PVC exists but its Secret is missing, restore the
original Secret rather than generating incompatible credentials.

Equivalent operations (inside the target, after transport):

```bash
kubectl -n offline-bundle create secret generic offline-postgresql-auth \
  --from-file=password=/path/to/private/password
helm upgrade --install offline-postgresql /offline-bundle/postgresql.tgz \
  --namespace offline-bundle --create-namespace \
  -f /offline-bundle/values.yaml \
  --set image.registry=localhost:5001 \
  --set image.digest=sha256:<authenticated-manifest-digest> \
  --wait --timeout 90s
kubectl -n offline-bundle get pods,pvc
kubectl -n offline-bundle exec statefulset/offline-postgresql -- sh -ec '
  export PGPASSWORD="$POSTGRES_PASSWORD" PGCONNECT_TIMEOUT=5
  psql --host=127.0.0.1 --username="$POSTGRES_USER" --dbname="$POSTGRES_DB" \
    --no-password --set=ON_ERROR_STOP=1 --tuples-only --no-align \
    --command="SELECT current_database(), current_user, 1;"
'
```

The chart exposes `image.registry`, `image.repository`, `image.tag` and
`image.digest`. Defaults use Docker Hub `library/postgres`; the signed
[deployment values](values.yaml) select repository `postgres` in local zot.
The verifier supplies the authenticated digest. `Always` pull policy requires
the local registry even on repeats.

The StatefulSet has one replica and a 1 GiB RWO claim. **No `storageClassName`
is set**, so the default class provisions it. PostgreSQL 18 data lives at
`/var/lib/postgresql/18/docker`, with the PVC mounted at `/var/lib/postgresql`.
UID/GID **70** matches the official **Alpine** image, capabilities are dropped,
and service-account token mounting is disabled. Changing to Debian images or
another major version needs deliberate UID/data-layout and migration changes.

Startup/readiness probes use `pg_isready`. This alone does **not** prove valid
credentials: the script also requires a TCP `psql` query using the existing
Secret. Initialization explicitly uses **SCRAM-SHA-256** host authentication.
This demo's bootstrap user is a database superuser; production applications
need separate least-privilege roles, backups, TLS and managed secret lifecycle.

Expected:

```text
offline-postgresql-0        1/1   Running
data-offline-postgresql-0   Bound ... 1Gi RWO standard
SQL: demo|demo|1
PASS: signature, every payload hash and imported image digest verified offline.
PASS: Helm deployed official PostgreSQL by authenticated digest; pod is Running/Ready, PVC Bound.
PASS: psql authenticated over TCP using the existing Secret; SQL returned demo|demo|1.
PASS: target still has no IPv4/IPv6 default route.
```

## Tampering

With a prepared target:

```bash
./scripts/verify-import.sh --trusted-key "$PWD/keys/cosign.pub" --tamper
```

This changes only the extracted image manifest, not the archive or inventory.
The inventory signature remains valid, but the file check returns **42**:

```text
TAMPER: modifying the transported image manifest, not the original archive.
REJECTED: authenticated SHA-256 mismatch: images/postgres/manifest.json
```

The wrapper's `--tamper` path requires exactly 42, then deploys the unchanged
bundle. A generic failure is never reported as successful tamper detection.
Changes to layers, chart or values are protected by the same inventory.

## Cleanup and repeatability

The wrapper cleans automatically. Manual phase runs leave the target alive:

```bash
./scripts/build-bundle.sh
./scripts/prepare-target.sh
./scripts/verify-import.sh --trusted-key "$PWD/keys/cosign.pub"
./scripts/verify-import.sh --trusted-key "$PWD/keys/cosign.pub" # upgrade, same Secret/PVC
./scripts/cleanup.sh
./scripts/cleanup.sh
```

Cleanup checks ownership and removes only this cluster, registry, registry
volume and Docker network. **The database data is disposable and is destroyed
with the kind node**; a PVC is persistence across pod restarts, not a backup.
The bundle, keys and preloaded tool images remain locally and gitignored.
After cleanup, optionally remove only the generated signing identity:

```bash
rm -f keys/cosign.key keys/cosign.pub keys/password
```

The next build generates a new identity, requiring deliberate trust re-enrollment.
Do not use this local-key/password pattern for production signing.

## Where network is still required / security limits

- Build-time image/tool downloads and connected infrastructure bootstrap require
  internet. On a truly offline host, independently transport and trust tool/node
  images with `docker save` / `docker load`; do not run preparation expecting
  missing images to download.
- The host remains online. Route removal blocks ordinary external IP access
  from the target, but Docker DNS can still resolve via the host, local peers
  remain reachable, and a privileged administrator could restore a route or
  install a proxy. This is not a zero-packet or physical air-gap claim.
- Registry HTTP without auth is for this short-lived demo. Host publication is
  loopback-only; Docker-network peers can still reach it. Production requires
  TLS, authentication and restricted writes.
- The signature authenticates this publisher's captured bytes, not upstream
  provenance, vulnerability freedom or freshness. No SBOM/scanning, replay
  prevention or Kubernetes admission enforcement is claimed. Future deployments
  do not automatically inherit this script's verify-before-import policy.

## Troubleshooting and validation

```bash
for script in run-demo.sh scripts/*.sh; do bash -n "$script"; done
shellcheck -x -P scripts:. run-demo.sh scripts/*.sh
helm lint chart -f values.yaml --strict
DEMO_AUTO_ADVANCE=1 ./run-demo.sh --tamper
```

- **Chart requires a Secret:** set `auth.existingSecret` when using the chart
  directly; it intentionally does not create or embed a password.
- **PVC Pending:** check the default StorageClass, provisioner, helper image and
  node disk pressure. Helm failures print pods, PVCs and events. Do not enable
  internet to compensate for missing pre-staged infrastructure.
- **Password authentication failed on an existing PVC:** restore its original
  Secret; changing `POSTGRES_PASSWORD` is not a database password migration.
- **ImagePullBackOff:** check zot logs and the authenticated digest; pod loopback
  is not the registry endpoint used by node containerd.
- **Port conflict, kind/bootstrap failure:** free port 5001 and check Docker,
  RAM/disk and privileged-container support. A Hub 429 is a connected failure.
- **Signature/archive failure:** re-transfer and verify the independent key,
  never bypass checks. Ownership mismatches require investigation.
- **Uncatchable interruption:** run cleanup explicitly.

## Tested with

Test date: **2026-10-16**, native Linux amd64:

| Component | Exact version |
| --- | --- |
| Docker engine | 29.9.1 |
| kind / Kubernetes node | v0.31.0 / kindest/node:v1.35.0 |
| Helm | v4.3.0 |
| Skopeo | quay.io/skopeo/stable:v1.20.0 |
| Cosign | ghcr.io/sigstore/cosign/cosign:v2.4.3 |
| zot | ghcr.io/project-zot/zot-linux-amd64:v2.1.15 |
| Official PostgreSQL | docker.io/library/postgres:18.6-alpine3.23 |
| Self-authored chart | offline-postgresql 0.1.0 |

**Full fresh run: 59 seconds**, including connected packaging/image capture,
tamper rejection, isolated import, Running/Ready pod, Bound PVC, authenticated
TCP SQL query and cleanup, with tool/node images preloaded. Cold downloads and
presenter pauses vary; rehearse on the talk machine.

Additional checks passed:

- **6-second repeat** of preparation, verified import and Helm upgrade, retaining
  the same Secret, PVC and database contents.
- SQL data survived deletion and offline replacement of the database pod.
- A deliberately wrong TCP password was rejected.
- Modified image manifest/blob, chart and values were rejected with exit 42;
  modified inventory failed Cosign verification.
- Private credentials were absent from the archive.
- Bash syntax, ShellCheck and Helm lint passed. Render checks confirmed digest
  precedence, default-StorageClass behavior, and rejection of a missing Secret
  name or malformed digest.
- Cleanup left no demo target containers; repeat cleanup succeeded.
