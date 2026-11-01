#!/system/bin/sh
#
# Hot install hook: start the daemon without a reboot.

MODDIR="${0%/*}"
readonly MODDIR

sh "${MODDIR}/scripts/control.sh" start >/dev/null 2>&1 &
