#!/system/bin/sh
#
# Starts dockerd when the module is enabled.

MODDIR="${0%/*}"
readonly MODDIR

sh "${MODDIR}/scripts/control.sh" start
