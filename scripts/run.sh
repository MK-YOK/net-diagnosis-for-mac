#!/bin/bash
# Full diagnostic pass: interface, connectivity (gateway/DNS/external), then
# Wi-Fi signal. Everything here is read-only — deciding what to do with the
# output (restart the router? not our problem, it's the ISP?) is deliberately
# left out of this script; see CLAUDE.md for that.

set -uo pipefail
cd "$(dirname "$0")" || exit 1

./net-interface-check.sh
echo
./net-connectivity-check.sh
echo
./net-wifi-check.sh
