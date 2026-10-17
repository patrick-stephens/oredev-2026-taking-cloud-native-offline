#!/usr/bin/env bash
set -euo pipefail
source "$(dirname -- "${BASH_SOURCE[0]}")/common.sh"

started_at=$SECONDS
report_failure() {
    local exit_code=$?
    if [[ "$exit_code" != 0 ]]; then
        printf 'FAILED (exit %s) after %dm %02ds; state retained for inspection.\n' \
            "$exit_code" "$(( (SECONDS - started_at) / 60 ))" "$(( (SECONDS - started_at) % 60 ))" >&2
    fi
}
trap report_failure EXIT
umask 077

require_command docker
require_command git
require_command curl
require_command ssh-keygen
require_command ssh-keyscan
require_command jq
require_command sha256sum

docker info --format '{{.OSType}}/{{.Architecture}}' | grep -qx 'linux/x86_64' ||
    die "This pinned kind node and tool set requires a Linux amd64 Docker engine."

phase "1: CONNECTED — stage every payload and create Git bundles"
"$DEMO_DIR/scripts/install-tools.sh"
"$DEMO_DIR/scripts/cleanup.sh"
mkdir -p "$STATE_DIR/ssh" "$STATE_DIR/home/.ssh" "$STATE_DIR/connected"
chmod 700 "$STATE_DIR" "$STATE_DIR/ssh" "$STATE_DIR/home" "$STATE_DIR/home/.ssh"

docker network create --internal "$NETWORK_NAME" >/dev/null
[[ "$(docker network inspect --format '{{.Internal}}' "$NETWORK_NAME")" == "true" ]] ||
    die "Docker network $NETWORK_NAME is not internal."

docker pull "$REGISTRY_IMAGE"
docker pull "$GITEA_IMAGE"
docker pull "$KIND_NODE_IMAGE"
docker pull "$PODINFO_IMAGE"
docker pull "$CURL_IMAGE"

docker run --detach --name "$REGISTRY_CONTAINER" \
    --network bridge \
    --publish 127.0.0.1:5001:5000 \
    --volume offline-gitops-registry-data:/var/lib/registry \
    "$REGISTRY_IMAGE" >/dev/null
wait_for_url "http://127.0.0.1:5001/v2/" "local registry"

flux_images="$STATE_DIR/flux-images.txt"
"$TOOLS_DIR/flux" install --export |
    sed -nE 's/^[[:space:]]*image: (ghcr\.io\/fluxcd\/(source-controller|kustomize-controller|helm-controller|notification-controller):[^[:space:]]+).*$/\1/p' |
    sort -u >"$flux_images"
[[ "$(wc -l <"$flux_images")" -eq 4 ]] ||
    die "Flux $FLUX_VERSION did not export exactly four required controller images."
while IFS= read -r image; do
    docker pull "$image"
    local_image="127.0.0.1:5001/${image#ghcr.io/}"
    docker tag "$image" "$local_image"
    docker push "$local_image"
done <"$flux_images"

podinfo_registry_image="127.0.0.1:5001/podinfo:6.15.0"
docker tag "$PODINFO_IMAGE" "$podinfo_registry_image"
docker push "$podinfo_registry_image"

"$TOOLS_DIR/helm" pull podinfo \
    --repo https://stefanprodan.github.io/podinfo \
    --version "$CHART_VERSION" \
    --destination "$STATE_DIR"
"$TOOLS_DIR/helm" push "$STATE_DIR/podinfo-${CHART_VERSION}.tgz" \
    oci://127.0.0.1:5001/charts

