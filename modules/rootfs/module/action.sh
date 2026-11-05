#!/system/bin/sh
#
# KernelSU action button: print the state of Layer 1 and of the image.

MODDIR="${0%/*}"
readonly MODDIR

sh "${MODDIR}/scripts/control.sh" status
