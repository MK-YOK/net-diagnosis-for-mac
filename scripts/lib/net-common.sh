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

# parse_duration <str> : echo the duration in seconds, or return 1 on bad input.
# Accepts "30m", "45s", "2h", or bare seconds like "90".
parse_duration() {
  local s="$1" num unit
  printf '%s' "$s" | grep -qE '^[0-9]+[smh]?$' || return 1
  num=$(printf '%s' "$s" | grep -oE '^[0-9]+')
  unit=$(printf '%s' "$s" | grep -oE '[smh]$')
  case "$unit" in
    m) printf '%s\n' "$((num * 60))" ;;
    h) printf '%s\n' "$((num * 3600))" ;;
    *) printf '%s\n' "$num" ;;
  esac
}

# exceeds <value> <threshold> : return 0 (true) if value > threshold.
# value may be "n/a" (avg when 100% loss) or empty → NOT exceeding (the loss
# check catches those cases). Non-numeric values are treated as not exceeding.
exceeds() {
  local value="$1" threshold="$2"
  case "$value" in
    ''|n/a) return 1 ;;
    *[!0-9.]*) return 1 ;;
  esac
  awk -v v="$value" -v t="$threshold" 'BEGIN { exit !(v > t) }'
}

# classify_route <iface> <cato_present> : pure classifier.
# cato_present is "1" when a Cato client process is running, else "0".
# -> cato | vpn | direct | unknown
classify_route() {
  local iface="$1" cato="$2"
  if [ -z "$iface" ]; then printf 'unknown\n'; return; fi
  case "$iface" in
    utun*)
      if [ "$cato" = "1" ]; then printf 'cato\n'; else printf 'vpn\n'; fi
      ;;
    *) printf 'direct\n' ;;
  esac
}

# default_route_class : wire the real route/pgrep commands into classify_route.
default_route_class() {
  local iface cato=0
  iface=$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')
  if pgrep -f CatoClient >/dev/null 2>&1; then cato=1; fi
  classify_route "$iface" "$cato"
}

# ping_probe <host> <count> : run ONE ping batch and echo "LOSS AVG" derived
# from the same sample. AVG is "n/a" when nothing returned (100% loss); LOSS
# defaults to "100" if the summary can't be parsed at all (e.g. unknown host).
ping_probe() {
  local host="$1" count="$2" out loss avg
  out=$(ping -c "$count" -t 5 "$host" 2>&1)
  loss=$(printf '%s\n' "$out" | ping_loss)
  avg=$(printf '%s\n' "$out" | ping_avg)
  [ -z "$loss" ] && loss="100"
  [ -z "$avg" ] && avg="n/a"
  printf '%s %s\n' "$loss" "$avg"
}

# physical_gateway : echo the physical LAN router IP, independent of any VPN.
# When Cato holds the default route via utun, `route -n get default` has no
# gateway line, so we ask the active hardware interface for its router.
# Honors an explicit GATEWAY override (from net-monitor.conf / env).
# Returns 1 (no output) if none found.
physical_gateway() {
  local iface router
  if [ -n "${GATEWAY:-}" ]; then printf '%s\n' "$GATEWAY"; return 0; fi
  for iface in $(ifconfig -l 2>/dev/null); do
    case "$iface" in en*) ;; *) continue ;; esac
    ifconfig "$iface" 2>/dev/null | grep -q 'status: active' || continue
    ifconfig "$iface" 2>/dev/null | grep -q 'inet ' || continue
    router=$(ipconfig getoption "$iface" router 2>/dev/null)
    if [ -n "$router" ]; then printf '%s\n' "$router"; return 0; fi
  done
  return 1
}
