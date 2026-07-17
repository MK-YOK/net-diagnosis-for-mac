# Cato Detection & Continuous Monitoring Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add Cato/VPN default-route detection and a foreground continuous-monitor mode to net-diagnosis-for-mac, sharing one library so snapshot and monitor use the same probe/threshold/route logic.

**Architecture:** A new `scripts/lib/net-common.sh` holds pure, testable helpers (ping-output parsers, a route classifier, duration/threshold logic) plus thin command wrappers (`ping_probe`, `physical_gateway`, `default_route_class`, `load_thresholds`). A new `net-cato-check.sh` reports who owns the default route (recommend-only, never disconnects). A new `net-monitor.sh` loops small parallel ping batches and prints a timestamped line only on threshold breach. `run.sh` gains the cato step; `net-log-run.sh` and `net-history-report.sh` gain a 17th `default_route` CSV column with backward compatibility.

**Tech Stack:** POSIX-ish Bash **3.2** (macOS system bash — no associative arrays, no `${var,,}`), standard macOS CLI tools (`route`, `ifconfig`, `ipconfig`, `pgrep`, `ping`, `awk`, `sed`, `grep`). No external test framework — a self-contained bash harness under `tests/`.

**Spec:** `docs/superpowers/specs/2026-07-17-cato-and-monitoring-design.md`

---

## File Structure

Created:
- `scripts/lib/net-common.sh` — shared helpers (sourced, never executed). One responsibility: the reusable probe/classify/threshold logic.
- `scripts/net-cato-check.sh` — default-route ownership report (Cato/VPN/direct/unknown).
- `scripts/net-monitor.sh` — foreground continuous monitor.
- `scripts/net-monitor.conf` — thresholds & tick config (committed; guarded assignment).
- `tests/run-tests.sh` — zero-dependency test harness for the pure helpers.

Modified:
- `scripts/run.sh` — insert cato step (interface → cato → connectivity → wifi).
- `scripts/net-log-run.sh` — source lib, use `physical_gateway`/`ping_probe`, add `default_route` column, migrate old 16-col header.
- `scripts/net-history-report.sh` — tolerate old 16-col rows and `n/a` avg values.
- `CLAUDE.md` — interpretation guidance for Cato / physical GW / monitor.
- `README.md` — document the two new commands.

**Conventions to follow (from existing scripts):** each script starts with a "what / read-only / no side effects" comment block, then `set -uo pipefail`, then `cd "$(dirname "$0")" || exit 1`. Entry scripts live in `scripts/` and `cd` into it, so the config file is reachable as `./net-monitor.conf` and the library as `./lib/net-common.sh`.

---

## Task 1: Test harness + `net-common.sh` with ping-output parsers

**Files:**
- Create: `tests/run-tests.sh`
- Create: `scripts/lib/net-common.sh`

- [ ] **Step 1: Write the failing test** — create `tests/run-tests.sh`

```bash
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

echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
```

- [ ] **Step 2: Run test to verify it fails**

Run: `chmod +x tests/run-tests.sh && ./tests/run-tests.sh`
Expected: FAIL — `../scripts/lib/net-common.sh` does not exist, source fails / functions undefined.

- [ ] **Step 3: Write minimal implementation** — create `scripts/lib/net-common.sh`

```bash
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./tests/run-tests.sh`
Expected: `PASS=3 FAIL=0`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add tests/run-tests.sh scripts/lib/net-common.sh
git commit -m "Add test harness and net-common.sh ping parsers"
```

---

## Task 2: `parse_duration` helper

**Files:**
- Modify: `scripts/lib/net-common.sh`
- Modify: `tests/run-tests.sh`

- [ ] **Step 1: Write the failing test** — insert before the final `echo "PASS=..."` line in `tests/run-tests.sh`

```bash
# --- parse_duration ---
assert_eq "parse_duration 30m"  "1800" "$(parse_duration 30m)"
assert_eq "parse_duration 45s"  "45"   "$(parse_duration 45s)"
assert_eq "parse_duration 2h"   "7200" "$(parse_duration 2h)"
assert_eq "parse_duration 90"   "90"   "$(parse_duration 90)"
assert_false "parse_duration rejects abc" parse_duration abc
assert_false "parse_duration rejects empty" parse_duration ""
assert_false "parse_duration rejects 5x" parse_duration 5x
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./tests/run-tests.sh`
Expected: FAIL lines for the `parse_duration` asserts (`parse_duration: command not found`).

- [ ] **Step 3: Write minimal implementation** — append to `scripts/lib/net-common.sh`

```bash
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./tests/run-tests.sh`
Expected: `PASS=10 FAIL=0`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/net-common.sh tests/run-tests.sh
git commit -m "Add parse_duration helper"
```

