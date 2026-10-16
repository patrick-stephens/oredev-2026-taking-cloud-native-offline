#!/usr/bin/env bash
set -euo pipefail
# shellcheck source=common.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"
START=$SECONDS
PAUSE="${DEMO_SLEEP_SECONDS:-2}"
umask 077
mkdir -p "$ROOT/.state" "$ROOT/artifacts"
on_exit() {
    local rc=$?
    if (( rc != 0 )); then
        echo "FAILED (exit $rc), collecting diagnostics; no success claimed." >&2
        collect_logs || echo "Log collection also failed." >&2
        printf "failed_runtime_seconds=%s\n" "$((SECONDS-START))" > "$ROOT/artifacts/runtime.txt"
    fi
}
trap on_exit EXIT

for command in docker curl jq tar sha256sum; do
    command -v "$command" >/dev/null || { echo "Missing prerequisite: $command" >&2; exit 1; }
done
docker compose version
echo '=== PHASE 1: CONNECTED ==='
echo "Preparing $JENKINS_IMAGE and a Harbor-triggered Dragonfly seed."
if [[ -f "$ROOT/.state/runtime.env" ]]; then
    bash "$ROOT/scripts/cleanup.sh" --reset
fi
# Keep old evidence until prerequisites and teardown have succeeded.
mkdir -p "$ROOT/.state/gateway" "$ROOT/.state/pulls"
for image in "$SKOPEO_IMAGE" "$JENKINS_IMAGE" "$NGINX_IMAGE" "$REDIS_IMAGE" \
    "$MARIADB_IMAGE" "$CURL_IMAGE" "goharbor/prepare:v$HARBOR_VERSION" \
    "dragonflyoss/manager:$DRAGONFLY_VERSION" "dragonflyoss/scheduler:$DRAGONFLY_VERSION" \
    "dragonflyoss/dfdaemon:$DRAGONFLY_VERSION"; do
    docker pull "$image"
done
{
    docker version
    docker compose version
    date -u +'%FT%TZ'
    cat "$ROOT/config/versions.env"
} > "$ROOT/artifacts/versions.txt"

if [[ ! -f "$ROOT/.state/harbor-installer.tgz" ]]; then
    curl -fL --retry 3 \
        "https://github.com/goharbor/harbor/releases/download/v$HARBOR_VERSION/harbor-online-installer-v$HARBOR_VERSION.tgz" \
        -o "$ROOT/.state/harbor-installer.tgz.part"
    mv "$ROOT/.state/harbor-installer.tgz.part" "$ROOT/.state/harbor-installer.tgz"
fi
tar -xzf "$ROOT/.state/harbor-installer.tgz" -C "$ROOT/.state"
secret() { od -An -N24 -tx1 /dev/urandom | tr -d ' \n'; }
DEMO_ADMIN_PASSWORD="$(secret)"
DEMO_DB_PASSWORD="$(secret)"
export DEMO_ADMIN_PASSWORD DEMO_DB_PASSWORD
printf 'DEMO_ADMIN_PASSWORD=%s\nDEMO_DB_PASSWORD=%s\n' \
    "$DEMO_ADMIN_PASSWORD" "$DEMO_DB_PASSWORD" > "$ROOT/.state/runtime.env"
printf 'user = "admin:%s"\n' "$DEMO_ADMIN_PASSWORD" > "$ROOT/.state/curl.conf"
sed -e 's/^hostname:.*/hostname: harbor/' \
    -e 's/^  port: 80$/  port: 8080/' \
    -e 's/^https:/#https:/' -e 's/^  port: 443/#  port: 443/' \
    -e 's/^  certificate:/#  certificate:/' -e 's/^  private_key:/#  private_key:/' \
    -e "s/^harbor_admin_password:.*/harbor_admin_password: $DEMO_ADMIN_PASSWORD/" \
    -e "s/^  password: root123$/  password: $DEMO_DB_PASSWORD/" \
    -e "s|^data_volume:.*|data_volume: $ROOT/.state/harbor-data|" \
    -e "s|^    location: /var/log/harbor|    location: $ROOT/.state/log|" \
    "$ROOT/.state/harbor/harbor.yml.tmpl" > "$ROOT/.state/harbor/harbor.yml"
