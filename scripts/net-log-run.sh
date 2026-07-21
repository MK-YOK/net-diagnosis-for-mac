#!/bin/bash
# Runs the same core probes as the connectivity/wifi checks, but parses the
# results into one CSV row appended to logs/history.csv instead of printing
# for a human. Called from run.sh on every pass, so history builds up over
# time — no cron/launchd needed. Read-only aside from appending to that log.
# Gateway is the PHYSICAL LAN router (see physical_gateway) so the GW figure
# is meaningful even when a VPN owns the default route.

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
  # migrate old 16-col header to the new 17-col header, keep existing rows
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

# -- default route classification (vpn/direct/unknown) --
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