---

## Task 3: `exceeds` threshold comparator

**Files:**
- Modify: `scripts/lib/net-common.sh`
- Modify: `tests/run-tests.sh`

- [ ] **Step 1: Write the failing test** — insert before the final `echo "PASS=..."` line

```bash
# --- exceeds <value> <threshold> : true when value > threshold ---
assert_true  "exceeds 312 > 50"      exceeds 312 50
assert_false "exceeds 10 not > 50"   exceeds 10 50
assert_false "exceeds equal not >"   exceeds 50 50
assert_true  "exceeds 0.1 > 0"       exceeds 0.1 0
assert_false "exceeds n/a not >"     exceeds n/a 50
assert_false "exceeds empty not >"   exceeds "" 50
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./tests/run-tests.sh`
Expected: FAIL lines for the `exceeds` asserts (`exceeds: command not found`).

- [ ] **Step 3: Write minimal implementation** — append to `scripts/lib/net-common.sh`

```bash
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./tests/run-tests.sh`
Expected: `PASS=16 FAIL=0`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/net-common.sh tests/run-tests.sh
git commit -m "Add exceeds threshold comparator"
```

---

## Task 4: `classify_route` (pure) + `default_route_class` (wired)

**Files:**
- Modify: `scripts/lib/net-common.sh`
- Modify: `tests/run-tests.sh`

- [ ] **Step 1: Write the failing test** — insert before the final `echo "PASS=..."` line

```bash
# --- classify_route <iface> <cato_present 0|1> : pure classifier ---
assert_eq "utun + cato -> cato"   "cato"    "$(classify_route utun5 1)"
assert_eq "utun no cato -> vpn"   "vpn"     "$(classify_route utun5 0)"
assert_eq "en0 -> direct"         "direct"  "$(classify_route en0 0)"
assert_eq "en0 + cato -> direct"  "direct"  "$(classify_route en0 1)"
assert_eq "empty iface -> unknown" "unknown" "$(classify_route "" 0)"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./tests/run-tests.sh`
Expected: FAIL lines for the `classify_route` asserts.

- [ ] **Step 3: Write minimal implementation** — append to `scripts/lib/net-common.sh`

```bash
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
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./tests/run-tests.sh`
Expected: `PASS=21 FAIL=0`, exit 0.

- [ ] **Step 5: Manually verify the wired version on this machine**

Run: `cd scripts && . ./lib/net-common.sh && default_route_class; cd ..`
Expected: prints `cato` if Cato is connected (utun default route + CatoClient running), else `direct`/`vpn`/`unknown`. Confirm it matches `route -n get default | grep interface` and `pgrep -f CatoClient`.

- [ ] **Step 6: Commit**

```bash
git add scripts/lib/net-common.sh tests/run-tests.sh
git commit -m "Add route classifier (classify_route/default_route_class)"
```

---

## Task 5: `ping_probe` (same-sample loss + avg)

**Files:**
- Modify: `scripts/lib/net-common.sh`
- Modify: `tests/run-tests.sh`

- [ ] **Step 1: Write the failing test** — insert before the final `echo "PASS=..."` line

Uses loopback so it is deterministic and network-independent.

```bash
# --- ping_probe <host> <count> : "LOSS AVG" from one ping sample ---
read PB_LOSS PB_AVG <<PBEOF
$(ping_probe 127.0.0.1 2)
PBEOF
assert_eq "loopback loss is 0.0" "0.0" "$PB_LOSS"
assert_false "loopback avg is numeric (not n/a)" [ "$PB_AVG" = "n/a" ]