mkdir -p "$ROOT/.state/harbor/input" "$ROOT/.state/harbor/common/config" "$ROOT/.state/harbor-data"
cp "$ROOT/.state/harbor/harbor.yml" "$ROOT/.state/harbor/input/harbor.yml"
# Use the official generator, but do not give it the host root or privileged mode.
docker run --rm --pull never --network none \
    -v "$ROOT/.state/harbor/input:/input" \
    -v "$ROOT/.state/harbor-data:/data" \
    -v "$ROOT/.state/harbor:/compose_location" \
    -v "$ROOT/.state/harbor/common/config:/config" \
    -v "$ROOT/.state:$ROOT/.state" \
    -v "$ROOT/.state:/hostfs$ROOT/.state" \
    "goharbor/prepare:v$HARBOR_VERSION" prepare
# Compose reads env_file on the host. Preserve the ownership of runtime-mounted
# app configs; change only generated env files that Compose imports.
docker run --rm --pull never --network none --entrypoint /bin/sh \
    -v "$ROOT/.state/harbor:/generated" "goharbor/prepare:v$HARBOR_VERSION" \
    -ec 'find /generated/common/config -type f -name env -exec chown "$1:$2" {} +' \
    sh "$(id -u)" "$(id -g)"
docker compose -f "$ROOT/.state/harbor/docker-compose.yml" config --format json |
    jq --arg network "$NETWORK" '
      del(.services.log) |
      .services |= with_entries(.value |= (
        del(.container_name, .logging, .depends_on.log) |
        .restart = "no" | .ports = [] | .pull_policy = "never")) |
      .services.jobservice.depends_on.core.condition = "service_healthy" |
      .services.proxy.depends_on.core.condition = "service_healthy" |
      .networks = {harbor:{external:true,name:$network}}
    ' > "$ROOT/.state/harbor.compose.json.part"
mv "$ROOT/.state/harbor.compose.json.part" "$ROOT/.state/harbor.compose.json"
# Pull Harbor separately: the runtime specification prohibits implicit pulls.
while IFS= read -r image; do docker pull "$image"; done < <(
    jq -r '.services[].image' "$ROOT/.state/harbor.compose.json" | sort -u
)
if ! docker network inspect "$NETWORK" >/dev/null 2>&1; then
    docker network create --internal "$NETWORK"
fi
[[ "$(docker network inspect -f '{{.Internal}}' "$NETWORK")" == true ]]
cp "$ROOT/config/gateway.conf" "$ROOT/.state/gateway/default.conf"
cp "$ROOT/config/peer.yaml" "$ROOT/.state/peer.yaml"
# Only the seed registers with manager; consumers use the scheduler directly.
sed '/^scheduler:/,/^download:/{ /^scheduler:/!{ /^download:/!d; }; }' \
    "$ROOT/config/peer.yaml" > "$ROOT/.state/seed.yaml"
sed -i '/^scheduler:/r /dev/stdin' "$ROOT/.state/seed.yaml" <<'SEED'
  manager:
    enable: true
    refreshInterval: 5s
    netAddrs:
      - type: tcp
        addr: manager:65003
    seedPeer:
      enable: true
      type: super
      clusterID: 1
      keepAlive:
        interval: 5s
  scheduleTimeout: 60s
  disableAutoBackSource: false
SEED
cat > "$ROOT/.state/manager.yaml" <<EOF
server:
  grpc:
    port: {start: 65003, end: 65003}
  rest:
    addr: ":8080"
auth:
  jwt:
    realm: Dragonfly
    key: "$DEMO_DB_PASSWORD"
    timeout: 48h
    maxRefresh: 48h
database:
  type: mysql
  mysql:
    user: dragonfly
    password: "$DEMO_DB_PASSWORD"
    host: dragonfly-db
    port: 3306
    dbname: manager
    migrate: true
  redis:
    addrs: [dragonfly-redis:6379]
    db: 0
    brokerDB: 1
    backendDB: 2
