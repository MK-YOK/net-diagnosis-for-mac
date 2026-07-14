#!/bin/bash
# Read-only connectivity diagnostics, layered so a failure can be pinned to
# gateway / DNS / external reachability separately. Part of the
# net-diagnosis-for-mac diagnostic pass (see run.sh). No side effects.

set -uo pipefail

GATEWAY=$(route -n get default 2>/dev/null | awk '/gateway:/{print $2}')

echo "== Default gateway =="
if [ -z "$GATEWAY" ]; then
  echo "No default gateway found — interface may be down or unconfigured."
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
