#!/system/bin/sh
#
# KernelSU uninstall hook: stop sing-box and remove everything the module
# created.

MODDIR="${0%/*}"
readonly MODDIR
SINGBOX_DIR=/data/adb/singbox
readonly SINGBOX_DIR

sh "${MODDIR}/scripts/control.sh" stop
rm -f /data/adb/ksu/bin/singbox-service
rm -rf /data/adb/rootfs/service/singbox
rm -rf "${SINGBOX_DIR}"