cache:
  redis: {ttl: 30s}
  local: {size: 10000, ttl: 10s}
metrics:
  enable: true
  addr: ":8000"
console: true
verbose: true
EOF
# Configs are not credentials for consumers; mounted files must be readable by image UIDs.
chmod 755 "$ROOT/.state" "$ROOT/.state/gateway"
chmod 644 "$ROOT/.state/peer.yaml" "$ROOT/.state/seed.yaml" "$ROOT/.state/gateway/default.conf"
hc up -d --pull never
dc up -d --wait --wait-timeout 240 --pull never dragonfly-redis dragonfly-db manager scheduler seed gateway
wait_url http://harbor:8080/api/v2.0/health
wait_url http://manager:8080/_ping
sleep 15
api /projects -X POST -d '{"project_name":"fleet","public":true}' > /dev/null
auth="$(printf 'admin:%s' "$DEMO_ADMIN_PASSWORD" | base64 -w0)"
jq -n --arg auth "$auth" '{"auths":{"harbor:8080":{"auth":$auth}}}' > "$ROOT/.state/auth.json"
# Export once from the host daemon; no second Docker Hub download.
mkdir -p "$ROOT/.state/pulls/source"
docker run --rm --pull never --network none \
    -v /var/run/docker.sock:/var/run/docker.sock -v "$ROOT/.state/pulls/source:/out" \
    "$SKOPEO_IMAGE" copy --override-os linux --override-arch amd64 \
    "docker-daemon:$JENKINS_IMAGE" dir:/out
docker run --rm --pull never --network "$NETWORK" \
    -v "$ROOT/.state/pulls/source:/in:ro" -v "$ROOT/.state/auth.json:/auth.json:ro" \
    "$SKOPEO_IMAGE" copy --dest-authfile /auth.json \
    --dest-tls-verify=false dir:/in "docker://harbor:8080/fleet/jenkins:$JENKINS_TAG"
docker run --rm --pull never --network "$NETWORK" "$SKOPEO_IMAGE" inspect --raw \
    --tls-verify=false "docker://harbor:8080/fleet/jenkins:$JENKINS_TAG" > "$ROOT/artifacts/manifest.json"
api /p2p/preheat/instances -X POST -d \
    '{"name":"dragonfly","vendor":"dragonfly","endpoint":"http://manager:8080","enabled":true,"default":true,"insecure":true,"auth_mode":"NONE"}'
PROVIDER_ID="$(api /p2p/preheat/instances/dragonfly | jq -er .id)"
POLICY="$(jq -nc --argjson id "$PROVIDER_ID" --arg tag "$JENKINS_TAG" \
    '{name:"jenkins",provider_id:$id,enabled:true,
      filters:([{type:"repository",value:"jenkins"},{type:"tag",value:$tag}]|tojson),
      trigger:"{\"type\":\"manual\",\"trigger_settings\":{}}"}')"
api /projects/fleet/preheat/policies -X POST -d "$POLICY"
api /projects/fleet/preheat/policies/jenkins -X POST -d "$POLICY"
for _ in $(seq 1 180); do
    api /projects/fleet/preheat/policies/jenkins/executions > "$ROOT/artifacts/preheat.json"
    status="$(jq -r '.[0].status // "Pending"' "$ROOT/artifacts/preheat.json")"
    echo "Harbor preheat: $status"
    case "$status" in
        Success) break ;;
        Error|Failed|Stopped) echo "Preheat failed: inspect artifacts." >&2; exit 1 ;;
    esac
    sleep 2
done
[[ "$status" == Success ]]
jq -e '.[0].metrics | .task_count == 1 and .success_task_count == 1' \
    "$ROOT/artifacts/preheat.json" > /dev/null
