#!/bin/sh
# Runs ONLY inside the disposable k3d node, never on the host.
set -eu
# Mangle hooks run before kube-router's filter-table ACCEPT rules. kube-router
# periodically prepends its own filter jumps, so filter ordering is not stable.
iptables() { /bin/aux/iptables -t mangle "$@"; }
ip6tables() { /bin/aux/ip6tables -t mangle "$@"; }
node_ip="$(ip -4 -o addr show dev eth0 | awk '{print $4}' | cut -d/ -f1)"
test -n "$node_ip"
if ! iptables -nL ZARF_DEMO_EGRESS >/dev/null 2>&1; then
    iptables -N ZARF_DEMO_EGRESS
    # Prevent Docker's loopback DNS resolver from forwarding external queries.
    iptables -A ZARF_DEMO_EGRESS -d 127.0.0.11 -p udp --dport 53 -j DROP
    iptables -A ZARF_DEMO_EGRESS -d 127.0.0.11 -p tcp --dport 53 -j DROP
    for destination in 127.0.0.0/8 "$node_ip/32" 10.42.0.0/16 10.43.0.0/16; do
        iptables -A ZARF_DEMO_EGRESS -d "$destination" -j RETURN
    done
    iptables -A ZARF_DEMO_EGRESS -j DROP
fi
for chain in OUTPUT FORWARD; do
    if ! iptables -C "$chain" -j ZARF_DEMO_EGRESS 2>/dev/null; then
        iptables -I "$chain" 1 -j ZARF_DEMO_EGRESS
    fi
done
if ! ip6tables -nL ZARF_DEMO_EGRESS >/dev/null 2>&1; then
    ip6tables -N ZARF_DEMO_EGRESS
    ip6tables -A ZARF_DEMO_EGRESS -d ::1/128 -j RETURN
    # Local neighbor discovery on pod bridges is not internet egress.
    ip6tables -A ZARF_DEMO_EGRESS -d fe80::/10 -j RETURN
    ip6tables -A ZARF_DEMO_EGRESS -d ff02::/16 -j RETURN
    ip6tables -A ZARF_DEMO_EGRESS -j DROP
fi
for chain in OUTPUT FORWARD; do
    if ! ip6tables -C "$chain" -j ZARF_DEMO_EGRESS 2>/dev/null; then
        ip6tables -I "$chain" 1 -j ZARF_DEMO_EGRESS
    fi
done
printf 'ISOLATED: node and pod egress allow only loopback, node IP, pod and service CIDRs.\n'
