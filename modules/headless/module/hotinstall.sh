#!/system/bin/sh
#
# Hot install hook: applies the module without a reboot.

MODDIR="${0%/*}"
readonly MODDIR

if grep -q '^[[:space:]]*ssid=' /data/adb/headless/wifi.conf 2>/dev/null; then
  sh "${MODDIR}/scripts/control.sh" start >/dev/null 2>&1 &
fi
