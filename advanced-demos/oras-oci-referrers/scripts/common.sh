#!/usr/bin/env bash
# shellcheck source-path=SCRIPTDIR disable=SC2034
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../config/versions.env
source "$ROOT/config/versions.env"
PREFIX=offline-oras-referrers
LABEL=io.offline-demo.name
CONNECTED="$PREFIX-connected"
OFFLINE="$PREFIX-airgapped"
UPLINK="$PREFIX-uplink"
INTERNAL="$PREFIX-internal"
REPOSITORY=localhost:5000/demo/alpine
TAG="alpine-$ALPINE_VERSION"
SBOM_TYPE=application/spdx+json
POLICY_TYPE=application/vnd.offline-demo.policy.v1+json
MODEL_TYPE=application/vnd.offline-demo.model.v1

die() { echo "ERROR: $*" >&2; exit 1; }

phase() {
  if [[ -t 1 && -n "${TERM:-}" && "${TERM:-}" != dumb ]]; then clear; fi
  echo "=== PHASE $1: $2 ==="
  sleep "${DEMO_PAUSE_SECONDS:-2}"
}

check_docker() {
  command -v docker >/dev/null || die "Docker CLI is required."
  docker info >/dev/null || die "A reachable Linux Docker engine is required."
  [[ "$(docker info --format '{{.OSType}}/{{.Architecture}}')" == linux/x86_64 ]] ||
    die "This pinned zot build requires a Linux amd64 Docker engine."
}

remove_owned() {
  local kind=$1 name=$2 owner
  if docker "$kind" inspect "$name" >/dev/null 2>&1; then
    if [[ "$kind" == container ]]; then
      owner="$(docker inspect --format "{{index .Config.Labels \"$LABEL\"}}" "$name")"
    else
      owner="$(docker "$kind" inspect --format "{{index .Labels \"$LABEL\"}}" "$name")"
    fi
    [[ "$owner" == "$PREFIX" ]] || die "Refusing to remove unowned $kind $name."
    if [[ "$kind" == container ]]; then
      docker container rm -f "$name" >/dev/null
    else
      docker "$kind" rm "$name" >/dev/null
    fi
  fi
}

cleanup_resources() {
  remove_owned container "$CONNECTED"
  remove_owned container "$OFFLINE"
  remove_owned network "$UPLINK"
  remove_owned network "$INTERNAL"
  remove_owned volume "$PREFIX-connected-data"
  remove_owned volume "$PREFIX-airgapped-data"
}

tools() {
  local namespace=$1
  shift
  docker run --rm --pull=never --network "container:$namespace" \
    --user "$(id -u):$(id -g)" --read-only --tmpfs /tmp \
    -e HTTP_PROXY= -e HTTPS_PROXY= -e ALL_PROXY= \
    -e http_proxy= -e https_proxy= -e all_proxy= -e NO_PROXY='*' -e no_proxy='*' \
    --mount "type=bind,src=$RUN_DIR,dst=/work" \
    --mount "type=bind,src=$ROOT/config,dst=/demo,readonly" \
    --mount "type=bind,src=$ROOT/scripts,dst=/scripts,readonly" \
    "$TOOLS_IMAGE" "$@"
}

firewall() {
  docker run --rm --pull=never --network "container:$OFFLINE" \
    --cap-add NET_ADMIN --read-only --tmpfs /tmp \
    "$TOOLS_IMAGE" bash -euo pipefail -c "$1"
}

start_registry() {
  local name=$1 network=$2 volume=$3
  local -a dns=()
  if [[ "$name" == "$OFFLINE" ]]; then dns=(--dns 127.0.0.1); fi
  docker volume create --label "$LABEL=$PREFIX" "$volume" >/dev/null
  docker run -d --pull=never --name "$name" --label "$LABEL=$PREFIX" \
    --network "$network" "${dns[@]}" \
    --mount "type=bind,src=$ROOT/config/zot.json,dst=/etc/zot/config.json,readonly" \
    --mount "type=volume,src=$volume,dst=/var/lib/zot" \
    "$ZOT_IMAGE" >/dev/null
  local attempt
  for ((attempt=0; attempt<30; attempt++)); do
    if tools "$name" curl --noproxy '*' -fsS --max-time 2 http://localhost:5000/v2/ >/dev/null; then
      return
    fi
    sleep 1
  done
  docker logs --tail 30 "$name" >&2
  die "Registry $name did not become ready."
}
