#!/bin/bash
# Shared helpers for net-diagnosis-for-mac. SOURCED by entry scripts (run.sh's
# children, net-cato-check.sh, net-monitor.sh) — never executed directly.
# Read-only; no side effects. Bash 3.2 compatible (macOS system bash).
#
# Callers cd into scripts/ first, so ./net-monitor.conf is reachable here.

# ping summary lines look like:
#   "3 packets transmitted, 3 packets received, 0.0% packet loss"
#   "round-trip min/avg/max/stddev = 1.9/2.4/3.1/0.5 ms"
# These are stdin FILTERS — they do not run ping themselves.
ping_loss() { grep -oE '[0-9.]+% packet loss' | grep -oE '^[0-9.]+'; }
ping_avg()  { grep 'round-trip' | sed -E 's#.*= [0-9.]+/([0-9.]+)/.*#\1#'; }
