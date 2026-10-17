#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=../config/versions.env
source "$ROOT/config/versions.env"

LIBVIRT_URI="${LIBVIRT_URI:-qemu:///system}"
STATE="$ROOT/.state"
VM_STATE="$STATE/kvm"
SSH_DIR="$STATE/ssh"
IMAGE_DIR="$STATE/images"
BASE_IMAGE="$IMAGE_DIR/jammy-server-cloudimg-amd64.img"
SSH_KEY="$SSH_DIR/id_ed25519"
SSH_KNOWN_HOSTS="$SSH_DIR/known_hosts"
NETWORK_NAME='kubean-lifecycle'
IMAGE_URL="https://cloud-images.ubuntu.com/jammy/$KVM_UBUNTU_IMAGE_DATE/jammy-server-cloudimg-amd64.img"

fail() {
  echo "ERROR: $*" >&2
  exit 1
}

require() {
  local tool
  for tool in "$@"; do
    command -v "$tool" >/dev/null || fail "missing prerequisite: $tool"
  done
}

domain_name() {
  printf 'kubean-lifecycle-%s' "$1"
}

guest_ip() {
  case "$1" in
    cp1) printf '192.168.56.11' ;;
    worker1) printf '192.168.56.12' ;;
    *) fail "unknown node: $1" ;;
  esac
}

nat_mac() {
  case "$1" in
    cp1) printf '52:54:00:56:00:11' ;;
    worker1) printf '52:54:00:56:00:12' ;;
    *) fail "unknown node: $1" ;;
  esac
}

private_mac() {
  case "$1" in
    cp1) printf '52:54:00:56:10:11' ;;
    worker1) printf '52:54:00:56:10:12' ;;
    *) fail "unknown node: $1" ;;
  esac
}

wait_for_ssh() {
  local node="$1"
  local address attempt=0
  address="$(guest_ip "$node")"
  while (( attempt < 120 )); do
    attempt=$((attempt + 1))
    if ssh -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=3 \
      -o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=$SSH_KNOWN_HOSTS" \
      "vagrant@$address" true >/dev/null 2>&1; then
      printf '%s is reachable over SSH at %s\n' "$node" "$address"
      return
    fi
    sleep 2
  done
  fail "SSH did not become available for $node at $address; inspect with virsh -c $LIBVIRT_URI console $(domain_name "$node")"
}

write_cloud_init() {
  local node="$1"
  local output="$2"
  local public_key
  public_key="$(<"$SSH_KEY.pub")"
  cat > "$output" <<EOF
#cloud-config
hostname: kubean-$node
manage_etc_hosts: true
users:
  - default
  - name: vagrant
    gecos: Kubean lifecycle demo
    groups: [adm, sudo]
    shell: /bin/bash
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: true
    ssh_authorized_keys:
      - $public_key
ssh_pwauth: false
disable_root: true
package_update: false
EOF
}

write_network_config() {
  local node="$1"
  local output="$2"
  cat > "$output" <<EOF
version: 2
ethernets:
  nat:
    match:
      macaddress: '$(nat_mac "$node")'
    dhcp4: true
    dhcp6: false
  private:
    match:
      macaddress: '$(private_mac "$node")'
    dhcp4: true
    dhcp4-overrides:
      use-routes: false
    dhcp6: false
EOF
}

ensure_network() {
  local network_info
  if ! virsh -c "$LIBVIRT_URI" net-info "$NETWORK_NAME" >/dev/null 2>&1; then
    virsh -c "$LIBVIRT_URI" net-define "$ROOT/config/libvirt-network.xml"
  fi
  network_info="$(virsh -c "$LIBVIRT_URI" net-info "$NETWORK_NAME")"
  if [[ ! "$network_info" =~ Active:[[:space:]]+yes ]]; then
    virsh -c "$LIBVIRT_URI" net-start "$NETWORK_NAME"
  fi
}

