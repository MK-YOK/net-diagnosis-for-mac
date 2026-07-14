#!/bin/bash
# Runs the same core probes as net-connectivity-check.sh / net-wifi-check.sh,
# but parses the results into one CSV row appended to logs/history.csv
# instead of printing for a human. Called from run.sh on every diagnostic
# pass, so history builds up automatically over time — no cron/launchd
# needed. Read-only aside from appending to that one log file.

set -uo pipefail
cd "$(dirname "$0")" || exit 1

LOG_DIR="../logs"
LOG_FILE="$LOG_DIR/history.csv"
HEADER="timestamp,interface,link_status,has_ip,gateway_ip,gateway_loss_pct,gateway_avg_ms,dns_ok,dns_query_ms,ext_ip_loss_pct,ext_ip_avg_ms,ext_host_loss_pct,ext_host_avg_ms,wifi_rssi,wifi_noise,wifi_channel"

mkdir -p "$LOG_DIR"
if [ ! -f "$LOG_FILE" ]; then
  echo "$HEADER" > "$LOG_FILE"
fi

# -- ping stats: "N packets transmitted, M packets received, X.X% packet loss"
# -- and (if any received) "round-trip min/avg/max/stddev = a/b/c/d ms"
ping_loss() { grep -oE '[0-9.]+% packet loss' | grep -oE '^[0-9.]+'; }
ping_avg()  { grep 'round-trip' | sed -E 's#.*= [0-9.]+/([0-9.]+)/.*#\1#'; }

TIMESTAMP=$(date -u +%Y-%m-%dT%H:%M:%SZ)

# -- interface --
IFACE=$(route -n get default 2>/dev/null | awk '/interface:/{print $2}')
LINK_STATUS=""
HAS_IP=0
if [ -n "$IFACE" ]; then
  LINK_STATUS=$(ifconfig "$IFACE" 2>/dev/null | awk '/status:/{print $2}')
  ifconfig "$IFACE" 2>/dev/null | grep -q "inet " && HAS_IP=1
fi

# -- gateway --
GATEWAY=$(route -n get default 2>/dev/null | awk '/gateway:/{print $2}')
GW_LOSS=""
GW_AVG=""
if [ -n "$GATEWAY" ]; then
  gw_output=$(ping -c 3 -t 5 "$GATEWAY" 2>&1)
  GW_LOSS=$(echo "$gw_output" | ping_loss)
  GW_AVG=$(echo "$gw_output" | ping_avg)
fi

# -- DNS --
dig_output=$(dig +time=3 +tries=1 apple.com 2>/dev/null)
DNS_OK=0
echo "$dig_output" | grep -qE 'ANSWER: [1-9]' && DNS_OK=1
DNS_MS=$(echo "$dig_output" | awk '/Query time:/{print $4}')

# -- external reachability --
extip_output=$(ping -c 3 -t 5 1.1.1.1 2>&1)
EXTIP_LOSS=$(echo "$extip_output" | ping_loss)
EXTIP_AVG=$(echo "$extip_output" | ping_avg)

exthost_output=$(ping -c 3 -t 5 apple.com 2>&1)
EXTHOST_LOSS=$(echo "$exthost_output" | ping_loss)
EXTHOST_AVG=$(echo "$exthost_output" | ping_avg)

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

echo "$TIMESTAMP,$IFACE,$LINK_STATUS,$HAS_IP,$GATEWAY,$GW_LOSS,$GW_AVG,$DNS_OK,$DNS_MS,$EXTIP_LOSS,$EXTIP_AVG,$EXTHOST_LOSS,$EXTHOST_AVG,$WIFI_RSSI,$WIFI_NOISE,$WIFI_CHANNEL" >> "$LOG_FILE"
