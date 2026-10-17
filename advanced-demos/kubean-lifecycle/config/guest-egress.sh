#!/usr/bin/env bash
set -euo pipefail

for table in iptables ip6tables; do
  for hook in OUTPUT FORWARD; do
    chain="KUBEAN-AIRGAP-$hook"
    if ! "$table" -w -nL "$chain" >/dev/null 2>&1; then
      "$table" -w -N "$chain"
    fi
    "$table" -w -F "$chain"
    if [[ "$hook" == OUTPUT ]]; then
      "$table" -w -A "$chain" -o lo -j RETURN
    fi
    if [[ "$table" == iptables ]]; then
      if [[ "$hook" == OUTPUT ]]; then
        "$table" -w -A "$chain" -p udp --sport 68 --dport 67 -j RETURN
      fi
      for destination in 192.168.56.0/24 10.233.0.0/16; do
        "$table" -w -A "$chain" -d "$destination" -j RETURN
      done
    fi
    "$table" -w -A "$chain" -j REJECT
    if ! "$table" -w -C "$hook" -j "$chain" 2>/dev/null; then
      "$table" -w -I "$hook" 1 -j "$chain"
    fi
  done
done
