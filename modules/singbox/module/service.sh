#!/system/bin/sh
#
# Starts the proxy at boot. It does not wait for Layer 1 or headless.

MODDIR="${0%/*}"
readonly MODDIR

sh "${MODDIR}/scripts/control.sh" start