# --- ping_probe timeout must scale with count (regression: a fixed -t 5 would
#     truncate the run to ~5 packets and report a clean result). Shadow `ping`
#     to capture its args, so this is network-independent.
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
```

- [ ] **Step 2: Run test to verify it fails**

Run: `./tests/run-tests.sh`
Expected: FAIL lines for the `ping_probe` asserts (`ping_probe: command not found`).

- [ ] **Step 3: Write minimal implementation** — append to `scripts/lib/net-common.sh`

```bash
# ping_probe <host> <count> : run ONE ping batch and echo "LOSS AVG" derived
# from the same sample. AVG is "n/a" when nothing returned (100% loss); LOSS
# defaults to "100" if the summary can't be parsed at all (e.g. unknown host).
# The overall timeout scales with count (macOS -t is a whole-run deadline), so
# a larger PING_COUNT is never silently truncated.
ping_probe() {
  local host="$1" count="$2" out loss avg
  out=$(ping -c "$count" -t "$((count + 3))" "$host" 2>&1)
  loss=$(printf '%s\n' "$out" | ping_loss)
  avg=$(printf '%s\n' "$out" | ping_avg)
  [ -z "$loss" ] && loss="100"
  [ -z "$avg" ] && avg="n/a"
  printf '%s %s\n' "$loss" "$avg"
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `./tests/run-tests.sh`
Expected: `PASS=24 FAIL=0`, exit 0.

- [ ] **Step 5: Commit**

```bash
git add scripts/lib/net-common.sh tests/run-tests.sh
git commit -m "Add ping_probe (same-sample loss+avg)"
```

---

## Task 6: `physical_gateway` (LAN router, independent of VPN default route)

**Files:**
- Modify: `scripts/lib/net-common.sh`

No unit test (it reads live interface state); verified by smoke test on this machine.

- [ ] **Step 1: Write minimal implementation** — append to `scripts/lib/net-common.sh`

```bash
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
```

- [ ] **Step 2: Smoke-verify on this machine**

Run: `cd scripts && . ./lib/net-common.sh && physical_gateway; cd ..`
Expected: prints the LAN router (e.g. `192.168.0.1`) **even while Cato is connected**. Cross-check: `ipconfig getoption en0 router`. Confirm it is non-empty and matches.

- [ ] **Step 3: Commit**

```bash
git add scripts/lib/net-common.sh
git commit -m "Add physical_gateway (VPN-independent LAN router discovery)"
```

---

## Task 7: `net-monitor.conf` + `load_thresholds` (env > conf > built-in)

**Files:**
- Create: `scripts/net-monitor.conf`
- Modify: `scripts/lib/net-common.sh`
- Modify: `tests/run-tests.sh`

- [ ] **Step 1: Write the failing test** — insert before the final `echo "PASS=..."` line

Runs each case in a subshell with a temp conf so state does not leak.

```bash
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
```

Note: each subshell `cd`s into `$CONF_DIR` so `load_thresholds` finds `./net-monitor.conf` there, while `$LIB` (captured before the cd) still points at the repo's library.

- [ ] **Step 2: Run test to verify it fails**

Run: `./tests/run-tests.sh`
Expected: FAIL lines for the `load_thresholds` asserts (`load_thresholds: command not found`).

- [ ] **Step 3: Create `scripts/net-monitor.conf`**

```bash
# net-monitor.conf — thresholds & tick config for net-monitor.sh.
# Sourced by net-common.sh's load_thresholds(). Uses guarded assignment
# (: "${VAR:=...}") so a command-line/env override wins over these defaults.
: "${GW_SPIKE_MS:=50}"    # GW ping avg (ms) above this = anomaly
: "${GW_LOSS_PCT:=0}"     # GW packet loss (%) above this = anomaly
: "${EXT_SPIKE_MS:=150}"  # external (1.1.1.1) avg (ms)
: "${EXT_LOSS_PCT:=0}"    # external loss (%)
: "${PING_COUNT:=5}"      # pings per host per tick
: "${GATEWAY:=}"          # explicit physical GW; empty = auto-detect
```

- [ ] **Step 4: Add `load_thresholds`** — append to `scripts/lib/net-common.sh`

```bash
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
```

- [ ] **Step 5: Run test to verify it passes**

Run: `./tests/run-tests.sh`
Expected: `PASS=27 FAIL=0`, exit 0.

- [ ] **Step 6: Commit**

```bash
git add scripts/net-monitor.conf scripts/lib/net-common.sh tests/run-tests.sh
git commit -m "Add net-monitor.conf and load_thresholds with env>conf>default precedence"
```

---

## Task 8: `net-cato-check.sh`

**Files:**
- Create: `scripts/net-cato-check.sh`

- [ ] **Step 1: Write the implementation**

```bash
#!/bin/bash
# Read-only: reports whether a VPN tunnel — specifically Cato — currently owns
# the default route, so triage can start by ruling it in or out. It only
# RECOMMENDS a manual before/after comparison; it never disconnects anything
# (Cato disconnect is a user action, like a router restart). Part of the
# net-diagnosis-for-mac pass (see run.sh). No side effects.

set -uo pipefail
cd "$(dirname "$0")" || exit 1
. "./lib/net-common.sh"

echo "== Default route owner (Cato / VPN check) =="

iface=$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')
class=$(default_route_class)
inet=$(ifconfig "$iface" 2>/dev/null | awk '/inet /{print $2; exit}')
[ -z "$inet" ] && inet="n/a"

case "$class" in
  cato)
    echo "[cato] デフォルト経路は Cato 経由の可能性が高い ($iface, inet $inet)"
    echo "       重い場合はまず Cato を手動で切って before/after を比較してください（切断は user 操作）。"
    ;;
  vpn)
    echo "[vpn] VPN トンネル($iface)が経路を握っています（Cato ではなさそう, inet $inet）。"
    echo "      重い場合は VPN を手動で切って before/after を比較してください（切断は user 操作）。"
    ;;
  direct)
    echo "[direct] デフォルト経路は物理インターフェース経由（VPN トンネルなし）。"
    ;;
  unknown)
    echo "[unknown] デフォルト経路が取得できません（インターフェース down 等の可能性）。"
    ;;
esac
```

- [ ] **Step 2: Make executable and smoke-verify**

Run: `chmod +x scripts/net-cato-check.sh && ./scripts/net-cato-check.sh`
Expected: prints the `== Default route owner ==` header and one bracketed line matching reality (on this machine, `[cato] ... (utunN, inet 10.x)` while Cato is connected). No errors, exit 0.

- [ ] **Step 3: Commit**

```bash
git add scripts/net-cato-check.sh
git commit -m "Add net-cato-check.sh (default-route owner report)"
```

---

## Task 9: Insert cato step into `run.sh`

**Files:**
- Modify: `scripts/run.sh:14-18`

- [ ] **Step 1: Edit `run.sh`** — change the run sequence so cato runs after interface, before connectivity. Replace:

```bash
./net-interface-check.sh
echo
./net-connectivity-check.sh
echo
./net-wifi-check.sh
```

with:

```bash
./net-interface-check.sh
echo
./net-cato-check.sh
echo
./net-connectivity-check.sh
echo
./net-wifi-check.sh
```

- [ ] **Step 2: Smoke-verify order**

Run: `./scripts/run.sh`
Expected: sections print in order interface → **cato** → connectivity → wifi, then the "(logged to logs/history.csv …)" line. No errors.

- [ ] **Step 3: Commit**

```bash
git add scripts/run.sh
git commit -m "Run net-cato-check after interface check in run.sh"
```

---

## Task 10: `net-log-run.sh` — shared lib, physical GW, `default_route` column, header migration

**Files:**
- Modify: `scripts/net-log-run.sh` (full rewrite of the body)

- [ ] **Step 1: Write a header-migration test** — insert before the final `echo "PASS=..."` line in `tests/run-tests.sh`

This tests the migration logic in isolation (same one-liner the script uses), without running network probes.

```bash
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
```

- [ ] **Step 2: Run test to verify it passes as a spec of the behavior**

Run: `./tests/run-tests.sh`
Expected: `PASS=29 FAIL=0`. (This asserts the migration one-liner is correct before we embed it in the script.)

- [ ] **Step 3: Rewrite `scripts/net-log-run.sh`** — full file:

```bash
#!/bin/bash
# Runs the same core probes as the connectivity/wifi checks, but parses the
# results into one CSV row appended to logs/history.csv instead of printing
# for a human. Called from run.sh on every pass, so history builds up over
# time — no cron/launchd needed. Read-only aside from appending to that log.
# Gateway is the PHYSICAL LAN router (see physical_gateway) so the GW figure
# is meaningful even when a VPN (Cato) owns the default route.

set -uo pipefail
cd "$(dirname "$0")" || exit 1
. "./lib/net-common.sh"

LOG_DIR="../logs"
LOG_FILE="$LOG_DIR/history.csv"
HEADER="timestamp,interface,link_status,has_ip,gateway_ip,gateway_loss_pct,gateway_avg_ms,dns_ok,dns_query_ms,ext_ip_loss_pct,ext_ip_avg_ms,ext_host_loss_pct,ext_host_avg_ms,wifi_rssi,wifi_noise,wifi_channel,default_route"
OLD_HEADER="timestamp,interface,link_status,has_ip,gateway_ip,gateway_loss_pct,gateway_avg_ms,dns_ok,dns_query_ms,ext_ip_loss_pct,ext_ip_avg_ms,ext_host_loss_pct,ext_host_avg_ms,wifi_rssi,wifi_noise,wifi_channel"

mkdir -p "$LOG_DIR"
if [ ! -f "$LOG_FILE" ]; then
  echo "$HEADER" > "$LOG_FILE"
elif [ "$(head -1 "$LOG_FILE")" = "$OLD_HEADER" ]; then
  # migrate old 16-col header to the new 17-col header, keep existing rows.
  # temp file lives in LOG_DIR so the mv is a same-filesystem atomic rename.
  tmpf=$(mktemp "$LOG_DIR/.history.csv.XXXXXX")
  { echo "$HEADER"; tail -n +2 "$LOG_FILE"; } > "$tmpf" && mv "$tmpf" "$LOG_FILE"
fi

TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# -- interface owning the default route --
IFACE=$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')
LINK_STATUS=""
HAS_IP=0
if [ -n "$IFACE" ]; then
  LINK_STATUS=$(ifconfig "$IFACE" 2>/dev/null | awk '/status:/{print $2}')
  ifconfig "$IFACE" 2>/dev/null | grep -q "inet " && HAS_IP=1
fi

# -- default route classification (cato/vpn/direct/unknown) --
DEFAULT_ROUTE=$(default_route_class)

# -- gateway: physical LAN router, independent of any VPN default route --
GATEWAY=$(physical_gateway || true)
GW_LOSS=""
GW_AVG=""
if [ -n "$GATEWAY" ]; then
  read GW_LOSS GW_AVG <<EOF
$(ping_probe "$GATEWAY" 3)
EOF
fi

# -- DNS --
dig_output=$(dig +time=3 +tries=1 apple.com 2>/dev/null)
DNS_OK=0
echo "$dig_output" | grep -qE 'ANSWER: [1-9]' && DNS_OK=1
DNS_MS=$(echo "$dig_output" | awk '/Query time:/{print $4}')

# -- external reachability --
read EXTIP_LOSS EXTIP_AVG <<EOF
$(ping_probe 1.1.1.1 3)
EOF
read EXTHOST_LOSS EXTHOST_AVG <<EOF
$(ping_probe apple.com 3)
EOF

# -- Wi-Fi (blank fields if not on Wi-Fi or wdutil needs a password) --
WIFI_RSSI=""
WIFI_NOISE=""
WIFI_CHANNEL=""
if command -v wdutil >/dev/null 2>&1; then
  wifi_info=$(sudo -n wdutil info 2>/dev/null | grep -A 20 "WIFI")
  WIFI_RSSI=$(echo "$wifi_info" | awk -F': ' '/RSSI/{print $2}' | grep -oE '\-?[0-9]+')
  WIFI_NOISE=$(echo "$wifi_info" | awk -F': ' '/Noise/{print $2}' | grep -oE '\-?[0-9]+')
  WIFI_CHANNEL=$(echo "$wifi_info" | awk -F': ' '/Channel/{print $2}' | grep -oE '^[0-9]+')
fi

echo "$TIMESTAMP,$IFACE,$LINK_STATUS,$HAS_IP,$GATEWAY,$GW_LOSS,$GW_AVG,$DNS_OK,$DNS_MS,$EXTIP_LOSS,$EXTIP_AVG,$EXTHOST_LOSS,$EXTHOST_AVG,$WIFI_RSSI,$WIFI_NOISE,$WIFI_CHANNEL,$DEFAULT_ROUTE" >> "$LOG_FILE"
```

- [ ] **Step 4: Verify end-to-end on this machine**

Run: `rm -f logs/history.csv; ./scripts/run.sh && tail -1 logs/history.csv && head -1 logs/history.csv`
Expected: header has 17 fields ending in `default_route`; the appended row has 17 comma-separated fields; `gateway_ip` is the physical router (e.g. `192.168.0.1`) and non-empty even with Cato up; the last field is `cato`/`direct`/`vpn`/`unknown`. Verify field count:
`head -1 logs/history.csv | awk -F, '{print NF}'` → `17`; `tail -1 logs/history.csv | awk -F, '{print NF}'` → `17`.

- [ ] **Step 5: Commit**

```bash
git add scripts/net-log-run.sh tests/run-tests.sh
git commit -m "Log default_route + physical gateway; migrate 16->17 col CSV header"
```

---

## Task 11: `net-history-report.sh` — tolerate old rows and `n/a` avg

**Files:**
- Modify: `scripts/net-history-report.sh:23-56` (the awk block)

Rationale: `ping_probe` now emits `n/a` for avg on 100% loss. Old 16-column rows may also predate `default_route`. The trend awk reads columns ≤13 (present in both layouts), so old rows are already safe there — but `n/a` in an avg column would be coerced to 0 by awk and skew averages. Fix: treat `n/a` like an empty/missing value.

- [ ] **Step 1: Write a fixture-based test** — insert before the final `echo "PASS=..."` line in `tests/run-tests.sh`

The report always reads `../logs/history.csv` relative to its own dir, so the test temporarily swaps in a fixture there and restores the real file afterward (`logs/` is gitignored; the fixture has a 16-col old row and a 17-col row whose gateway avg is `n/a`).

```bash
# --- report tolerates n/a avg + mixed 16/17-col rows (real script, fixture swapped in) ---
REAL="../logs/history.csv"
mkdir -p ../logs
BAK=""
if [ -f "$REAL" ]; then BAK=$(mktemp); cp "$REAL" "$BAK"; fi
# Guard the real history file: restore on normal end AND on interruption
# (Ctrl-C/crash) so the test can never clobber the user's real trend data.
restore_hist() { if [ -n "$BAK" ]; then mv "$BAK" "$REAL"; else rm -f "$REAL"; fi; }
trap restore_hist EXIT
cat > "$REAL" <<'REPEOF'
timestamp,interface,link_status,has_ip,gateway_ip,gateway_loss_pct,gateway_avg_ms,dns_ok,dns_query_ms,ext_ip_loss_pct,ext_ip_avg_ms,ext_host_loss_pct,ext_host_avg_ms,wifi_rssi,wifi_noise,wifi_channel,default_route
2026-01-01T00:00:00Z,en0,active,1,192.168.0.1,0.0,2.0,1,5,0.0,10.0,0.0,12.0,-55,-90,36
2026-01-01T00:05:00Z,utun5,active,1,192.168.0.1,100,n/a,1,5,0.0,20.0,0.0,22.0,-55,-90,36,cato
REPEOF
OUT=$(../scripts/net-history-report.sh 2>&1); RC=$?
assert_eq "report exits 0 on n/a + mixed rows" "0" "$RC"
if printf '%s' "$OUT" | grep -qi 'awk:'; then fail "report emitted an awk error"; else pass; fi
restore_hist
trap - EXIT
```

- [ ] **Step 2: Run test to verify current behavior**

Run: `./tests/run-tests.sh`
Expected: exit code 0 and no `awk:` error even with the current report (the pre-fix risk is a skewed average, not a crash). These two asserts lock in "no regression"; the correctness fix below is confirmed by the Step 4 smoke check.

- [ ] **Step 3: Patch the awk block** — in `scripts/net-history-report.sh`, update the field-capture and `avg()` function so `n/a` is treated as missing. Replace the capture block:

```awk
{
  n++
  gw_avg[n]=$7; gw_loss[n]=$6
  extip_avg[n]=$11; extip_loss[n]=$10
  exthost_avg[n]=$13; exthost_loss[n]=$12
  ts[n]=$1
}
```

with (normalize `n/a` to empty on capture):

```awk
{
  n++
  gw_avg[n]=($7=="n/a")?"":$7; gw_loss[n]=($6=="n/a")?"":$6
  extip_avg[n]=($11=="n/a")?"":$11; extip_loss[n]=($10=="n/a")?"":$10
  exthost_avg[n]=($13=="n/a")?"":$13; exthost_loss[n]=($12=="n/a")?"":$12
  ts[n]=$1
}
```

The existing `avg()` already skips `arr[i] != ""`, so normalized `n/a`→`""` values are correctly excluded. The `report()` function already prints `latest=n/a` when the latest captured value is empty (`cur == ""`), so a 100%-loss latest run reads cleanly.

- [ ] **Step 4: Run test + smoke check**

Run: `./tests/run-tests.sh`
Expected: `PASS=31 FAIL=0`.
Then: `./scripts/net-history-report.sh`
Expected: no `awk:` errors; the last-N table shows the `default_route` column (via `column -t`), and rows with `n/a` avg don't distort the trend deltas.

- [ ] **Step 5: Commit**

```bash
git add scripts/net-history-report.sh tests/run-tests.sh
git commit -m "Report: treat n/a avg as missing; keep old rows safe"
```

---

## Task 12: `net-monitor.sh` (foreground continuous monitor)

**Files:**
- Create: `scripts/net-monitor.sh`

No unit test for the loop itself (long-running, network-bound). Its logic pieces (`parse_duration`, `exceeds`, `ping_probe`, `physical_gateway`, `default_route_class`, `load_thresholds`) are already tested in Tasks 2–7. Verified here by a short real run.

- [ ] **Step 1: Write the implementation**

```bash
#!/bin/bash
# Read-only continuous monitor. Every tick it pings the physical gateway and
# an external host (1.1.1.1) IN PARALLEL, and prints a timestamped line ONLY
# when latency or loss crosses a threshold — to catch intermittent faults in
# the act. Quiet while healthy (a periodic liveness line). An optional
# duration arg (e.g. 30m / 45s / 2h / bare seconds) stops it; otherwise Ctrl-C
# stops it. Either way it prints a summary. Anomaly lines are also appended to
# logs/monitor-YYYYMMDD.log. No side effects beyond that append. Thresholds
# come from net-monitor.conf (env vars override). See CLAUDE.md.

set -uo pipefail
cd "$(dirname "$0")" || exit 1
. "./lib/net-common.sh"

load_thresholds

DURATION_SECS=0
if [ "$#" -ge 1 ]; then
  DURATION_SECS=$(parse_duration "$1") || {
    echo "Invalid duration: $1 (use 30m / 45s / 2h / bare seconds)" >&2
    exit 1
  }
fi

LOG_DIR="../logs"
mkdir -p "$LOG_DIR"
MON_LOG="$LOG_DIR/monitor-$(date +%Y%m%d).log"

START=$(date +%s)
TICKS=0
ANOMALIES=0
WORST_GW=0
WORST_EXT=0

emit() { echo "$1"; echo "$1" >> "$MON_LOG"; }

summary() {
  local now elapsed
  now=$(date +%s); elapsed=$((now - START))
  echo
  echo "== 監視サマリ =="
  echo "監視時間: ${elapsed}s / tick 数: $TICKS / 異常検知: $ANOMALIES 件"
  echo "最悪 GW avg: ${WORST_GW}ms / 最悪 EXT avg: ${WORST_EXT}ms"
  echo "異常ログ: $MON_LOG"
  exit 0
}
trap summary INT

echo "監視開始（Ctrl-C で停止）。閾値: GW>${GW_SPIKE_MS}ms/loss>${GW_LOSS_PCT}%, EXT>${EXT_SPIKE_MS}ms/loss>${EXT_LOSS_PCT}%"

while :; do
  TICKS=$((TICKS + 1))

  GW=$(physical_gateway || true)
  gwfile=$(mktemp); extfile=$(mktemp)
  if [ -n "$GW" ]; then
    ping_probe "$GW" "$PING_COUNT" > "$gwfile" &
    gwpid=$!
  else
    echo "n/a n/a" > "$gwfile"
    gwpid=""
  fi
  ping_probe 1.1.1.1 "$PING_COUNT" > "$extfile" &
  extpid=$!
  [ -n "$gwpid" ] && wait "$gwpid"
  wait "$extpid"
  read GW_LOSS GW_AVG < "$gwfile"
  read EXT_LOSS EXT_AVG < "$extfile"
  rm -f "$gwfile" "$extfile"

  ROUTE=$(default_route_class)
  TS=$(date +%H:%M:%S)

  if exceeds "$GW_AVG" "$GW_SPIKE_MS"; then
    emit "$TS  GW spike avg=${GW_AVG}ms loss=${GW_LOSS}%  [route=$ROUTE]"
    ANOMALIES=$((ANOMALIES + 1))
  fi
  if exceeds "$GW_LOSS" "$GW_LOSS_PCT"; then
    emit "$TS  GW loss=${GW_LOSS}% avg=${GW_AVG}ms  [route=$ROUTE]"
    ANOMALIES=$((ANOMALIES + 1))
  fi
  if exceeds "$EXT_AVG" "$EXT_SPIKE_MS"; then
    emit "$TS  EXT spike avg=${EXT_AVG}ms loss=${EXT_LOSS}%  [route=$ROUTE]"
    ANOMALIES=$((ANOMALIES + 1))
  fi
  if exceeds "$EXT_LOSS" "$EXT_LOSS_PCT"; then
    emit "$TS  EXT loss=${EXT_LOSS}% avg=${EXT_AVG}ms  [route=$ROUTE]"
    ANOMALIES=$((ANOMALIES + 1))
  fi

  if exceeds "$GW_AVG" "$WORST_GW"; then WORST_GW="$GW_AVG"; fi
  if exceeds "$EXT_AVG" "$WORST_EXT"; then WORST_EXT="$EXT_AVG"; fi

  # liveness line every 12 ticks (~1 min at ~5s/tick), otherwise stay quiet
  if [ "$((TICKS % 12))" -eq 0 ]; then
    now=$(date +%s)
    echo "監視中… 経過 $((now - START))s / tick $TICKS / 異常計 $ANOMALIES 件"
  fi

  if [ "$DURATION_SECS" -gt 0 ]; then
    now=$(date +%s)
    if [ "$((now - START))" -ge "$DURATION_SECS" ]; then summary; fi
  fi
done
```

- [ ] **Step 2: Make executable and verify a short bounded run**

Run: `chmod +x scripts/net-monitor.sh && ./scripts/net-monitor.sh 10s`
Expected: prints the "監視開始 …" banner, runs for ~10s, then prints the `== 監視サマリ ==` block with a tick count ≥1 and exits 0. On a healthy network there should be no anomaly lines; if any fire, confirm a matching line also landed in `logs/monitor-YYYYMMDD.log`.

- [ ] **Step 3: Verify the anomaly path deterministically** (tiny threshold forces a hit)

Run: `GW_SPIKE_MS=0 ./scripts/net-monitor.sh 6s`
Expected: at least one `GW spike …` (or `GW loss …`) line prints with a `[route=…]` tag, the summary reports `異常検知: N 件` with N≥1, and the same line exists in `logs/monitor-YYYYMMDD.log`. (`GW_SPIKE_MS=0` proves env overrides the conf default of 50, exercising Task 7's precedence end-to-end.)

- [ ] **Step 4: Verify bad-duration handling**

Run: `./scripts/net-monitor.sh nonsense; echo "rc=$?"`
Expected: prints `Invalid duration: nonsense …` to stderr and `rc=1`.

- [ ] **Step 5: Commit**

```bash
git add scripts/net-monitor.sh
git commit -m "Add net-monitor.sh foreground continuous monitor"
```

---

## Task 13: Documentation — `CLAUDE.md` and `README.md`

**Files:**
- Modify: `CLAUDE.md`
- Modify: `README.md`

- [ ] **Step 1: Add interpretation guidance to `CLAUDE.md`** — add a new subsection after the "Interpreting the output" section:

```markdown
## Cato / VPN on the default route

`net-cato-check.sh` reports whether a VPN tunnel — specifically Cato — owns
the default route (`cato` / `vpn` / `direct` / `unknown`), and `run.sh` runs
it right after the interface check. Cato has been the first suspect before and
turned out innocent, so treat it as a **starting point for elimination, not a
culprit**: when things are slow, recommend the user manually disconnect Cato
and compare before/after. Never disconnect it yourself — that's a user action,
like a router restart.

**Physical gateway.** The GW figure everywhere (snapshot and monitor) is the
**physical LAN router** via `physical_gateway`, not the default-route gateway.
This matters because when Cato holds the default route, `route -n get default`
has no gateway line at all (previously the GW ping was silently skipped). So
"GW is fine but external is bad" vs "GW itself is bad" stays a valid
router-vs-ISP split regardless of whether Cato is connected.

## Catching intermittent faults (continuous monitoring)

A single `run.sh` snapshot can't catch a fault that comes and goes. When the
symptom is intermittent — "it was bad, now it's fine, now it's bad again" —
use `./scripts/net-monitor.sh [duration]`. It pings the physical gateway and
an external host every few seconds and prints a timestamped line only when a
threshold is crossed, tagging each with the route class (`cato`/`vpn`/…) so
you can see whether Cato was in the path when the spike happened. Thresholds
live in `scripts/net-monitor.conf` (override per-run with env vars, e.g.
`GW_SPIKE_MS=30 ./scripts/net-monitor.sh 30m`). Anomalies also append to
`logs/monitor-YYYYMMDD.log`. Keep the non-committal tone: report which layer
(GW / external) degraded and whether it correlates with Cato — don't over-
conclude from one spike.
```

- [ ] **Step 2: Document the new commands in `README.md`** — add a short "Continuous monitoring" and "Cato check" note near where `run.sh` is described (match the README's existing heading style). Example block:

```markdown
### Continuous monitoring (intermittent faults)

`./scripts/run.sh` is a one-shot snapshot. For a fault that comes and goes,
run the monitor to catch it live:

```bash
./scripts/net-monitor.sh 30m   # watch for 30 min (omit for Ctrl-C to stop)
```

It stays quiet while healthy and prints a timestamped line only when gateway
or external latency/loss crosses a threshold (configurable in
`scripts/net-monitor.conf`), tagging each with whether Cato/VPN owned the
route at that moment. Anomalies are also written to
`logs/monitor-YYYYMMDD.log` (gitignored, local only).

### Cato / VPN detection

Each `run.sh` now reports whether Cato (or another VPN tunnel) owns the
default route. It only reports and recommends a manual before/after
comparison — it never disconnects anything.
```

- [ ] **Step 3: Verify the docs render and match reality**

Run: `./scripts/run.sh` once and confirm the cato section and the described behavior match what CLAUDE.md/README now say (command names, config path, log path all correct).

- [ ] **Step 4: Commit**

```bash
git add CLAUDE.md README.md
git commit -m "Document Cato check and continuous monitoring"
```

---

## Notes for the implementer

- **Bash 3.2 only.** No `declare -A`, no `${var^^}`/`${var,,}`, no `mapfile`. Stick to the idioms shown above (they're all 3.2-safe).
- **`read VAR1 VAR2 <<EOF … EOF`** is used to capture `ping_probe`'s two-value output without a subshell (so the vars persist). Keep the heredoc body exactly `$(ping_probe …)` on its own line.
- **Parallel probes write to temp files**, then `read` after `wait` — background subshells can't assign to parent variables, so don't try to capture them directly.
- **The test harness is cumulative**: each task appends asserts to `tests/run-tests.sh`. Always keep the final two lines (`echo "PASS=$PASS FAIL=$FAIL"` and `[ "$FAIL" -eq 0 ]`) at the very end; insert new asserts above them.
- **`logs/` is gitignored** (including `monitor-*.log` and `history.csv`) — never commit them. `scripts/net-monitor.conf` **is** committed.
- Run `./tests/run-tests.sh` after every net-common.sh change; it must end `FAIL=0`.
```
