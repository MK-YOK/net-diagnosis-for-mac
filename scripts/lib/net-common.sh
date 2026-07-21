#!/bin/bash
# Shared helpers for net-diagnosis-for-mac. SOURCED by entry scripts (run.sh's
# children, net-vpn-check.sh, net-monitor.sh) — never executed directly.
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
# The guard rejects obvious non-numerics; it does not fully validate number
# format (callers only pass single decimals).
exceeds() {
  local value="$1" threshold="$2"
  case "$value" in
    ''|n/a) return 1 ;;
    *[!0-9.]*) return 1 ;;
  esac
  awk -v v="$value" -v t="$threshold" 'BEGIN { exit !(v > t) }'
}

# classify_route <iface> : pure classifier.
# -> vpn | direct | unknown
classify_route() {
  local iface="$1"
  if [ -z "$iface" ]; then printf 'unknown\n'; return; fi
  case "$iface" in
    utun*) printf 'vpn\n' ;;
    *) printf 'direct\n' ;;
  esac
}

# default_route_class : wire the real route command into classify_route.
default_route_class() {
  local iface
  iface=$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')
  classify_route "$iface"
}

# ping_probe <host> <count> : run ONE ping batch and echo "LOSS AVG" derived
# from the same sample. AVG is "n/a" when nothing returned (100% loss); LOSS
# defaults to "100" if the summary can't be parsed at all (e.g. unknown host).
ping_probe() {
  local host="$1" count="$2" out loss avg
  out=$(ping -c "$count" -t "$((count + 3))" "$host" 2>&1)
  loss=$(printf '%s\n' "$out" | ping_loss)
  avg=$(printf '%s\n' "$out" | ping_avg)
  [ -z "$loss" ] && loss="100"
  [ -z "$avg" ] && avg="n/a"
  printf '%s %s\n' "$loss" "$avg"
}

# physical_gateway : echo the physical LAN router IP, independent of any VPN.
# When a VPN holds the default route via utun, `route -n get default` has no
# gateway line, so we ask the active hardware interface for its router.
# Honors an explicit GATEWAY override (from net-monitor.conf / env).
# Returns 1 (no output) if none found.
# Caveat: on multi-homed setups (e.g. Wi-Fi + USB-Ethernet both up) this
# picks the first active en* by enumeration order, which may not be the
# interface actually carrying traffic. Fine for a single-link laptop.
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

# load_thresholds : populate threshold/tick vars with precedence
#   env (already set) > ./net-monitor.conf > built-in fallback below.
# Callers cd into scripts/ first, so the conf is at ./net-monitor.conf.
# All three layers use guarded assignment, so an already-set env var is never
# overwritten by the conf or the fallback.
load_thresholds() {
  if [ -f "./net-monitor.conf" ]; then . "./net-monitor.conf"; fi
  : "${GW_SPIKE_MS:=50}"
  : "${GW_LOSS_PCT:=0}"
  : "${EXT_SPIKE_MS:=150}"
  : "${EXT_LOSS_PCT:=0}"
  : "${PING_COUNT:=5}"
  : "${GATEWAY:=}"
}
