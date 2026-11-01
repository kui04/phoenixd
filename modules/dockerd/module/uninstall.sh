#!/system/bin/sh
#
# KernelSU uninstall hook: remove everything the module created.

MODDIR="${0%/*}"
readonly MODDIR

sh "${MODDIR}/scripts/cleanup.sh"
