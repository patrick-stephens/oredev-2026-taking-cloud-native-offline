#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../config/base-images.env
source "$ROOT/config/base-images.env"

NETWORK=dependency-mirrors-verdaccio
CONTAINER=dependency-mirrors-verdaccio
VOLUME=dependency-mirrors-verdaccio-storage
PROJECT="$ROOT/.work/verdaccio-client"
HOST_UID="$(id -u)"
HOST_GID="$(id -g)"
START_SECONDS=$SECONDS
CONTAINER_STARTED=0
NETWORK_CREATED=0
VOLUME_CREATED=0

cleanup() {
    local status=$?
    if (( status != 0 )) && (( CONTAINER_STARTED )); then
        docker logs "$CONTAINER" >&2 || true
    fi
    if (( CONTAINER_STARTED )); then
        docker rm --force "$CONTAINER" >/dev/null
    fi
    if (( NETWORK_CREATED )); then
        docker network rm "$NETWORK" >/dev/null
    fi
    if (( VOLUME_CREATED )); then
        docker volume rm "$VOLUME" >/dev/null
    fi
    rm -rf -- "$PROJECT"
    rm -f -- "$ROOT/.work/verdaccio-htpasswd" "$ROOT/.work/verdaccio.npmrc"
    exit "$status"
}
trap cleanup EXIT

if [[ ! -d "$ROOT/artifacts/verdaccio/packages" ]] ||
    ! find "$ROOT/artifacts/verdaccio/packages" -maxdepth 1 -type f -name '*.tgz' -print -quit | grep -q .; then
    echo 'Missing packed npm artifacts; run ./scripts/run-demo.sh first.' >&2
    exit 1
fi
for image in "$NODE_IMAGE" "$VERDACCIO_IMAGE"; do
    if ! docker image inspect "$image" >/dev/null 2>&1; then
        printf 'Image is not present locally: %s\nPull it during the CONNECTED phase first.\n' "$image" >&2
        exit 1
    fi
done
for resource in \
    "$(docker container inspect "$CONTAINER" --format '{{.Id}}' 2>/dev/null || true)" \
    "$(docker network inspect "$NETWORK" --format '{{.Id}}' 2>/dev/null || true)" \
    "$(docker volume inspect "$VOLUME" --format '{{.Name}}' 2>/dev/null || true)"
do
    if [[ -n "$resource" ]]; then
        echo 'A resource from a previous Verdaccio stretch run still exists; clean it before retrying.' >&2
        exit 1
    fi
done

rm -rf -- "$PROJECT"
mkdir -p "$PROJECT"
cp -a "$ROOT/apps/node-express/." "$PROJECT/"
mkdir -p "$ROOT/.work"
REGISTRY_PASSWORD="$(docker run --rm "$NODE_IMAGE" node -e \
    'process.stdout.write(require("node:crypto").randomBytes(24).toString("hex"))')"
REGISTRY_HASH="$(printf '%s\n' "$REGISTRY_PASSWORD" | docker run --rm --interactive \
    "$VERDACCIO_IMAGE" node -e \
    'const fs=require("node:fs");const bcrypt=require("/usr/local/lib/node_modules/verdaccio/node_modules/bcryptjs");process.stdout.write(bcrypt.hashSync(fs.readFileSync(0,"utf8").trim(),10))')"
NPM_AUTH="$(printf 'offline-demo:%s' "$REGISTRY_PASSWORD" | base64 --wrap=0)"
printf 'offline-demo:%s\n' "$REGISTRY_HASH" >"$ROOT/.work/verdaccio-htpasswd"
printf 'registry=http://verdaccio:4873/\n//verdaccio:4873/:_auth=%s\n//verdaccio:4873/:always-auth=true\n' \
    "$NPM_AUTH" >"$ROOT/.work/verdaccio.npmrc"
chmod 600 "$ROOT/.work/verdaccio-htpasswd" "$ROOT/.work/verdaccio.npmrc"
chmod 644 "$ROOT/.work/verdaccio-htpasswd"

