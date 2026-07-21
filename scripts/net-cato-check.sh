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
