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
