# Taking cloud-native offline: a pull-through cache

This single-terminal demo runs [zot](https://zotregistry.dev/v2.1.15/articles/mirroring/)
as an on-demand proxy for Docker Hub's official `nginx:latest`. The first request
fetches from Docker Hub. An explicit **cache-only mode** freezes cached tags
before the outage; the second copies **all layers to a fresh client while both
the client and zot have no internet route**. No host firewall rules, daemon
configuration, Kubernetes cluster, or second terminal are needed.

## Important: cached `latest` is not automatically instant offline

zot v2.1.15 attempts an upstream refresh when resolving a **tag**, even if that
tag is already cached. In testing, leaving proxy mode enabled while disconnecting
the uplink made `nginx:latest` stall beyond the client's 90-second timeout.
The cache contains the data, but tag freshness checks can still block access.
This demo does **not** claim automatic, instantaneous fallback for mutable tags.

The chosen offline policy is explicit: before disconnecting, verification
recreates zot using `zot-offline-config.json`, which has no sync extension but
uses the **same persistent volume**. No images are re-downloaded, copied into a
different repository or pushed manually. Cached `nginx:latest` now resolves
locally without an upstream check. This is a short registry restart, not a
zero-downtime failover. On exit the script restores the online proxy config.

In production, choose and rehearse this cache-only transition, or use primed
immutable digests (which zot can serve locally without a tag refresh). Merely
installing a proxy does not eliminate every online dependency.

## Prerequisites and assumptions

- A Linux **amd64** Docker engine (native Linux or Docker Desktop's Linux engine),
  Docker CLI and Compose v2+; permission to use Docker without `sudo`.
  The zot image is architecture-specific; this demo deliberately targets amd64.
- Bash 4+, `curl`, `jq`, GNU `timeout`, `sha256sum`, `cut`, `grep`, and `clear`
  (normally included on Linux; on macOS install Bash, coreutils and jq and make
  GNU `timeout` available under that name).
- Port **127.0.0.1:5000** free; approximately 2 GB free Docker storage.
- Initial access to GHCR, Quay, Docker Hub, its authentication service and layer
  CDN. Anonymous Docker Hub pulls must not be rate-limited.
- No corporate proxy is configured inside these containers. Host proxy variables
  are not passed to Skopeo. Docker's image-download proxy can still be used.
- Run only one copy of this demo per Docker engine: the project name is fixed
  to `offline-cache-demo`.

Skopeo is supplied by the pinned `quay.io/skopeo/stable:v1.20.0` tools service;
you **do not need to install Skopeo on the host**. zot is pinned to v2.1.15.
Container tools share zot's network namespace, so `localhost:5000` means the
same registry from inside the client and, while the uplink is attached, from
your terminal. Docker withdraws the host's published port when the last
external network is disconnected. During isolation, the scripts reach
`localhost:5000` **inside the client namespace**; host access returns on restore.

## Run the talk, in one terminal

From the repository root:

```bash
cd demo-cache
./scripts/start-cache.sh
./scripts/prime-cache.sh
./scripts/verify-cache.sh
./scripts/stop-cache.sh
```

Run each command when ready to advance your narration. Each phase clears an
interactive terminal and prints a banner; redirected/non-interactive output
retains every phase. Verification pauses for Enter after the direct pull failure
so the audience can read it before the next clear. No manual network changes or
extra terminal are needed.

For a timed, unattended rehearsal in the same terminal:

```bash
time DEMO_AUTO_ADVANCE=1 bash -c './scripts/start-cache.sh && ./scripts/prime-cache.sh && ./scripts/verify-cache.sh && ./scripts/stop-cache.sh'
```

Allow **under five minutes** on a normal broadband connection, excluding audience
pauses. First-use tool downloads dominate; preload them before the talk:

```bash
docker compose --profile tools pull
```

To demonstrate a genuine **cold** cache after a previous run, explicitly delete
only this demo's stored images before starting again:

```bash
./scripts/stop-cache.sh --purge
```

### 1. Start the cache

```bash
./scripts/start-cache.sh
```

Expected:

```text
1 / START: pull-through registry on localhost:5000
READY: http://localhost:5000/v2/
Persistent storage: Docker volume mounted at /var/lib/zot
```

Startup downloads missing tools, starts zot, restores the demo uplink if needed,
and waits for `/v2/`. Startup fails explicitly on missing dependencies, occupied
ports, unsupported architecture or registry failure.

### 2. Prime through the cache, then inspect storage

```bash
./scripts/prime-cache.sh
```

The actual client operation is:

```bash
docker compose run --rm --no-deps -T skopeo --command-timeout 90s \
  copy --src-tls-verify=false \
  docker://localhost:5000/nginx:latest dir:/tmp/nginx-online
```

This is a pull **from** zot, not a push/upload into it. The sync configuration
maps local `nginx` to Docker Hub's `library/nginx`. Only this repository is
eligible for on-demand sync, with no polling or retry delay.

Expected (digests, file counts and sizes vary with `latest`):

```text
2 / PRIME: request nginx:latest THROUGH zot
Getting image source signatures
Copying blob sha256:...
Copying config sha256:...
Writing manifest to image destination
Cached tags:
[
  "latest"
]
Local OCI storage ...
/cache/nginx/blobs/sha256/...
PRIMED: manifests and layer blobs are stored locally.
```

The script checks the OCI index and lists actual blob files in zot's persistent
Docker volume and its size. The minimal zot image has no shell utilities, so
the tooling container mounts the same volume **read-only** at `/cache`.
You can also inspect them manually, before stopping:

```bash
curl --noproxy '*' -fsS http://localhost:5000/v2/nginx/tags/list | jq .
docker compose run --rm --no-deps -T --entrypoint /bin/sh skopeo \
  -c 'find /cache -type f; du -sh /cache'
docker compose logs --tail 30 zot
```

Skopeo's directory output is disposable: its container exits and is removed.
zot's named volume is the **only persistent image cache used by this demo**.
The Docker engine stores the tool images, not the nginx image being tested.

### 3. Lose internet; prove a direct Docker Hub request fails

```bash
./scripts/verify-cache.sh
```

First the script checks that Docker Hub is reachable online, then records the
cached manifest's SHA-256. It explicitly switches to cache-only mode, retaining
the volume, and waits for the registry to become ready:

```bash
ZOT_CONFIG=./zot-offline-config.json docker compose up -d zot
```

It then disconnects zot's `uplink` network:

```bash
docker network disconnect offline-cache-demo_uplink "$(docker compose ps -q zot)"
```

zot and its Skopeo client retain only the **internal** Docker network. Your host
and unrelated containers retain internet access. The script checks every
remaining network is internal before proceeding.

The offline direct request is:

```bash
docker compose run --rm --no-deps -T skopeo --command-timeout 8s \
  inspect --raw docker://docker.io/library/nginx:latest
```

Expected:

```text
3 / OFFLINE: cut internet for BOTH zot and its pull client
Switching to CACHE-ONLY mode: no upstream tag refresh; same stored blobs.
ISOLATED: only the internal Docker network remains; the host is unaffected.
... network is unreachable ...
EXPECTED FAILURE: direct Docker Hub access is unavailable.
```

The exact network error can instead be a DNS failure or deadline exceeded.
Authentication failures, rate limits, missing images, Compose failures and
unexpected success **do not pass** this check. `inspect --raw` contacts Docker
Hub without consulting any Docker daemon image cache; failure to obtain its
manifest means a direct image pull cannot succeed.

### 4. Pull from localhost with no internet

The same verification script immediately runs:

```bash
docker compose run --rm --no-deps -T skopeo --command-timeout 90s \
  copy --src-tls-verify=false \
  docker://localhost:5000/nginx:latest dir:/tmp/nginx-offline
```

Expected:

```text
4 / CACHE HIT: pull ALL nginx layers with no internet
Copying blob sha256:...
Writing manifest to image destination
PASS: a fresh client copied every layer from localhost:5000 in 2s (<15s).
PASS: online/offline manifest SHA-256 matches: ...
PASS: registry API remained reachable inside the isolated client namespace.
Restoring proxy mode and the demo uplink...
```

Elapsed time varies by machine; **15 seconds is a tested assertion**, not a
claim of zero transfer time. Every layer must transfer locally. Comparing the
raw manifest before/after also proves the tag did not change during the outage.
The script automatically restores proxy mode and the uplink on success, error,
Ctrl-C or termination, equivalent to:

```bash
ZOT_CONFIG=./zot-config.json docker compose up -d zot
```

After an uncatchable interruption (for example `kill -9`), recover:

```bash
./scripts/start-cache.sh
```

### 5. Stop or reset

```bash
./scripts/stop-cache.sh
```

Normal shutdown preserves the cache. Re-running any script is safe; priming a
warm cache just copies the already-stored image. Explicitly remove the demo's
volume for another cold rehearsal:

```bash
./scripts/stop-cache.sh --purge
```

Both shutdown commands are safe to repeat. Neither removes downloaded tool
images or modifies unrelated Docker projects.

## Scope and production caveats

- This is registry caching, not a complete air-gap supply chain. Uncached
  images still need upstream access; prime every required image/platform first.
  Skopeo exercises the client's native amd64 image, not every platform.
  zot may store the complete upstream multi-platform index and its images;
  the tested nginx cache occupied approximately 490 MiB.
- `latest` is deliberately used for the talk. Proxy mode attempts tag refreshes;
  cache-only mode deliberately freezes tags. For reproducible deployments,
  pin digests and explicitly plan updates before going offline.
- HTTP and no authentication are intentional **local-demo-only** choices.
  The host port is loopback-bound; Docker peers on attached networks can also
  access zot. Production needs TLS, authentication and access controls.
- Optional Helm/Kubernetes deployment is deliberately excluded from the timed
  flow. A registry override alone is **not** enough for `bitnami/nginx`: that
  chart expects Bitnami's image layout, entrypoint and security settings, not
  Docker Hub's official `nginx:latest`. A real offline chart demo also needs a
  locally downloaded chart, all dependency images, and a registry address
  reachable **from the cluster nodes** (node `localhost` is not your host).
  The demo proves the cached image is available without making a misleading
  chart compatibility claim.

## Troubleshooting and validation

```bash
for script in scripts/*.sh; do bash -n "$script"; done
shellcheck -x -P scripts scripts/*.sh          # optional, if installed
docker compose --profile tools config --quiet
docker compose logs --tail 100 zot
```

For bind errors, free port 5000. For upstream `429`/authentication errors, resolve
Docker Hub access/rate limits before the talk; do not treat them as proof of an
outage. For namespace/network errors, stop then start the demo. If the offline
copy exceeds 15 seconds, check local Docker storage/CPU load and rehearse again.
All network work is bounded by timeouts, but slow first-use downloads can still
make a cold setup unsuitable for a five-minute slot: preload the tool images.

### Recorded end-to-end results

Tested on 2026-10-16 with a Linux amd64 Docker engine, Docker 29.9.0,
Compose v5.6.0 and the pinned container tools above:

| Check | Result |
| --- | --- |
| Cold image cache, tools preloaded: start, prime, verify, stop | 15.2 seconds total |
| Offline full-image copy to a fresh client | 2 seconds, below the enforced 15-second limit |
| Direct Docker Hub request with uplink detached | Failed with a DNS/network error, as required |
| Cached manifest fingerprint before/after isolation | Identical |
| Repeated start, prime, verify and stop; retained volume after restart | Passed |
| Verification before priming | Failed explicitly with a priming instruction |
| SIGTERM during the cache-only transition | Exit 143; proxy configuration and host API restored |
| Repeated explicit volume purge | Passed |
| Bash syntax, ShellCheck and Compose configuration validation | Passed |

Timings exclude tool-image downloads and presenter pauses. Docker and upstream
image sizes vary; rehearse on the presentation machine and connection.