echo '=== OPTIONAL STRETCH: INTERNAL VERDACCIO MIRROR ==='
docker network create --internal \
    --label org.oredev.demo=dependency-mirrors "$NETWORK" >/dev/null
NETWORK_CREATED=1
docker volume create --label org.oredev.demo=dependency-mirrors "$VOLUME" >/dev/null
VOLUME_CREATED=1
docker run --detach \
    --name "$CONTAINER" \
    --label org.oredev.demo=dependency-mirrors \
    --network "$NETWORK" \
    --network-alias verdaccio \
    --mount "type=bind,src=$ROOT/config/verdaccio.yaml,dst=/verdaccio/conf/config.yaml,readonly" \
    --mount "type=bind,src=$ROOT/.work/verdaccio-htpasswd,dst=/verdaccio/conf/htpasswd,readonly" \
    --mount "type=volume,src=$VOLUME,dst=/verdaccio/storage" \
    "$VERDACCIO_IMAGE" >/dev/null
CONTAINER_STARTED=1

docker run --rm --network "$NETWORK" "$NODE_IMAGE" node -e '
const wait = async () => {
  for (let attempt = 0; attempt < 60; attempt++) {
    try {
      const response = await fetch("http://verdaccio:4873/-/ping");
      if (response.ok) return;
    } catch {}
    await new Promise((resolve) => setTimeout(resolve, 1000));
  }
  throw new Error("Verdaccio did not become ready on the internal network");
};
wait().catch((error) => { console.error(error); process.exit(1); });
'

echo 'Network policy: Verdaccio and its npm client share a Docker --internal network.'
docker network inspect "$NETWORK" --format '{{if .Internal}}internal=true{{else}}internal=false{{end}}' |
    grep -qx 'internal=true'
docker run --rm --network "$NETWORK" "$NODE_IMAGE" node -e '
const socket = require("node:net").createConnection({ host: "1.1.1.1", port: 443 });
socket.setTimeout(2000);
socket.on("connect", () => {
  console.error("Unexpected external TCP connection from the internal Docker network.");
  process.exit(1);
});
socket.on("error", () => process.exit(0));
socket.on("timeout", () => { socket.destroy(); process.exit(0); });
'
echo 'External egress check: blocked; only the local registry is reachable.'
docker run --rm \
    --user "$HOST_UID:$HOST_GID" \
    --network "$NETWORK" \
    -v "$ROOT/artifacts/verdaccio/packages:/packages:ro" \
    -v "$ROOT/.work/verdaccio.npmrc:/tmp/verdaccio.npmrc:ro" \
    -v "$PROJECT:/src" \
    -w /src \
    "$NODE_IMAGE" \
    sh -ec '
        for package in /packages/*.tgz; do
            npm publish "$package" --registry http://verdaccio:4873 \
                --userconfig /tmp/verdaccio.npmrc \
                --ignore-scripts --no-audit --no-fund >/dev/null 2>&1
        done
        echo "Published local package archives; installing from Verdaccio."
        npm ci --ignore-scripts --no-audit --no-fund --cache /tmp/npm-cache \
            --userconfig /tmp/verdaccio.npmrc \
            --registry http://verdaccio:4873 --replace-registry-host=always
    '

echo 'Smoke testing the Express app installed from the registry with networking removed:'
docker run --rm \
    --network none \
    -v "$PROJECT:/src:ro" \
    -w /src \
    "$NODE_IMAGE" \
    node -e 'const app = require("./app"); if (typeof app !== "function") process.exit(1); console.log("Express app loaded from Verdaccio-installed dependencies.")'

printf '=== VERDACCIO STRETCH COMPLETE: registry served %s package archives on an internal network (%s seconds) ===\n' \
    "$(find "$ROOT/artifacts/verdaccio/packages" -maxdepth 1 -type f -name '*.tgz' | wc -l)" \
    "$((SECONDS - START_SECONDS))"