create_node() {
  local node="$1"
  local domain disk userdata networkdata
  domain="$(domain_name "$node")"
  disk="$VM_STATE/$node.qcow2"
  userdata="$VM_STATE/$node-user-data.yaml"
  networkdata="$VM_STATE/$node-network-config.yaml"
  if virsh -c "$LIBVIRT_URI" dominfo "$domain" >/dev/null 2>&1; then
    if [[ "$(virsh -c "$LIBVIRT_URI" domstate "$domain")" == 'shut off' ]]; then
      virsh -c "$LIBVIRT_URI" start "$domain" >/dev/null
    fi
    return
  fi

  write_cloud_init "$node" "$userdata"
  write_network_config "$node" "$networkdata"
  if [[ -e "$disk" ]]; then
    qemu-img info "$disk" >/dev/null || fail "invalid existing VM disk: $disk"
  else
    qemu-img create -f qcow2 -F qcow2 -b "$BASE_IMAGE" "$disk" 32G >/dev/null
  fi
  virt-install --connect "$LIBVIRT_URI" --name "$domain" \
    --memory 4096 --vcpus 2 --cpu host-passthrough \
    --osinfo ubuntu22.04 --import \
    --disk "path=$disk,format=qcow2,bus=virtio" \
    --network "network=default,model=virtio,mac=$(nat_mac "$node")" \
    --network "network=$NETWORK_NAME,model=virtio,mac=$(private_mac "$node")" \
    --cloud-init "user-data=$userdata,network-config=$networkdata" \
    --noautoconsole --wait 0
}

up() {
  require virsh virt-install qemu-img curl sha256sum ssh ssh-keygen
  [[ -r /dev/kvm && -w /dev/kvm ]] || fail '/dev/kvm must be readable and writable'
  mkdir -p "$VM_STATE" "$SSH_DIR" "$IMAGE_DIR"

  if [[ ! -s "$BASE_IMAGE" ]]; then
    local partial="$BASE_IMAGE.partial"
    curl --fail --location --retry 3 --silent --show-error "$IMAGE_URL" --output "$partial"
    printf '%s  %s\n' "$KVM_UBUNTU_IMAGE_SHA256" "$partial" | sha256sum --check --status || {
      rm -f -- "$partial"
      fail "Ubuntu cloud image checksum mismatch: $IMAGE_URL"
    }
    mv -- "$partial" "$BASE_IMAGE"
  fi
  if [[ ! -s "$SSH_KEY" ]]; then
    ssh-keygen -q -t ed25519 -N '' -f "$SSH_KEY" -C kubean-lifecycle-demo
  fi
  chmod 0600 "$SSH_KEY"
  ensure_network

  create_node cp1
  create_node worker1
  restore_nat
  wait_for_ssh cp1
  wait_for_ssh worker1
}

restore_nat() {
  local node domain mac
  for node in cp1 worker1; do
    domain="$(domain_name "$node")"
    mac="$(nat_mac "$node")"
    virsh -c "$LIBVIRT_URI" domif-setlink "$domain" "$mac" up
    virsh -c "$LIBVIRT_URI" domif-setlink "$domain" "$mac" up --config
  done
}

connect_external_egress() {
  local node address
  restore_nat
  for node in cp1 worker1; do
    wait_for_ssh "$node"
    address="$(guest_ip "$node")"
    ssh -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=5 \
      -o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=$SSH_KNOWN_HOSTS" \
      "vagrant@$address" 'sudo bash -s' <<'REMOTE'
set -euo pipefail
if systemctl cat kubean-airgap.service >/dev/null 2>&1; then
  systemctl disable --now kubean-airgap.service
fi
for table in iptables ip6tables; do
  for hook in OUTPUT FORWARD; do
    chain="KUBEAN-AIRGAP-$hook"
    if "$table" -w -nL "$chain" >/dev/null 2>&1; then
      while "$table" -w -C "$hook" -j "$chain" 2>/dev/null; do
        "$table" -w -D "$hook" -j "$chain"
      done
      "$table" -w -F "$chain"
      "$table" -w -X "$chain"
    fi
  done
done
REMOTE
    printf 'CONNECTED: removed only demo egress filters on %s.\n' "$node"
  done
}

isolate_external_egress() {
  local node address
  for node in cp1 worker1; do
    address="$(guest_ip "$node")"
    ssh -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=5 \
      -o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=$SSH_KNOWN_HOSTS" \
      "vagrant@$address" \
      'sudo install -m 0755 /dev/stdin /usr/local/sbin/kubean-airgap' \
      < "$ROOT/config/guest-egress.sh"
    ssh -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=5 \
      -o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=$SSH_KNOWN_HOSTS" \
      "vagrant@$address" 'sudo bash -s' <<'REMOTE'
set -euo pipefail
cat > /etc/systemd/system/kubean-airgap.service <<'UNIT'
[Unit]
Description=Kubean demo external-egress filter
Before=network-pre.target kubelet.service
Wants=network-pre.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/kubean-airgap
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
UNIT
systemctl daemon-reload
systemctl enable kubean-airgap.service
systemctl restart kubean-airgap.service
REMOTE
    printf 'Installed idempotent external-egress filters on %s.\n' "$node"
  done
}

