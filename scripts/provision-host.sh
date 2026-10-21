#!/usr/bin/env bash
# shellcheck disable=SC1091,SC2317 # demo files are sourced dynamically; provision_* are called indirectly
# Pre-cache host tools, container images and downloads needed by the demos so
# that each demo's CONNECTED phase is fast and its AIR-GAPPED phase has what it
# needs. Safe to re-run: everything already present is skipped.
#
# Pins are read from each demo's own config/scripts wherever possible, so this
# script follows the demos instead of duplicating their versions.
#
# Usage: scripts/provision-host.sh [--only IDS] [--skip IDS] [--no-system-packages] [--list]
set -euo pipefail

REPO_ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
LIVE="$REPO_ROOT/live-demos"
ADV="$REPO_ROOT/advanced-demos"

DEMO_IDS=(live-1 live-2 adv-01 adv-02 adv-03 adv-04 adv-05 adv-06 adv-07 adv-08 adv-09 adv-10 adv-11 adv-12)
declare -A DEMO_PATH=(
    [live-1]=live-demos/1-pull-through-cache-zot
    [live-2]=live-demos/2-offline-bundle-cosign
    [adv-01]=advanced-demos/zarf-package-lifecycle
    [adv-02]=advanced-demos/spegel-p2p
    [adv-03]=advanced-demos/oras-oci-referrers
    [adv-04]=advanced-demos/ratify-notation-policy
    [adv-05]=advanced-demos/offline-vuln-scan
    [adv-06]=advanced-demos/k3s-airgap
    [adv-07]=advanced-demos/offline-gitops-flux
    [adv-08]=advanced-demos/dependency-mirrors
    [adv-09]=advanced-demos/multi-arch-bundle
    [adv-10]=advanced-demos/apko-melange-offline
    [adv-11]=advanced-demos/harbor-dragonfly-preheat
    [adv-12]=advanced-demos/kubean-lifecycle
)
# Host commands each demo checks for (docker/helm/kind/kubectl are handled separately).
declare -A DEMO_CMDS=(
    [live-1]="curl jq timeout sha256sum cut grep clear"
    [live-2]="jq tar timeout sha256sum find sort stat awk grep cmp base64 head realpath"
    [adv-01]="curl jq sha256sum awk grep sed timeout head base64 cmp realpath"
    [adv-02]="curl sha256sum awk grep sed timeout"
    [adv-03]="flock jq diff sha256sum"
    [adv-04]="curl jq openssl sha256sum tar timeout clear uname grep sed sort tr cut base64 diff date"
    [adv-05]="curl tar sha256sum jq timeout date du cut tail install stat grep uname id"
    [adv-06]="curl jq sha256sum tar timeout awk grep date"
    [adv-07]="git curl ssh-keygen ssh-keyscan jq sha256sum tar"
    [adv-08]="tar"
    [adv-09]="curl jq clear sleep sha256sum id cp rm sed grep"
    [adv-10]="awk bwrap clear curl find grep seq sha256sum sleep tar wc"
    [adv-11]="curl jq tar sha256sum od"
    [adv-12]="curl awk sha256sum tar find sort xargs jq flock virsh virt-install qemu-img ssh ssh-keygen"
)
declare -A APT_PACKAGE=(
    [curl]=curl [jq]=jq [git]=git [tar]=tar [bwrap]=bubblewrap [openssl]=openssl
    [ssh]=openssh-client [ssh-keygen]=openssh-client [ssh-keyscan]=openssh-client
    [flock]=util-linux [clear]=ncurses-bin [diff]=diffutils [cmp]=diffutils [awk]=gawk
    [find]=findutils [xargs]=findutils [grep]=grep [sed]=sed [od]=coreutils
    [virsh]="libvirt-clients libvirt-daemon-system qemu-system-x86"
    [virt-install]=virtinst [qemu-img]=qemu-utils
)

# Shared host binaries: the demos that check exact versions pin them in ratify's versions.env.
HELM_VERSION="$(source "$ADV/ratify-notation-policy/config/versions.env" && printf '%s' "$HELM_VERSION")"
KIND_VERSION="$(source "$ADV/ratify-notation-policy/config/versions.env" && printf '%s' "$KIND_VERSION")"
# Kubean's lifecycle drives kubectl against its upgrade target; any compatible kubectl on PATH is kept.
KUBECTL_VERSION="v$(source "$ADV/kubean-lifecycle/config/versions.env" && printf '%s' "$UPGRADE_KUBERNETES_VERSION")"

