#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../config/base-images.env
source "$ROOT/config/base-images.env"
SLEEP_SECONDS="${DEMO_SLEEP_SECONDS:-2}"
START_SECONDS=$SECONDS
HOST_UID="$(id -u)"
HOST_GID="$(id -g)"
MODE="${1:-full}"

case "$MODE" in
    full|--air-gapped) ;;
    *)
        printf 'Usage: %s [--air-gapped]\n' "$0" >&2
        exit 2
        ;;
esac

pause_for_narration() {
    sleep "$SLEEP_SECONDS"
}

clear_between_phases() {
    if [[ -t 1 ]]; then
        clear
    fi
}

if [[ "$MODE" == full ]]; then
    mkdir -p "$ROOT/artifacts" "$ROOT/.work"

    echo '=== PHASE 1: CONNECTED ==='
    echo 'Pulling the pinned toolchain images and acquiring all dependency artifacts.'
    docker pull "$PYTHON_IMAGE"
    docker pull "$NODE_IMAGE"
    docker pull "$GO_IMAGE"
    docker pull "$DEBIAN_IMAGE"
    docker pull "$VERDACCIO_IMAGE"

    docker run --rm \
        -v "$ROOT/.work:/work" \
        -v "$ROOT/artifacts:/artifacts" \
        "$NODE_IMAGE" rm -rf \
        /work/npm/node_modules /work/go/vendor \
        /artifacts/pip/wheels /artifacts/npm-cache /artifacts/go/vendor \
        /artifacts/debs /artifacts/verdaccio/packages \
        /artifacts/dependency-mirrors.tar.gz \
        /artifacts/contrast-build.log
    rm -rf -- "$ROOT/.work" "$ROOT/artifacts"
    mkdir -p "$ROOT/artifacts/pip/wheels" "$ROOT/artifacts/npm-cache" \
        "$ROOT/artifacts/go" "$ROOT/artifacts/debs" \
        "$ROOT/artifacts/verdaccio/packages" "$ROOT/.work"

    docker run --rm \
        --user "$HOST_UID:$HOST_GID" \
        -e HOME=/tmp \
        -v "$ROOT/apps/python-flask:/src:ro" \
        -v "$ROOT/artifacts/pip/wheels:/wheels" \
        -w /src "$PYTHON_IMAGE" \
        pip download --no-cache-dir --only-binary=:all: --dest /wheels -r requirements.txt

    mkdir -p "$ROOT/.work/npm"
    cp -a "$ROOT/apps/node-express/." "$ROOT/.work/npm/"
    docker run --rm \
        --user "$HOST_UID:$HOST_GID" \
        -v "$ROOT/.work/npm:/src" \
        -v "$ROOT/artifacts/npm-cache:/cache" \
        -v "$ROOT/scripts/pack-node-deps.cjs:/pack-node-deps.cjs:ro" \
        -v "$ROOT/artifacts/verdaccio/packages:/packages" \
        -w /src "$NODE_IMAGE" \
        sh -ec 'npm ci --cache /cache && node /pack-node-deps.cjs /src /packages /cache'
    rm -rf -- "$ROOT/.work/npm/node_modules"

    mkdir -p "$ROOT/.work/go"
    cp -a "$ROOT/apps/go-cli/." "$ROOT/.work/go/"
    docker run --rm \
        --user "$HOST_UID:$HOST_GID" \
        -e GOMODCACHE=/tmp/gomodcache \
        -e GOCACHE=/tmp/gocache \
        -v "$ROOT/.work/go:/src" \
        -w /src "$GO_IMAGE" \
        sh -ec 'go mod download && go mod vendor'
    cp -a "$ROOT/.work/go/vendor" "$ROOT/artifacts/go/vendor"

    docker run --rm \
        -v "$ROOT/artifacts/debs:/artifacts" \
        "$DEBIAN_IMAGE" sh -ec \
        'trap "chmod 755 /artifacts" EXIT; chmod 777 /artifacts; apt-get update >/dev/null && cd /artifacts && apt-get download jq libjq1 libonig5'

    tar -czf "$ROOT/artifacts/dependency-mirrors.tar.gz" \
        -C "$ROOT/artifacts" pip npm-cache go debs verdaccio
    echo 'Connected artifacts:'
    printf '  pip wheels: %s\n' "$(find "$ROOT/artifacts/pip/wheels" -maxdepth 1 -type f | wc -l)"
    printf '  npm cache files: %s\n' "$(find "$ROOT/artifacts/npm-cache" -type f | wc -l)"
    printf '  Go vendored files: %s\n' "$(find "$ROOT/artifacts/go/vendor" -type f | wc -l)"
    printf '  Debian packages: %s\n' "$(find "$ROOT/artifacts/debs" -maxdepth 1 -name '*.deb' | wc -l)"
    printf '  Verdaccio package tarballs: %s\n' "$(find "$ROOT/artifacts/verdaccio/packages" -maxdepth 1 -name '*.tgz' | wc -l)"
    printf '  Bundle: %s\n' "$ROOT/artifacts/dependency-mirrors.tar.gz"
    pause_for_narration
    clear_between_phases
