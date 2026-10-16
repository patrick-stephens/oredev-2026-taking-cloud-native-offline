#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

if docker container inspect dependency-mirrors-verdaccio >/dev/null 2>&1; then
    owner="$(docker container inspect dependency-mirrors-verdaccio \
        --format '{{ index .Config.Labels "org.oredev.demo" }}')"
    if [[ "$owner" != dependency-mirrors ]]; then
        echo 'Refusing to remove an unlabelled Verdaccio container with the demo name.' >&2
        exit 1
    fi
    docker container rm --force dependency-mirrors-verdaccio
fi
if docker network inspect dependency-mirrors-verdaccio >/dev/null 2>&1; then
    owner="$(docker network inspect dependency-mirrors-verdaccio \
        --format '{{ index .Labels "org.oredev.demo" }}')"
    if [[ "$owner" != dependency-mirrors ]]; then
        echo 'Refusing to remove an unlabelled Docker network with the demo name.' >&2
        exit 1
    fi
    docker network rm dependency-mirrors-verdaccio
fi
if docker volume inspect dependency-mirrors-verdaccio-storage >/dev/null 2>&1; then
    owner="$(docker volume inspect dependency-mirrors-verdaccio-storage \
        --format '{{ index .Labels "org.oredev.demo" }}')"
    if [[ "$owner" != dependency-mirrors ]]; then
        echo 'Refusing to remove an unlabelled Docker volume with the demo name.' >&2
        exit 1
    fi
    docker volume rm dependency-mirrors-verdaccio-storage
fi

for image in \
    offline-dependency-mirrors:python \
    offline-dependency-mirrors:node \
    offline-dependency-mirrors:go \
    offline-dependency-mirrors:apt \
    offline-dependency-mirrors:contrast
do
    if docker image inspect "$image" >/dev/null 2>&1; then
        docker image rm "$image"
    fi
done

rm -rf -- "$ROOT/.work" "$ROOT/artifacts"
printf "Removed this demo's staged artifacts and tagged images.\n"