inside http://seed:8000/metrics > "$ROOT/artifacts/seed-preheated.prom"
awk '/^dragonfly_dfdaemon_seed_peer_download_traffic\{type="back_to_source"\}/ {
    if ($2 > 0) found=1
} END {exit !found}' "$ROOT/artifacts/seed-preheated.prom"
docker image inspect "$JENKINS_IMAGE" --format '{{json .RepoDigests}}' > "$ROOT/artifacts/jenkins-digests.json"
mapfile -t harbor_images < <(jq -r '.services[].image' "$ROOT/.state/harbor.compose.json" | sort -u)
docker image inspect "${harbor_images[@]}" \
    "$SKOPEO_IMAGE" "$JENKINS_IMAGE" "$NGINX_IMAGE" "$CURL_IMAGE" "$REDIS_IMAGE" "$MARIADB_IMAGE" \
    "dragonflyoss/manager:$DRAGONFLY_VERSION" "dragonflyoss/scheduler:$DRAGONFLY_VERSION" \
    "dragonflyoss/dfdaemon:$DRAGONFLY_VERSION" \
    --format '{{.RepoTags}} {{.RepoDigests}}' > "$ROOT/artifacts/image-lock.txt"
sleep "$PAUSE"
if [[ -t 1 && -n "${TERM:-}" ]]; then clear; fi
echo '=== PHASE 2: AIR-GAPPED ==='
echo 'Local registry metadata and P2P traffic are permitted; internet egress must fail.'
bash "$ROOT/scripts/verify-isolation.sh"
printf 'mode,consumer,elapsed_ms,compressed_bytes\n' > "$ROOT/artifacts/timings.csv"
bash "$ROOT/scripts/benchmark.sh" direct
# No source may supply blobs after this point, including to seed peers.
sed '/# Replaced with/,/proxy_set_header Host harbor:8080;/c\        return 403;' \
    "$ROOT/config/gateway.conf" > "$ROOT/.state/gateway/default.conf"
dc exec -T gateway nginx -t
dc exec -T gateway nginx -s reload
sleep 2
blob="$(jq -er '.layers[0].digest' "$ROOT/artifacts/manifest.json")"
probe_rc=0
code="$(inside -o /dev/null -w '%{http_code}' "http://harbor:8080/v2/fleet/jenkins/blobs/$blob" 2>"$ROOT/artifacts/blocked-probe.err")" || probe_rc=$?
[[ "$probe_rc" == 22 ]] || { echo "Unexpected blocked probe exit: $probe_rc" >&2; exit 1; }
[[ "$code" == 403 ]] || { echo "Harbor blob blockade failed: $code" >&2; exit 1; }
CUTOVER="$(date -u +'%FT%TZ')"
dc up -d --wait --wait-timeout 240 --pull never peer1 peer2 peer3 peer4 peer5
inside http://seed:8000/metrics > "$ROOT/artifacts/seed-before.prom"
bash "$ROOT/scripts/benchmark.sh" p2p
inside http://seed:8000/metrics > "$ROOT/artifacts/seed-after.prom"
for i in $(seq 1 5); do
    inside "http://peer$i:8000/metrics" > "$ROOT/artifacts/peer$i.prom"
done
bash "$ROOT/scripts/verify-isolation.sh"
collect_logs
dc logs --no-color gateway > "$ROOT/artifacts/gateway.log"
dc logs --no-color --since "$CUTOVER" gateway > "$ROOT/artifacts/gateway-blocked.log"
origin_bytes="$(awk '/ (GET|HEAD) .*\/blobs\/sha256:/ && $(NF-1) ~ /^2/ {n += $NF} END {print n+0}' \
    "$ROOT/artifacts/gateway-blocked.log")"
[[ "$origin_bytes" == 0 ]] || { echo "Source served $origin_bytes blob bytes after cutover!" >&2; exit 1; }
bash "$ROOT/scripts/report.sh"
cat "$ROOT/artifacts/timings.csv"
sleep "$PAUSE"
printf 'total_runtime_seconds=%s\n' "$((SECONDS-START))" | tee "$ROOT/artifacts/runtime.txt"
echo 'Verified: five digest-checked cold copies via peers while all Harbor blob requests return 403.'
echo 'Use seed-before/after and peer metrics plus gateway/Dragonfly logs to inspect distribution.'
