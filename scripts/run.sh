#!/bin/bash
# Full diagnostic pass: interface, connectivity (gateway/DNS/external), then
# Wi-Fi signal. Everything here is read-only — deciding what to do with the
# output (restart the router? not our problem, it's the ISP?) is deliberately
# left out of this script; see CLAUDE.md for that.
#
# Also appends a row to logs/history.csv (see net-log-run.sh) so repeated
# runs build up a time series — lets "feels slower lately" be checked with
# net-history-report.sh instead of just a gut feeling.

set -uo pipefail
cd "$(dirname "$0")" || exit 1

./net-interface-check.sh
echo
./net-vpn-check.sh
echo
./net-connectivity-check.sh
echo
./net-wifi-check.sh

./net-log-run.sh
echo
echo "(logged to logs/history.csv — see net-history-report.sh for trends)"