docker network connect --alias registry "$NETWORK_NAME" "$REGISTRY_CONTAINER"
registry_ip="$(network_container_ip "$REGISTRY_CONTAINER")"
[[ "$registry_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
    die "Could not resolve the registry's internal IPv4 address."
docker network disconnect bridge "$REGISTRY_CONTAINER"
[[ "$(docker inspect --format \
    "{{with index .NetworkSettings.Networks \"$NETWORK_NAME\"}}{{.IPAddress}}{{end}}" \
    "$REGISTRY_CONTAINER")" == "$registry_ip" ]] ||
    die "The local registry did not remain connected to the internal Docker network."

git -C "$STATE_DIR/connected" init --initial-branch=main >/dev/null
cp -a "$DEMO_DIR/config/git-repo/." "$STATE_DIR/connected/"
find "$STATE_DIR/connected" -type f -name '*.yaml' -print0 |
    xargs -0 sed -i "s/__REGISTRY_IP__/$registry_ip/g"
git -C "$STATE_DIR/connected" config user.name "Offline GitOps Demo"
git -C "$STATE_DIR/connected" config user.email "offline-gitops@example.invalid"
git -C "$STATE_DIR/connected" add .
git -C "$STATE_DIR/connected" commit -m "Add offline podinfo deployment" >/dev/null
git -C "$STATE_DIR/connected" bundle create "$STATE_DIR/offline.bundle" --all >/dev/null

helm_release="$STATE_DIR/connected/clusters/demo/apps/podinfo/helm-release.yaml"
sed -i \
    -e 's/replicaCount: 1/replicaCount: 2/' \
    -e 's/Offline baseline from Git/Updated through offline bundle/' \
    "$helm_release"
git -C "$STATE_DIR/connected" add .
git -C "$STATE_DIR/connected" commit -m "Scale podinfo through an offline Git bundle" >/dev/null
git -C "$STATE_DIR/connected" bundle create "$STATE_DIR/update.bundle" --all >/dev/null
git -C "$STATE_DIR/connected" bundle verify "$STATE_DIR/offline.bundle"
git -C "$STATE_DIR/connected" bundle verify "$STATE_DIR/update.bundle"
sha256sum "$STATE_DIR/offline.bundle" "$STATE_DIR/update.bundle" |
    tee "$STATE_DIR/bundle-checksums.txt"
printf 'Staged bundles: baseline (%s) and update (%s).\n' \
    "$(du -h "$STATE_DIR/offline.bundle" | cut -f1)" \
    "$(du -h "$STATE_DIR/update.bundle" | cut -f1)"

KUBECONFIG="$STATE_DIR/kubeconfig"
export KUBECONFIG
sed "s/__REGISTRY_IP__/$registry_ip/g" "$DEMO_DIR/config/kind.yaml" >"$STATE_DIR/kind.yaml"
"$TOOLS_DIR/kind" create cluster \
    --name "$CLUSTER_NAME" \
    --image "$KIND_NODE_IMAGE" \
    --config "$STATE_DIR/kind.yaml" \
    --kubeconfig "$KUBECONFIG" \
    --wait 3m
docker network connect "$NETWORK_NAME" "$CLUSTER_NODE"
external_iface="$(docker exec "$CLUSTER_NODE" ip -4 route show default | awk 'NR == 1 {print $5}')"
[[ -n "$external_iface" ]] || die "Could not identify the kind node's Internet-facing interface."
external_ip="$(docker run --pull=never --rm --network "container:$CLUSTER_NODE" "$CURL_IMAGE" \
    --noproxy '*' --ipv4 --fail --silent --show-error --max-time 15 \
    --output /dev/null --write-out '%{remote_ip}' https://example.com/)"
[[ "$external_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
    die "The connected node's external HTTPS positive control failed."
printf 'CONNECTED positive control: external HTTPS succeeded via %s.\n' "$external_ip"
for firewall in iptables ip6tables; do
    # Only replies to inbound administration may leave the external interface.
    docker exec "$CLUSTER_NODE" "$firewall" -I OUTPUT 1 \
        -m conntrack --ctstate ESTABLISHED,RELATED --ctdir REPLY -j ACCEPT
    docker exec "$CLUSTER_NODE" "$firewall" -I OUTPUT 2 -o "$external_iface" -j REJECT
    docker exec "$CLUSTER_NODE" "$firewall" -I FORWARD 1 \
        -m conntrack --ctstate ESTABLISHED,RELATED --ctdir REPLY -j ACCEPT
    docker exec "$CLUSTER_NODE" "$firewall" -I FORWARD 2 -o "$external_iface" -j REJECT
done
"$TOOLS_DIR/kind" load docker-image "$CURL_IMAGE" --name "$CLUSTER_NAME"
printf 'Cluster prepared; external-interface egress rules installed before AIR-GAPPED begins.\n'

pause_for_presenter

phase "2: AIR-GAPPED — internal Git, registry, cluster and Flux bootstrap"
docker run --detach --name "$GITEA_CONTAINER" \
    --pull=never \
    --network "$NETWORK_NAME" --network-alias gitea \
    --volume offline-gitops-gitea-data:/data \
    --env USER_UID=1000 --env USER_GID=1000 \
    --env GITEA__database__DB_TYPE=sqlite3 \
    --env GITEA__security__INSTALL_LOCK=true \
    --env GITEA__service__DISABLE_REGISTRATION=true \
    --env GITEA__server__SSH_DOMAIN=localhost \
    --env GITEA__server__SSH_PORT=2222 \
    --env GITEA__server__ROOT_URL=http://127.0.0.1:3000/ \
    "$GITEA_IMAGE" >/dev/null
gitea_ip="$(network_container_ip "$GITEA_CONTAINER")"
[[ "$gitea_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] ||
    die "Could not resolve Gitea's internal IPv4 address."
wait_for_url "http://$gitea_ip:3000/" "Gitea"

gitea_user="demo-admin"
gitea_password="$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n')"
printf '%s\n' "$gitea_user:$gitea_password" >"$STATE_DIR/gitea-credentials"
chmod 600 "$STATE_DIR/gitea-credentials"
docker exec -u git "$GITEA_CONTAINER" gitea admin user create \
    --username "$gitea_user" \
    --password "$gitea_password" \
    --email offline-gitops@example.invalid \
    --admin \
    --must-change-password=false

ssh_key="$STATE_DIR/ssh/id_ed25519"
ssh-keygen -q -t ed25519 -N '' -C offline-gitops-demo -f "$ssh_key"
chmod 600 "$ssh_key"
ssh_public_key="$(<"$ssh_key.pub")"
jq -n --arg key "$ssh_public_key" \
    '{title:"offline-gitops-demo",key:$key}' |
    curl --noproxy '*' --fail --silent --show-error \
        --user "$gitea_user:$gitea_password" \
        --header 'Content-Type: application/json' \
        --data-binary @- \
        "http://$gitea_ip:3000/api/v1/user/keys" >/dev/null
jq -n '{name:"offline-gitops",private:true,default_branch:"main"}' |
    curl --noproxy '*' --fail --silent --show-error \
        --user "$gitea_user:$gitea_password" \
        --header 'Content-Type: application/json' \
        --data-binary @- \
        "http://$gitea_ip:3000/api/v1/user/repos" >/dev/null

ssh-keyscan -T 10 -p 22 "$gitea_ip" >"$STATE_DIR/home/.ssh/known_hosts" 2>/dev/null
chmod 600 "$STATE_DIR/home/.ssh/known_hosts"
export HOME="$STATE_DIR/home"
ssh_url="ssh://git@$gitea_ip:22/$gitea_user/offline-gitops.git"
git_ssh_command="ssh -i $ssh_key -o IdentitiesOnly=yes -o UserKnownHostsFile=$STATE_DIR/home/.ssh/known_hosts -o StrictHostKeyChecking=yes"
sha256sum --check "$STATE_DIR/bundle-checksums.txt"
git clone "$STATE_DIR/offline.bundle" "$STATE_DIR/initial-import"
git -C "$STATE_DIR/initial-import" remote add gitea "$ssh_url"
GIT_SSH_COMMAND="$git_ssh_command" git -C "$STATE_DIR/initial-import" push gitea main

printf 'y\n' | "$TOOLS_DIR/flux" bootstrap git \
    --url "$ssh_url" \
    --branch main \
    --private-key-file "$ssh_key" \
    --path clusters/demo \
    --registry "$registry_ip:5000/fluxcd" \
    --components source-controller,kustomize-controller,helm-controller,notification-controller \
    --timeout 5m

"$TOOLS_DIR/kubectl" -n flux-system wait \
    --for=condition=Ready pod --all --timeout=5m
"$TOOLS_DIR/flux" reconcile source git flux-system --timeout=2m
"$TOOLS_DIR/flux" reconcile kustomization flux-system --with-source --timeout=5m
"$TOOLS_DIR/flux" reconcile helmrelease podinfo -n podinfo --with-source --timeout=5m
baseline_commit="$(GIT_SSH_COMMAND="$git_ssh_command" git ls-remote "$ssh_url" refs/heads/main | cut -f1)"
verify_state 1 "Offline baseline from Git" "$baseline_commit"
verify_isolation "$registry_ip" "$external_iface" "$external_ip"

printf '\nInitial local evidence:\n'
"$TOOLS_DIR/flux" get sources git -A
"$TOOLS_DIR/flux" get kustomizations -A
"$TOOLS_DIR/kubectl" -n podinfo get pods -o wide
"$TOOLS_DIR/kubectl" -n podinfo get deployment podinfo \
    -o jsonpath='desired={.spec.replicas} ready={.status.readyReplicas}{"\n"}'

pause_for_presenter

phase "3: AIR-GAPPED UPDATE — import the staged bundle and observe reconciliation"
printf 'Bundle checksums (created in the CONNECTED phase):\n'
cat "$STATE_DIR/bundle-checksums.txt"
sha256sum --check "$STATE_DIR/bundle-checksums.txt"
GIT_SSH_COMMAND="$git_ssh_command" git clone "$ssh_url" "$STATE_DIR/update-import"
git -C "$STATE_DIR/update-import" config user.name "Offline GitOps Demo"
git -C "$STATE_DIR/update-import" config user.email "offline-gitops@example.invalid"
git -C "$STATE_DIR/update-import" fetch "$STATE_DIR/update.bundle" main
update_commit="$(git -C "$STATE_DIR/update-import" rev-parse FETCH_HEAD)"
git -C "$STATE_DIR/update-import" cherry-pick -x "$update_commit"
GIT_SSH_COMMAND="$git_ssh_command" git -C "$STATE_DIR/update-import" push origin main
imported_commit="$(git -C "$STATE_DIR/update-import" rev-parse HEAD)"

"$TOOLS_DIR/flux" reconcile source git flux-system --timeout=2m
"$TOOLS_DIR/flux" reconcile kustomization flux-system --with-source --timeout=5m
"$TOOLS_DIR/flux" reconcile helmrelease podinfo -n podinfo --with-source --timeout=5m
verify_state 2 "Updated through offline bundle" "$imported_commit"
verify_isolation "$registry_ip" "$external_iface" "$external_ip"

printf '\nUpdated local evidence:\n'
"$TOOLS_DIR/flux" get sources git -A
"$TOOLS_DIR/flux" get kustomizations -A
"$TOOLS_DIR/kubectl" -n podinfo get pods -o wide
"$TOOLS_DIR/kubectl" -n podinfo get deployment podinfo \
    -o jsonpath='desired={.spec.replicas} ready={.status.readyReplicas}{"\n"}'
printf '\nCOMPLETE: Flux reconciled the Gitea update with external egress blocked.\n'
printf 'Total runtime: %dm %02ds\n' "$(( (SECONDS - started_at) / 60 ))" "$(( (SECONDS - started_at) % 60 ))"
printf 'Runtime remains available for inspection; run ./scripts/cleanup.sh when done.\n'
