#!/system/bin/sh
#
# runit service: local DNS forwarder daemon (dns-forwarder).

MODDIR="$(cd "${0%/*}/../.." && pwd)"
readonly MODDIR
. "${MODDIR}/scripts/common.sh"

exec 2>&1
if [ ! -x "${BIN_DIR}/dns-forwarder" ]; then
  log 'dns-forwarder missing or not executable'
  sleep 5
  exit 1
fi

exec "${BIN_DIR}/dns-forwarder" "${HEADLESS_DIR}/resolv.conf"
