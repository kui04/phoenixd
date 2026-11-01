#!/system/bin/sh
#
# runit service: DRM status display daemon (phx-statusd).

MODDIR="$(cd "${0%/*}/../.." && pwd)"
readonly MODDIR
. "${MODDIR}/scripts/common.sh"

exec 2>&1
if [ ! -x "${BIN_DIR}/phx-statusd" ]; then
  log 'phx-statusd missing or not executable'
  sleep 5
  exit 1
fi

exec "${BIN_DIR}/phx-statusd" \
  --timeout "${DISPLAY_TIMEOUT}" \
  --brightness "${DISPLAY_BRIGHTNESS}"

