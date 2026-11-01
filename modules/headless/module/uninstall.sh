#!/system/bin/sh
#
# KernelSU uninstall hook: stop the setup, restore Android and remove files.

MODDIR="${0%/*}"
readonly MODDIR

sh "${MODDIR}/scripts/control.sh" stop >/dev/null 2>&1
rm -rf /data/adb/headless
rm -f /data/adb/ksu/bin/headless-service