check_connected() {
  local node address route
  for node in cp1 worker1; do
    address="$(guest_ip "$node")"
    route="$(ssh -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=5 \
      -o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=$SSH_KNOWN_HOSTS" \
      "vagrant@$address" 'ip route show default')"
    [[ -n "$route" ]] || fail "$node has no default route in the connected phase"
    ssh -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=5 \
      -o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=$SSH_KNOWN_HOSTS" \
      "vagrant@$address" 'timeout 8 bash -c "</dev/tcp/1.1.1.1/443"' >/dev/null ||
      fail "$node could not reach the connected-phase external TCP probe"
    printf 'Connected check: %s has a default route and reaches 1.1.1.1:443.\n' "$node"
  done
}

check_isolation() {
  local node address route ipv6_route
  for node in cp1 worker1; do
    address="$(guest_ip "$node")"
    route="$(ssh -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=5 \
      -o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=$SSH_KNOWN_HOSTS" \
      "vagrant@$address" 'ip route show default')"
    [[ -n "$route" ]] || fail "$node has no default route; Kubernetes service routing requires one"
    ipv6_route="$(ssh -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=5 \
      -o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=$SSH_KNOWN_HOSTS" \
      "vagrant@$address" 'ip -6 route show default')"
    [[ -z "$ipv6_route" ]] || fail "$node has an IPv6 default route: $ipv6_route"
    if ssh -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=5 \
      -o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=$SSH_KNOWN_HOSTS" \
      "vagrant@$address" 'timeout 5 bash -c "</dev/tcp/1.1.1.1/443"' >/dev/null 2>&1; then
      fail "$node reached an external IP during the air-gapped phase"
    fi
    if ssh -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=5 \
      -o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=$SSH_KNOWN_HOSTS" \
      "vagrant@$address" 'timeout 5 bash -c "exec 3<>/dev/tcp/2606:4700:4700::1111/443"' \
      >/dev/null 2>&1; then
      fail "$node reached an external IPv6 address during the air-gapped phase"
    fi
    ssh -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=5 \
      -o StrictHostKeyChecking=accept-new -o "UserKnownHostsFile=$SSH_KNOWN_HOSTS" \
      "vagrant@$address" 'sudo systemctl is-enabled --quiet kubean-airgap.service &&
        sudo systemctl is-active --quiet kubean-airgap.service &&
        sudo iptables -w -C OUTPUT -j KUBEAN-AIRGAP-OUTPUT >/dev/null &&
        sudo iptables -w -C FORWARD -j KUBEAN-AIRGAP-FORWARD >/dev/null &&
        sudo ip6tables -w -C OUTPUT -j KUBEAN-AIRGAP-OUTPUT >/dev/null &&
        sudo ip6tables -w -C FORWARD -j KUBEAN-AIRGAP-FORWARD >/dev/null' ||
      fail "$node does not have persistent IPv4/IPv6 egress filters"
    printf 'Expected isolation: %s retains its private route and cannot reach public probes; filters persist across boot.\n' "$node"
  done
}

destroy() {
  local node domain
  require virsh
  for node in cp1 worker1; do
    domain="$(domain_name "$node")"
    if virsh -c "$LIBVIRT_URI" dominfo "$domain" >/dev/null 2>&1; then
      virsh -c "$LIBVIRT_URI" destroy "$domain" >/dev/null 2>&1 || true
      virsh -c "$LIBVIRT_URI" undefine "$domain" --nvram >/dev/null 2>&1 ||
        virsh -c "$LIBVIRT_URI" undefine "$domain" >/dev/null
    fi
  done
  if virsh -c "$LIBVIRT_URI" net-info "$NETWORK_NAME" >/dev/null 2>&1; then
    virsh -c "$LIBVIRT_URI" net-destroy "$NETWORK_NAME" >/dev/null 2>&1 || true
    virsh -c "$LIBVIRT_URI" net-undefine "$NETWORK_NAME" >/dev/null
  fi
}

case "${1:-}" in
  up) up ;;
  connect-egress) connect_external_egress ;;
  check-connected) check_connected ;;
  isolate-egress) isolate_external_egress ;;
  check-isolation) check_isolation ;;
  destroy) destroy ;;
  *)
    echo "Usage: $0 {up|connect-egress|check-connected|isolate-egress|check-isolation|destroy}" >&2
    exit 2
    ;;
esac
