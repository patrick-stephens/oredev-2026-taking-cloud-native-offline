#!/usr/bin/env sh
set -eu
# Internal Docker networks lack a default route. Service DNAT needs a route
# lookup to succeed first, including for host-networked kube-router.
ip route replace 10.96.0.0/12 dev eth0
exec /sbin/tini -- /entrypoint.sh "$@"
