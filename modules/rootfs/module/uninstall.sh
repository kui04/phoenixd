#!/system/bin/sh
#
# KernelSU uninstall hook: stop the supervisor and clean up.

MODDIR="${0%/*}"
readonly MODDIR

sh "${MODDIR}/scripts/cleanup.sh"