else
    for artifact_dir in pip/wheels npm-cache go/vendor debs; do
        if [[ ! -d "$ROOT/artifacts/$artifact_dir" ]]; then
            printf 'Missing staged artifact directory: artifacts/%s\n' "$artifact_dir" >&2
            exit 1
        fi
    done
    for image in "$PYTHON_IMAGE" "$NODE_IMAGE" "$GO_IMAGE" "$DEBIAN_IMAGE"; do
        if ! docker image inspect "$image" >/dev/null 2>&1; then
            printf 'Base image is not present locally: %s\n' "$image" >&2
            exit 1
        fi
    done
    rm -rf -- "$ROOT/.work"
    mkdir -p "$ROOT/.work"
fi

echo '=== PHASE 2: AIR-GAPPED ==='
echo 'All following image builds use --network none; base images are already local.'
BUILD="$ROOT/.work/build"
rm -rf -- "$BUILD"
mkdir -p "$BUILD"/{python,node,go,apt,contrast}

cp -a "$ROOT/apps/python-flask/." "$BUILD/python/"
mkdir -p "$BUILD/python/deps"
cp -a "$ROOT/artifacts/pip/wheels" "$BUILD/python/deps/"

cp -a "$ROOT/apps/node-express/." "$BUILD/node/"
mkdir -p "$BUILD/node/deps"
cp -a "$ROOT/artifacts/npm-cache" "$BUILD/node/deps/"

cp -a "$ROOT/apps/go-cli/." "$BUILD/go/"
cp -a "$ROOT/artifacts/go/vendor" "$BUILD/go/vendor"

cp -a "$ROOT/apps/apt-c-utility/." "$BUILD/apt/"
mkdir -p "$BUILD/apt/deps"
cp -a "$ROOT/artifacts/debs" "$BUILD/apt/deps/"

docker build --network none --pull=false --build-arg "PYTHON_IMAGE=$PYTHON_IMAGE" \
    -t offline-dependency-mirrors:python "$BUILD/python"
docker build --network none --pull=false --build-arg "NODE_IMAGE=$NODE_IMAGE" \
    -t offline-dependency-mirrors:node "$BUILD/node"
docker build --network none --pull=false --build-arg "GO_IMAGE=$GO_IMAGE" \
    -t offline-dependency-mirrors:go "$BUILD/go"
docker build --network none --pull=false --build-arg "DEBIAN_IMAGE=$DEBIAN_IMAGE" \
    -t offline-dependency-mirrors:apt "$BUILD/apt"

echo 'Smoke tests (containers use Docker network "none"):'
docker run --rm --network none offline-dependency-mirrors:python \
    python -c 'from app import app; response = app.test_client().get("/healthz"); assert response.status_code == 200 and response.json["status"] == "ok"; print(response.json)'
docker run --rm --network none offline-dependency-mirrors:node \
    node -e 'const app = require("./app"); const server = app.listen(0, "127.0.0.1", async () => { try { const response = await fetch(`http://127.0.0.1:${server.address().port}/healthz`); const body = await response.json(); if (response.status !== 200 || body.status !== "ok") process.exitCode = 1; console.log(body); } catch (error) { console.error(error); process.exitCode = 1; } finally { server.close(); } });'
docker run --rm --network none offline-dependency-mirrors:go demo
docker run --rm --network none offline-dependency-mirrors:apt \
    sh -ec 'test "$(jq -n "\"apt-offline-ok\"")" = "\"apt-offline-ok\"" && jq --version'

echo 'Negative control: same Express Dockerfile, intentionally empty npm cache.'
cp -a "$ROOT/apps/node-express/." "$BUILD/contrast/"
mkdir -p "$BUILD/contrast/deps/npm-cache"
if docker build --network none --pull=false --build-arg "NODE_IMAGE=$NODE_IMAGE" \
    -t offline-dependency-mirrors:contrast "$BUILD/contrast" \
    >"$ROOT/artifacts/contrast-build.log" 2>&1
then
    echo 'ERROR: negative control unexpectedly succeeded; the empty-cache proof is invalid.' >&2
    exit 1
fi
if ! grep -Eq 'ENOTCACHED|not in cache|cache mode' "$ROOT/artifacts/contrast-build.log"; then
    echo 'ERROR: negative control failed, but not with an informative npm cache-miss error.' >&2
    tail -n 40 "$ROOT/artifacts/contrast-build.log" >&2
    exit 1
fi
echo 'Expected failure captured (npm has no cached package data):'
grep -E 'ENOTCACHED|not in cache|cache mode' "$ROOT/artifacts/contrast-build.log" | head -n 3

echo 'Network isolation check: network=none exposes only loopback in the build image.'
docker run --rm --network none "$GO_IMAGE" sh -ec \
    'interfaces="$(ls /sys/class/net)"; test "$interfaces" = lo; printf "interfaces: %s\n" "$interfaces"'

printf '=== COMPLETE: all four offline builds and the negative control behaved as expected (%s seconds) ===\n' "$((SECONDS - START_SECONDS))"
