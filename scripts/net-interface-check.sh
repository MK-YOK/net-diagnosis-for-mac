#!/bin/bash
# Read-only interface/link diagnostics: which service is active, does it
# have a valid IP, is the link actually up. Part of the net-diagnosis-for-mac
# diagnostic pass (see run.sh). No side effects.

set -uo pipefail

echo "== Active network services (in priority order) =="
networksetup -listnetworkserviceorder 2>/dev/null | grep -B1 "Hardware Port" | grep -E "^\([0-9]"

echo
echo "== Primary interface (route to default) =="
route -n get default 2>/dev/null | grep -E "interface|gateway"

echo
echo "== Interface details (up/running, IP, media) =="
for iface in $(ifconfig -l); do
  status=$(ifconfig "$iface" 2>/dev/null | grep -E "^\s*status:" | awk '{print $2}')
  [ -z "$status" ] && continue
  echo "-- $iface (status: $status) --"
  ifconfig "$iface" 2>/dev/null | grep -E "inet |media:"
done