if [[ -n "${PROVISION_BIN_DIR:-}" ]]; then
    BIN_DIR="$PROVISION_BIN_DIR"
elif [[ -w /usr/local/bin ]]; then
    BIN_DIR=/usr/local/bin
else
    BIN_DIR="$HOME/.local/bin"
fi

INSTALL_SYSTEM_PACKAGES=1
SELECTED=()
SKIPPED=()

p_usage() {
    cat <<EOF
Usage: ${0##*/} [options]

Pre-caches the tools, container images and downloads needed by the demos.

Options:
  --only IDS             Comma-separated demo IDs to provision (default: all)
  --skip IDS             Comma-separated demo IDs to skip (e.g. adv-12, which needs ~60 GiB)
  --no-system-packages   Do not apt-get install missing host commands; only report them
  --list                 List demo IDs and exit
  -h, --help             Show this help

Environment:
  PROVISION_BIN_DIR      Where helm/kind/kubectl are installed if missing
                         (default: /usr/local/bin if writable, else ~/.local/bin)
EOF
}

p_log() { printf '\033[1;34m==>\033[0m %s\n' "$*"; }
p_ok() { printf '    \033[32mok\033[0m %s\n' "$*"; }
p_warn() { printf '\033[1;33mWARN:\033[0m %s\n' "$*" >&2; }
p_die() { printf '\033[1;31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }

# Usage: p_split_ids VAR "id1,id2"  (runs in the main shell so p_die exits the script)
p_split_ids() {
    local -n out=$1
    local id
    out=()
    for id in ${2//,/ }; do
        [[ -n "${DEMO_PATH[$id]:-}" ]] || p_die "Unknown demo ID: $id (see --list)"
        out+=("$id")
    done
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --only) [[ $# -ge 2 ]] || p_die "--only needs a value"; p_split_ids SELECTED "$2"; shift 2 ;;
        --skip) [[ $# -ge 2 ]] || p_die "--skip needs a value"; p_split_ids SKIPPED "$2"; shift 2 ;;
        --no-system-packages) INSTALL_SYSTEM_PACKAGES=0; shift ;;
        --list)
            for id in "${DEMO_IDS[@]}"; do printf '%-7s %s\n' "$id" "${DEMO_PATH[$id]}"; done
            exit 0 ;;
        -h|--help) p_usage; exit 0 ;;
        *) p_usage >&2; exit 2 ;;
    esac
done
[[ ${#SELECTED[@]} -gt 0 ]] || SELECTED=("${DEMO_IDS[@]}")
if [[ ${#SKIPPED[@]} -gt 0 ]]; then
    mapfile -t SELECTED < <(printf '%s\n' "${SELECTED[@]}" | grep -vxF -f <(printf '%s\n' "${SKIPPED[@]}") || true)
fi
[[ ${#SELECTED[@]} -gt 0 ]] || p_die "No demos selected."

p_selected() {
    local id
    for id in "${SELECTED[@]}"; do [[ "$id" == "$1" ]] && return 0; done
    return 1
}

# ---------------------------------------------------------------- helpers

p_require_cmds() {
    local tool missing=()
    for tool in "$@"; do command -v "$tool" >/dev/null || missing+=("$tool"); done
    [[ ${#missing[@]} -eq 0 ]] || p_die "Missing host commands: ${missing[*]}"
}

p_pull() {
    local image attempt
    local -A seen=()
    for image in "$@"; do
        [[ -z "${seen[$image]:-}" ]] || continue
        seen[$image]=1
        if docker image inspect "$image" >/dev/null 2>&1; then
            p_ok "image cached: $image"
            continue
        fi
        for attempt in 1 2 3; do
            if docker pull --quiet --platform linux/amd64 "$image" >/dev/null; then
                p_ok "image pulled: $image"
                continue 2
            fi
            p_warn "pull failed (attempt $attempt/3): $image"
            sleep $((attempt * 5))
        done
        p_die "Could not pull $image"
    done
}

# Download URL to DEST unless it already exists with the expected SHA-256.
p_fetch() {
    local url=$1 dest=$2 sha=${3:-}
    if [[ -s "$dest" ]] && { [[ -z "$sha" ]] || printf '%s  %s\n' "$sha" "$dest" | sha256sum --check --status; }; then
        p_ok "cached: ${dest#"$REPO_ROOT"/}"
        return 0
    fi
    mkdir -p "$(dirname -- "$dest")"
    curl --fail --location --silent --show-error --retry 3 --connect-timeout 15 \
        "$url" --output "$dest.partial"
    if [[ -n "$sha" ]] && ! printf '%s  %s\n' "$sha" "$dest.partial" | sha256sum --check --status; then
        rm -f -- "$dest.partial"
        p_die "SHA-256 mismatch for $url"
    fi
    mv -- "$dest.partial" "$dest"
    p_ok "downloaded: ${dest#"$REPO_ROOT"/}"
}

p_images_in_yaml() {
    sed -nE 's/^[[:space:]]*(- )?image: ([^[:space:]]+)[[:space:]]*$/\2/p' "$@" | tr -d "\"'" | sort -u
}

p_install_bin() {
    local src=$1 name=$2
    mkdir -p "$BIN_DIR"
    install -m 0755 "$src" "$BIN_DIR/$name"
    p_ok "installed $name -> $BIN_DIR/$name"
    case ":$PATH:" in *":$BIN_DIR:"*) ;; *) p_warn "$BIN_DIR is not on PATH; add it so the demos find $name." ;; esac
}

p_check_resolved() {
    local name=$1 want=$2 have=$3
    [[ "$have" == "$want"* ]] ||
        p_die "$(command -v "$name") reports $have but $want is required; it shadows $BIN_DIR/$name on PATH."
}

p_ensure_helm() {
    if command -v helm >/dev/null && [[ "$(helm version --short 2>/dev/null)" == "$HELM_VERSION"* ]]; then
        p_ok "helm $HELM_VERSION"
        return 0
    fi
    local tmp archive="helm-$HELM_VERSION-linux-amd64.tar.gz" sha
    tmp="$(mktemp -d)"
    sha="$(curl -fsSL "https://get.helm.sh/$archive.sha256sum" | awk '{print $1}')"
    p_fetch "https://get.helm.sh/$archive" "$tmp/$archive" "$sha"
    tar -xzf "$tmp/$archive" -C "$tmp" linux-amd64/helm
    p_install_bin "$tmp/linux-amd64/helm" helm
    rm -rf -- "$tmp"
    p_check_resolved helm "$HELM_VERSION" "$(helm version --short)"
}

p_ensure_kind() {
    if command -v kind >/dev/null && [[ "$(kind version 2>/dev/null)" == "kind $KIND_VERSION "* ]]; then
        p_ok "kind $KIND_VERSION"
        return 0
    fi
    local tmp base="https://github.com/kubernetes-sigs/kind/releases/download/$KIND_VERSION" sha
    tmp="$(mktemp -d)"
    sha="$(curl -fsSL "$base/kind-linux-amd64.sha256sum" | awk '{print $1}')"
    p_fetch "$base/kind-linux-amd64" "$tmp/kind" "$sha"
    p_install_bin "$tmp/kind" kind
    rm -rf -- "$tmp"
    p_check_resolved kind "kind $KIND_VERSION" "$(kind version)"
}

p_ensure_kubectl() {
    if command -v kubectl >/dev/null; then
        p_ok "kubectl ($(kubectl version --client 2>/dev/null | head -1))"
        return 0
    fi
    local tmp base="https://dl.k8s.io/release/$KUBECTL_VERSION/bin/linux/amd64" sha
    tmp="$(mktemp -d)"
    sha="$(curl -fsSL "$base/kubectl.sha256")"
    p_fetch "$base/kubectl" "$tmp/kubectl" "$sha"
    p_install_bin "$tmp/kubectl" kubectl
    rm -rf -- "$tmp"
}

# ---------------------------------------------------------------- demos
# Each runs in its own subshell; sourcing a demo's config cannot leak into others.

provision_live-1() {
    local d="$LIVE/1-pull-through-cache-zot"
    timeout 900 docker compose --project-name offline-cache-demo --file "$d/compose.yaml" \
        --profile tools pull --policy missing --quiet
    p_ok "compose images (zot, skopeo) cached"
}

provision_live-2() {
    local d="$LIVE/2-offline-bundle-cosign"
    p_ensure_helm
    p_ensure_kind
    source "$d/scripts/common.sh"
    p_pull "$NODE_IMAGE" "$ZOT" "$SKOPEO" "$COSIGN"
}

provision_adv-01() {
    local d="$ADV/zarf-package-lifecycle"
    bash "$d/scripts/install-tools.sh"
    source "$d/scripts/common.sh"
    p_pull "$NODE_IMAGE" "$COSIGN" ghcr.io/k3d-io/k3d-tools:5.9.0 ghcr.io/stefanprodan/podinfo:6.15.0
    local base="https://github.com/zarf-dev/zarf/releases/download/v0.88.0" sha
    sha="$(curl -fsSL "$base/checksums.txt" | awk -v f="$INIT" '$2 == f {print $1}')"
    [[ -n "$sha" ]] || p_die "No checksum for $INIT"
    p_fetch "$base/$INIT" "$ARTIFACTS/$INIT" "$sha"
}

provision_adv-02() {
    local d="$ADV/spegel-p2p"
    p_ensure_helm
    source "$d/scripts/common.sh"
    mkdir -p "$TOOLS"
    ensure_k3d
    # shellcheck disable=SC2153 # K3D_VERSION comes from the sourced common.sh
    p_ok "k3d v$K3D_VERSION in ${TOOLS#"$REPO_ROOT"/}"
    p_pull "$NODE_IMAGE" "$REGISTRY_IMAGE" "$REDIS_SOURCE_IMAGE" "$SPEGEL_IMAGE" \
        "ghcr.io/k3d-io/k3d-tools:$K3D_VERSION" "ghcr.io/k3d-io/k3d-proxy:$K3D_VERSION"
}

provision_adv-03() {
    local d="$ADV/oras-oci-referrers"
    source "$d/scripts/common.sh"
    p_pull "$ZOT_IMAGE" "$ALPINE_IMAGE" "$ORAS_IMAGE" "$SYFT_IMAGE" "$COSIGN_IMAGE"
    if docker image inspect "$TOOLS_IMAGE" >/dev/null 2>&1; then
        p_ok "image cached: $TOOLS_IMAGE"
    else
        docker build --quiet --build-arg "ALPINE_IMAGE=$ALPINE_IMAGE" \
            --build-arg "ORAS_IMAGE=$ORAS_IMAGE" --build-arg "SYFT_IMAGE=$SYFT_IMAGE" \
            --build-arg "COSIGN_IMAGE=$COSIGN_IMAGE" \
            -t "$TOOLS_IMAGE" -f "$d/config/Dockerfile" "$d/config" >/dev/null
        p_ok "image built: $TOOLS_IMAGE"
    fi
}

provision_adv-04() {
    local d="$ADV/ratify-notation-policy" profile state tmp
    p_ensure_helm
    p_ensure_kind
    source "$d/config/versions.env"
    umask 077
    # Seed each profile's .state with the binaries run-demo.sh skips re-downloading.
    for profile in notation cosign sbom; do
        state="$d/.state/$profile"
        mkdir -p "$state/bin"
        if [[ $profile != cosign ]]; then
            p_fetch "https://github.com/notaryproject/notation/releases/download/v$NOTATION_VERSION/notation_${NOTATION_VERSION}_linux_amd64.tar.gz" \
                "$state/notation_${NOTATION_VERSION}_linux_amd64.tar.gz" "$NOTATION_SHA256"
        fi
        if [[ $profile == cosign ]]; then
            p_fetch "https://github.com/sigstore/cosign/releases/download/v$COSIGN_VERSION/cosign-linux-amd64" \
                "$state/bin/cosign" "$COSIGN_SHA256"
        fi
        if [[ $profile != notation ]]; then
            p_fetch "https://github.com/oras-project/oras/releases/download/v$ORAS_VERSION/oras_${ORAS_VERSION}_linux_amd64.tar.gz" \
                "$state/oras_${ORAS_VERSION}_linux_amd64.tar.gz" "$ORAS_SHA256"
        fi
        if [[ $profile == sbom ]]; then
            p_fetch "https://github.com/anchore/syft/releases/download/v$SYFT_VERSION/syft_${SYFT_VERSION}_linux_amd64.tar.gz" \
                "$state/syft_${SYFT_VERSION}_linux_amd64.tar.gz" "$SYFT_SHA256"
        fi
    done
    p_pull "$NODE_IMAGE" "$ZOT_IMAGE" "$APP_IMAGE" "$SKOPEO_IMAGE" "$HTPASSWD_IMAGE" "$PROBE_IMAGE" "$ROUTER_IMAGE"
    # Policy images are discovered from the pinned charts, exactly as run-demo.sh does.
    tmp="$(mktemp -d)"
    p_fetch "https://notaryproject.github.io/ratify/ratify-$RATIFY_CHART_VERSION.tgz" "$tmp/ratify.tgz" "$RATIFY_CHART_SHA256"
    helm pull gatekeeper --repo https://open-policy-agent.github.io/gatekeeper/charts \
        --version "$GATEKEEPER_CHART_VERSION" --destination "$tmp"
    printf '%s  %s\n' "$GATEKEEPER_CHART_SHA256" "$tmp/gatekeeper-$GATEKEEPER_CHART_VERSION.tgz" | sha256sum --check --status ||
        p_die "Gatekeeper chart checksum mismatch"
    helm template gatekeeper "$tmp/gatekeeper-$GATEKEEPER_CHART_VERSION.tgz" --skip-tests \
        -n gatekeeper-system -f "$d/config/gatekeeper-values.yaml" >"$tmp/gatekeeper.yaml"
    helm template ratify "$tmp/ratify.tgz" --skip-tests -n gatekeeper-system \
        -f "$d/config/ratify-values.yaml" >"$tmp/ratify.yaml"
    mapfile -t images < <(p_images_in_yaml "$tmp/gatekeeper.yaml" "$tmp/ratify.yaml")
    rm -rf -- "$tmp"
    p_pull "${images[@]}"
}

provision_adv-05() {
    local d="$ADV/offline-vuln-scan" candidates
    source "$d/scripts/common.sh"
    candidates="$(sed -nE 's/^image_candidates=\((.*)\)$/\1/p' "$d/scripts/run-demo.sh")"
    [[ -n "$candidates" ]] || p_die "Could not read image_candidates from run-demo.sh"
    # shellcheck disable=SC2086 # Intentional word splitting of the bash array literal.
    p_pull "$DEMO_REGISTRY_IMAGE" "$DEMO_SKOPEO_IMAGE" "$DEMO_RUNTIME_IMAGE" $candidates
}

provision_adv-06() {
    local d="$ADV/k3s-airgap"
    (cd "$d" && bash scripts/prepare.sh)
    (cd "$d" && bash scripts/prepare-k0s.sh)
}

provision_adv-07() {
    local d="$ADV/offline-gitops-flux" tmp
    bash "$d/scripts/install-tools.sh"
    source "$d/scripts/common.sh"
    p_pull "$REGISTRY_IMAGE" "$GITEA_IMAGE" "$KIND_NODE_IMAGE" "$PODINFO_IMAGE" "$CURL_IMAGE"
    mapfile -t images < <("$TOOLS_DIR/flux" install --export |
        sed -nE 's/^[[:space:]]*image: (ghcr\.io\/fluxcd\/(source-controller|kustomize-controller|helm-controller|notification-controller):[^[:space:]]+).*$/\1/p' |
        sort -u)
    [[ ${#images[@]} -eq 4 ]] || p_die "Expected four Flux controller images, got ${#images[@]}"
    p_pull "${images[@]}"
    # The --argocd variant: same manifest and Redis rewrite as scripts/argocd.sh.
    tmp="$(mktemp)"
    curl -fsSL --retry 3 "https://raw.githubusercontent.com/argoproj/argo-cd/v${ARGOCD_VERSION}/manifests/install.yaml" -o "$tmp"
    sed -i 's|image: public.ecr.aws/docker/library/redis:7.2.11-alpine$|image: docker.io/library/redis:7.2.11-alpine|' "$tmp"
    mapfile -t images < <(p_images_in_yaml "$tmp")
    rm -f -- "$tmp"
    p_pull "${images[@]}"
}

provision_adv-08() {
    local d="$ADV/dependency-mirrors"
    source "$d/config/base-images.env"
    p_pull "$PYTHON_IMAGE" "$NODE_IMAGE" "$GO_IMAGE" "$DEBIAN_IMAGE" "$VERDACCIO_IMAGE"
}

provision_adv-09() {
    local d="$ADV/multi-arch-bundle"
    docker buildx inspect default >/dev/null || p_die "Docker Buildx 'default' builder is required"
    source "$d/config/versions.env"
    p_pull "$ZOT_IMAGE" "$SKOPEO_IMAGE" "$GO_BUILDER_IMAGE" "$BUSYBOX_IMAGE" "$BINFMT_IMAGE"
}

provision_adv-10() {
    local d="$ADV/apko-melange-offline"
    bash "$d/scripts/install-tools.sh"
    source "$d/config/versions.env"
    p_pull "$ALPINE_IMAGE" "$NGINX_IMAGE" "$ZOT_IMAGE" "$K3S_IMAGE" "$PAUSE_IMAGE" "$K3D_TOOLS_IMAGE" "$K3D_PROXY_IMAGE"
    bwrap --unshare-net --ro-bind / / true 2>/dev/null ||
        p_warn "bwrap cannot create a network namespace (unprivileged user namespaces restricted, e.g. by AppArmor); the offline build will fail."
}

provision_adv-11() {
    local d="$ADV/harbor-dragonfly-preheat" component installer
    source "$d/config/versions.env"
    p_pull "$SKOPEO_IMAGE" "$JENKINS_IMAGE" "$NGINX_IMAGE" "$REDIS_IMAGE" "$MARIADB_IMAGE" "$CURL_IMAGE" \
        "goharbor/prepare:v$HARBOR_VERSION" "dragonflyoss/manager:$DRAGONFLY_VERSION" \
        "dragonflyoss/scheduler:$DRAGONFLY_VERSION" "dragonflyoss/dfdaemon:$DRAGONFLY_VERSION"
    # Services generated by goharbor/prepare with defaults; run-demo.sh starts them with pull_policy: never.
    for component in harbor-log registry-photon harbor-registryctl harbor-db harbor-core \
        harbor-portal harbor-jobservice redis-photon nginx-photon; do
        p_pull "goharbor/$component:v$HARBOR_VERSION"
    done
    installer="$d/.state/harbor-installer.tgz"
    p_fetch "https://github.com/goharbor/harbor/releases/download/v$HARBOR_VERSION/harbor-online-installer-v$HARBOR_VERSION.tgz" "$installer"
    tar -tzf "$installer" >/dev/null || { rm -f -- "$installer"; p_die "Corrupt Harbor installer removed; re-run."; }
}

provision_adv-12() {
    local d="$ADV/kubean-lifecycle" image_dir images
    p_ensure_helm
    p_ensure_kubectl
    source "$d/config/versions.env"
    if [[ -s "$d/artifacts/kubean-lifecycle-bundles.tar.gz" ]]; then
        p_ok "bundle exists: advanced-demos/kubean-lifecycle/artifacts/kubean-lifecycle-bundles.tar.gz"
        p_pull "$HTTPD_IMAGE" "$BUSYBOX_IMAGE" "$REGISTRY_IMAGE" "$FILES_IMAGE" "quay.io/podman/stable:v$PODMAN_IMPORT_VERSION"
    else
        (cd "$d" && bash scripts/prepare-bundle.sh)
    fi
    # Same path, URL and checksum as scripts/kvm.sh, without creating VMs.
    image_dir="$d/.state/images"
    p_fetch "https://cloud-images.ubuntu.com/jammy/$KVM_UBUNTU_IMAGE_DATE/jammy-server-cloudimg-amd64.img" \
        "$image_dir/jammy-server-cloudimg-amd64.img" "$KVM_UBUNTU_IMAGE_SHA256"
    # Management-cluster prerequisites from the README.
    helm repo add kubean-io https://kubean-io.github.io/kubean-helm-chart/ --force-update >/dev/null
    helm repo update kubean-io >/dev/null
    mapfile -t images < <(helm template kubean kubean-io/kubean --version "$KUBEAN_OPERATOR_VERSION" \
        -n kubean-system | p_images_in_yaml /dev/stdin)
    p_pull "${images[@]}" "ghcr.io/kubean-io/spray-job:$BASE_KUBEAN_VERSION" \
        "ghcr.io/kubean-io/spray-job:$UPGRADE_KUBEAN_VERSION" "$BUSYBOX_IMAGE"
    [[ -r /dev/kvm && -w /dev/kvm ]] || p_warn "/dev/kvm is not read/writable by $(id -un); add yourself to the kvm group."
    virsh -c qemu:///system list >/dev/null 2>&1 ||
        p_warn "Cannot connect to qemu:///system; ensure libvirtd is running and you are in the libvirt group."
}

# ---------------------------------------------------------------- host checks

p_log "Host checks"
[[ "$(uname -s)/$(uname -m)" == Linux/x86_64 ]] || p_die "The demos pin linux/amd64; use a native Linux x86_64 host."
command -v docker >/dev/null || p_die "Install Docker Engine first: https://docs.docker.com/engine/install/"
docker info >/dev/null 2>&1 || p_die "Docker is not reachable; start it and ensure you can run docker without sudo."
[[ "$(docker info --format '{{.OSType}}/{{.Architecture}}')" == linux/x86_64 ]] || p_die "A linux/amd64 Docker engine is required."
docker compose version >/dev/null 2>&1 || p_die "Docker Compose v2 plugin is required."
docker buildx version >/dev/null 2>&1 || p_die "Docker Buildx plugin is required."
p_ok "docker $(docker version --format '{{.Server.Version}}'), $(docker compose version --short 2>/dev/null || echo compose), buildx"

missing=()
for id in "${SELECTED[@]}"; do
    for tool in ${DEMO_CMDS[$id]}; do
        command -v "$tool" >/dev/null || missing+=("$tool")
    done
done
if [[ ${#missing[@]} -gt 0 ]]; then
    mapfile -t missing < <(printf '%s\n' "${missing[@]}" | sort -u)
    packages=()
    for tool in "${missing[@]}"; do
        # shellcheck disable=SC2206 # Some commands map to several packages.
        packages+=(${APT_PACKAGE[$tool]:-coreutils})
    done
    mapfile -t packages < <(printf '%s\n' "${packages[@]}" | sort -u)
    if [[ $INSTALL_SYSTEM_PACKAGES == 1 ]] && command -v apt-get >/dev/null; then
        p_log "Installing missing host commands (${missing[*]}) via apt: ${packages[*]}"
        sudo_cmd=()
        [[ $EUID -eq 0 ]] || sudo_cmd=(sudo)
        "${sudo_cmd[@]}" apt-get update -qq
        DEBIAN_FRONTEND=noninteractive "${sudo_cmd[@]}" apt-get install -y -qq "${packages[@]}"
    else
        p_warn "Missing host commands: ${missing[*]} (packages: ${packages[*]}). Demos needing them will fail."
    fi
else
    p_ok "all host commands present"
fi

if p_selected adv-12; then
    free_gib=$(( $(df --output=avail -k "$REPO_ROOT" | tail -1) / 1024 / 1024 ))
    [[ $free_gib -ge 80 ]] || p_warn "Only ${free_gib} GiB free; adv-12 (kubean) needs 60-80 GiB. Use --skip adv-12 if short."
fi

# ---------------------------------------------------------------- run

declare -A RESULT=()
for id in "${SELECTED[@]}"; do
    p_log "[$id] ${DEMO_PATH[$id]}"
    started=$SECONDS
    # Run as a plain command (not an `if` condition) so errexit stays active inside.
    set +e
    (
        set -euo pipefail
        # shellcheck disable=SC2086 # intentional word splitting of the command list
        p_require_cmds docker ${DEMO_CMDS[$id]}
        "provision_$id"
    )
    status=$?
    set -e
    if [[ $status -eq 0 ]]; then
        RESULT[$id]="ok ($((SECONDS - started))s)"
    else
        RESULT[$id]="FAILED (exit $status)"
    fi
done

p_log "Summary"
failed=0
for id in "${SELECTED[@]}"; do
    printf '  %-7s %-24s %s\n' "$id" "${RESULT[$id]}" "${DEMO_PATH[$id]}"
    [[ "${RESULT[$id]}" == ok* ]] || failed=1
done

cat <<'EOF'

Still fetched live by design during each demo's CONNECTED phase (the demos
rebuild these every run to show the transfer boundary, so they cannot be
pre-seeded without changing the demos):
  live-1  nginx:latest through zot (that is the demo)
  live-2  postgres image copied by skopeo into the bundle
  adv-01  zarf package create (podinfo chart, git repo, image) and checksums.txt
  adv-02  spegel Helm chart (helm pull from ghcr.io)
  adv-03  alpine copied by oras into zot
  adv-04  ratify/gatekeeper charts (re-downloaded and checksum-verified)
  adv-05  trivy/grype binaries and vulnerability DBs
  adv-08  pip/npm/go/apt dependencies
  adv-09  busybox multi-arch index via skopeo
  adv-10  Alpine APK closure
Docker images used in those phases are cached, so they mostly cost metadata.
EOF

exit "$failed"
