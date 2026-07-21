#!/bin/bash
# Read-only connectivity diagnostics, layered so a failure can be pinned to
# gateway / DNS / external reachability separately. Part of the
# net-diagnosis-for-mac diagnostic pass (see run.sh). No side effects.
# The gateway is the PHYSICAL LAN router (via physical_gateway), so it works
# even when a VPN (Cato) owns the default route.

set -uo pipefail
cd "$(dirname "$0")" || exit 1
. "./lib/net-common.sh"

GATEWAY=$(physical_gateway || true)

echo "== Default gateway (physical LAN router) =="
if [ -z "$GATEWAY" ]; then
  echo "No physical gateway found — interface may be down or unconfigured."
else
  echo "Gateway: $GATEWAY"
  echo
  echo "== Ping gateway (3 packets) =="
  ping -c 3 -t 5 "$GATEWAY"
fi

echo
echo "== Configured DNS resolvers =="
scutil --dns 2>/dev/null | grep "nameserver\[" | sort -u

echo
echo "== DNS resolution check =="
for host in apple.com cloudflare.com; do
  echo "-- $host --"
  dig +short +time=3 +tries=1 "$host" 2>/dev/null || echo "(dig failed or timed out)"
done

echo
echo "== External IP reachability (bypasses DNS) =="
ping -c 3 -t 5 1.1.1.1

echo
echo "== External hostname reachability (uses DNS) =="
ping -c 3 -t 5 apple.com
