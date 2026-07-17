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
assert_true()  { local d="$1"; shift; if "$@"; then pass; else fail "$d (expected success)"; fi; }
assert_false() { local d="$1"; shift; if "$@"; then fail "$d (expected failure)"; else pass; fi; }

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

# --- ping_probe timeout must scale with count (regression: fixed -t 5 truncated) ---
PING_ARGS_FILE=$(mktemp)
ping() {
  printf '%s\n' "$*" > "$PING_ARGS_FILE"
  cat <<'FAKEPING'
--- fakehost ping statistics ---
6 packets transmitted, 6 packets received, 0.0% packet loss
round-trip min/avg/max/stddev = 1.0/2.0/3.0/0.1 ms
FAKEPING
}
ping_probe fakehost 6 >/dev/null
unset -f ping
TVAL=$(grep -oE '\-t [0-9]+' "$PING_ARGS_FILE" | grep -oE '[0-9]+$')
assert_true "ping_probe -t scales with count (>=6)" [ "${TVAL:-0}" -ge 6 ]
rm -f "$PING_ARGS_FILE"

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

# --- 16->17 col header migration (logic mirrored from net-log-run.sh) ---
OLD_HEADER='timestamp,interface,link_status,has_ip,gateway_ip,gateway_loss_pct,gateway_avg_ms,dns_ok,dns_query_ms,ext_ip_loss_pct,ext_ip_avg_ms,ext_host_loss_pct,ext_host_avg_ms,wifi_rssi,wifi_noise,wifi_channel'
NEW_HEADER="$OLD_HEADER,default_route"
MIG_DIR=$(mktemp -d)
printf '%s\n%s\n' "$OLD_HEADER" "2026-01-01T00:00:00Z,en0,active,1,192.168.0.1,0.0,2.0,1,5,0.0,10.0,0.0,12.0,-55,-90,36" > "$MIG_DIR/history.csv"
# migration one-liner:
if [ "$(head -1 "$MIG_DIR/history.csv")" = "$OLD_HEADER" ]; then
  tmpf=$(mktemp); { echo "$NEW_HEADER"; tail -n +2 "$MIG_DIR/history.csv"; } > "$tmpf" && mv "$tmpf" "$MIG_DIR/history.csv"
fi
assert_eq "header migrated to 17 cols" "$NEW_HEADER" "$(head -1 "$MIG_DIR/history.csv")"
assert_eq "old data row preserved" "2" "$(wc -l < "$MIG_DIR/history.csv" | tr -d ' ')"
rm -rf "$MIG_DIR"

# --- report tolerates n/a avg + mixed 16/17-col rows (real script, fixture swapped in) ---
REAL="../logs/history.csv"
mkdir -p ../logs
BAK=""
if [ -f "$REAL" ]; then BAK=$(mktemp); cp "$REAL" "$BAK"; fi
cat > "$REAL" <<'REPEOF'
timestamp,interface,link_status,has_ip,gateway_ip,gateway_loss_pct,gateway_avg_ms,dns_ok,dns_query_ms,ext_ip_loss_pct,ext_ip_avg_ms,ext_host_loss_pct,ext_host_avg_ms,wifi_rssi,wifi_noise,wifi_channel,default_route
2026-01-01T00:00:00Z,en0,active,1,192.168.0.1,0.0,2.0,1,5,0.0,10.0,0.0,12.0,-55,-90,36
2026-01-01T00:05:00Z,utun5,active,1,192.168.0.1,100,n/a,1,5,0.0,20.0,0.0,22.0,-55,-90,36,cato
REPEOF
OUT=$(../scripts/net-history-report.sh 2>&1); RC=$?
assert_eq "report exits 0 on n/a + mixed rows" "0" "$RC"
if printf '%s' "$OUT" | grep -qi 'awk:'; then fail "report emitted an awk error"; else pass; fi
if [ -n "$BAK" ]; then mv "$BAK" "$REAL"; else rm -f "$REAL"; fi

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
