#!/system/bin/sh
#
# Starts the headless setup in the background after boot completed.

MODDIR="${0%/*}"
readonly MODDIR
. "${MODDIR}/scripts/common.sh"

[ -f "${DISABLED_FILE}" ] && exit 0
[ "${AUTOSTART}" = 1 ] || exit 0
mkdir -p "${RUN_DIR}"
sh "${MODDIR}/scripts/control.sh" start >>"${LOG_FILE}" 2>&1 </dev/null &
