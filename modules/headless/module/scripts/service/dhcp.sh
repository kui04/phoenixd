#!/system/bin/sh
#
# runit service: udhcpc in the foreground. It retries without end.

MODDIR="$(cd "${0%/*}/../.." && pwd)"
readonly MODDIR
. "${MODDIR}/scripts/common.sh"

exec 2>&1
exec busybox udhcpc -f -i "${WIFI_IFACE}" -t 5 -A 5 \
  -s "${MODDIR}/scripts/dhcp-event.sh"
