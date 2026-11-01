#!/system/bin/sh
#
# Starts sing-box when the module is enabled.

MODDIR="${0%/*}"
readonly MODDIR

sh "${MODDIR}/scripts/control.sh" start
