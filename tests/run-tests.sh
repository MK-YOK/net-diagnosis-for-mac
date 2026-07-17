#!/bin/bash
# Zero-dependency test harness for scripts/lib/net-common.sh pure helpers.
# No bats/framework. Run: ./tests/run-tests.sh   (exit 0 = all pass)
set -uo pipefail
cd "$(dirname "$0")" || exit 1
. "../scripts/lib/net-common.sh"

PASS=0; FAIL=0
pass() { PASS=$((PASS+1)); }
fail() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
assert_eq()    { if [ "$2" = "$3" ]; then pass; else fail "$1 — expected [$2] got [$3]"; fi; }
assert_true()  { d="$1"; shift; if "$@"; then pass; else fail "$d (expected success)"; fi; }
assert_false() { d="$1"; shift; if "$@"; then fail "$d (expected failure)"; else pass; fi; }

# --- ping_loss / ping_avg (stdin parsers) ---
GW_SAMPLE='PING 192.168.0.1: 56 data bytes
64 bytes from 192.168.0.1: icmp_seq=0 ttl=64 time=2.1 ms
--- 192.168.0.1 ping statistics ---
3 packets transmitted, 3 packets received, 0.0% packet loss
round-trip min/avg/max/stddev = 1.9/2.4/3.1/0.5 ms'
assert_eq "ping_loss parses 0.0%" "0.0" "$(printf '%s\n' "$GW_SAMPLE" | ping_loss)"
assert_eq "ping_avg parses 2.4"   "2.4" "$(printf '%s\n' "$GW_SAMPLE" | ping_avg)"

LOSS_SAMPLE='--- 1.1.1.1 ping statistics ---
5 packets transmitted, 3 packets received, 40.0% packet loss
round-trip min/avg/max/stddev = 10.0/20.0/30.0/5.0 ms'
assert_eq "ping_loss parses 40.0%" "40.0" "$(printf '%s\n' "$LOSS_SAMPLE" | ping_loss)"

# --- parse_duration ---
assert_eq "parse_duration 30m"  "1800" "$(parse_duration 30m)"
assert_eq "parse_duration 45s"  "45"   "$(parse_duration 45s)"
assert_eq "parse_duration 2h"   "7200" "$(parse_duration 2h)"
assert_eq "parse_duration 90"   "90"   "$(parse_duration 90)"
assert_false "parse_duration rejects abc" parse_duration abc
assert_false "parse_duration rejects empty" parse_duration ""
assert_false "parse_duration rejects 5x" parse_duration 5x

# --- exceeds <value> <threshold> : true when value > threshold ---
assert_true  "exceeds 312 > 50"      exceeds 312 50
assert_false "exceeds 10 not > 50"   exceeds 10 50
assert_false "exceeds equal not >"   exceeds 50 50
assert_true  "exceeds 0.1 > 0"       exceeds 0.1 0
assert_false "exceeds n/a not >"     exceeds n/a 50
assert_false "exceeds empty not >"   exceeds "" 50

# --- classify_route <iface> <cato_present 0|1> : pure classifier ---
assert_eq "utun + cato -> cato"   "cato"    "$(classify_route utun5 1)"
assert_eq "utun no cato -> vpn"   "vpn"     "$(classify_route utun5 0)"
assert_eq "en0 -> direct"         "direct"  "$(classify_route en0 0)"
assert_eq "en0 + cato -> direct"  "direct"  "$(classify_route en0 1)"
assert_eq "empty iface -> unknown" "unknown" "$(classify_route "" 0)"

# --- ping_probe <host> <count> : "LOSS AVG" from one ping sample ---
read PB_LOSS PB_AVG <<PBEOF
$(ping_probe 127.0.0.1 2)
PBEOF
assert_eq "loopback loss is 0.0" "0.0" "$PB_LOSS"
assert_false "loopback avg is numeric (not n/a)" [ "$PB_AVG" = "n/a" ]

# --- load_thresholds : env > conf > built-in fallback ---
LIB="$PWD/../scripts/lib/net-common.sh"   # $PWD is tests/ (harness cd'd here)
CONF_DIR=$(mktemp -d)
cat > "$CONF_DIR/net-monitor.conf" <<'CONFEOF'
: "${GW_SPIKE_MS:=77}"
: "${PING_COUNT:=9}"
CONFEOF

# conf wins when env is unset
V=$( cd "$CONF_DIR" && . "$LIB" && load_thresholds && echo "$GW_SPIKE_MS" )
assert_eq "conf sets GW_SPIKE_MS" "77" "$V"

# env wins over conf
V=$( cd "$CONF_DIR" && export GW_SPIKE_MS=30 && . "$LIB" && load_thresholds && echo "$GW_SPIKE_MS" )
assert_eq "env overrides conf" "30" "$V"

# built-in fallback for a key not present in the conf (EXT_SPIKE_MS)
V=$( cd "$CONF_DIR" && . "$LIB" && load_thresholds && echo "$EXT_SPIKE_MS" )
assert_eq "built-in EXT_SPIKE_MS fallback" "150" "$V"

rm -rf "$CONF_DIR"

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
