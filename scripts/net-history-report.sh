#!/bin/bash
# Summarizes logs/history.csv (built up by net-log-run.sh on every run.sh
# pass): shows the last N runs plus the latest run's latency/loss compared
# to the average of all prior runs, so "feels slower lately" becomes a
# number. Read-only. Usage: ./net-history-report.sh [N]

set -uo pipefail
cd "$(dirname "$0")" || exit 1

LOG_FILE="../logs/history.csv"
ROWS="${1:-20}"

if [ ! -f "$LOG_FILE" ] || [ "$(wc -l < "$LOG_FILE")" -le 1 ]; then
  echo "No history yet. Run ./run.sh a few times to build up data."
  exit 0
fi

echo "== Last $ROWS runs (logs/history.csv) =="
{ head -1 "$LOG_FILE"; tail -n +2 "$LOG_FILE" | tail -n "$ROWS"; } | column -t -s,

echo
echo "== Trend: latest run vs. average of all prior runs =="
awk -F, '
NR==1 { next }
{
  n++
  gw_avg[n]=$7; gw_loss[n]=$6
  extip_avg[n]=$11; extip_loss[n]=$10
  exthost_avg[n]=$13; exthost_loss[n]=$12
  ts[n]=$1
}
function avg(arr, upto,    s, c, i) {
  s = 0; c = 0
  for (i = 1; i < upto; i++) { if (arr[i] != "") { s += arr[i]; c++ } }
  if (c == 0) return -1
  return s / c
}
function report(label, arr, upto,    base, cur, diff, pct) {
  cur = arr[upto]
  if (cur == "") { printf "%-26s latest=n/a\n", label; return }
  base = avg(arr, upto)
  if (base < 0) { printf "%-26s latest=%-8s (no prior data to compare)\n", label, cur; return }
  diff = cur - base
  pct = (base > 0) ? (diff / base * 100) : 0
  printf "%-26s latest=%-8s avg_prior=%-8.1f delta=%+.1f (%+.0f%%)\n", label, cur, base, diff, pct
}
END {
  if (n < 2) { print "Not enough history yet (need at least 2 runs)."; exit }
  print "Latest run: " ts[n]
  report("Gateway latency (ms)", gw_avg, n)
  report("Gateway loss (%)", gw_loss, n)
  report("External IP latency (ms)", extip_avg, n)
  report("External IP loss (%)", extip_loss, n)
  report("External host latency (ms)", exthost_avg, n)
  report("External host loss (%)", exthost_loss, n)
}
' "$LOG_FILE"
