#!/system/bin/sh
#
# KernelSU uninstall hook: hand wlan0 back to Android and remove the files of
# this module. Layer 1, the netns, NAT, and the proxy belong to other modules.

MODDIR="${0%/*}"
readonly MODDIR
. "${MODDIR}/scripts/common.sh"

sh "${MODDIR}/scripts/control.sh" stop >/dev/null 2>&1
rm -rf "${SERVICE_DIR}/wifi" "${SERVICE_DIR}/charge" "${SERVICE_DIR}/display"
rm -f /data/adb/ksu/bin/headless-service
rm -rf /data/adb/headless
