#!/system/bin/sh
#
# KernelSU uninstall hook: stop the proxy and remove the files of this module.

MODDIR="${0%/*}"
readonly MODDIR
ROOTFS_HOME="${ROOTFS_HOME:-/data/adb/rootfs}"

sh "${MODDIR}/scripts/control.sh" stop >/dev/null 2>&1
rm -rf "${ROOTFS_HOME}/host-service/singbox" /data/adb/singbox
rm -f /data/adb/ksu/bin/singbox-service
