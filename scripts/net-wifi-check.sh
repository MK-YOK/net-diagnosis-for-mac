#!/bin/bash
# Read-only Wi-Fi signal/quality diagnostics. Only meaningful if the active
# interface is Wi-Fi (see net-interface-check.sh); harmless no-op on
# Ethernet. Part of the net-diagnosis-for-mac diagnostic pass (see run.sh).
# No side effects.

set -uo pipefail

echo "== Wi-Fi info (SSID, RSSI, noise, channel) =="
wdutil_output=""
if command -v wdutil >/dev/null 2>&1; then
  wdutil_output=$(sudo -n wdutil info 2>/dev/null | grep -A 20 "WIFI")
fi
if [ -n "$wdutil_output" ]; then
  echo "$wdutil_output"
else
  echo "(wdutil needs sudo — run 'sudo wdutil info' manually for RSSI/noise; falling back to system_profiler)"
  system_profiler SPAirPortDataType 2>/dev/null | grep -E "Card Type|Firmware Version|Current Network|Channel|Signal|Noise|Transmit Rate"
fi
