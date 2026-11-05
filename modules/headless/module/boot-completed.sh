#!/system/bin/sh
#
# Starts the headless setup in the background after boot completed. The short
# delay lets adbd and the USB configuration settle before the Android UI stack
# is stopped.

MODDIR="${0%/*}"
readonly MODDIR
. "${MODDIR}/scripts/common.sh"

[ -f "${DISABLED_FILE}" ] && exit 0
[ "${AUTOSTART}" = 1 ] || exit 0
mkdir -p "${RUN_DIR}"
(
  sleep 10
  sh "${MODDIR}/scripts/control.sh" start
) >>"${LOG_FILE}" 2>&1 </dev/null &
