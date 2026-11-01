#!/system/bin/sh
#
# runit service: wpa_supplicant in the foreground.

MODDIR="$(cd "${0%/*}/../.." && pwd)"
readonly MODDIR
. "${MODDIR}/scripts/common.sh"

mkdir -p "${RUN_DIR}/wpa"
exec 2>&1
exec wpa_supplicant -i "${WIFI_IFACE}" -D nl80211 -c "${WIFI_CONF}"
