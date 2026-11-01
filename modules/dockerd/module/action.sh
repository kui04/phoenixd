#!/system/bin/sh
#
# KernelSU action button: print the daemon status and the last log lines.

MODDIR="${0%/*}"
readonly MODDIR

sh "${MODDIR}/scripts/control.sh" status
echo
sh "${MODDIR}/scripts/control.sh" log 12
