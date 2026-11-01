#!/system/bin/sh
#
# KernelSU uninstall hook: stop the setup, restore Android and remove files.

MODDIR="${0%/*}"
readonly MODDIR

sh "${MODDIR}/scripts/control.sh" stop >/dev/null 2>&1
echo 0 >/sys/class/power_supply/battery/input_suspend 2>/dev/null
echo 0 >/sys/class/qcom-battery/restrict_chg 2>/dev/null
echo 1 >/sys/class/power_supply/charge_pump_master/cp_enable 2>/dev/null
rm -rf /data/adb/headless
rm -f /data/adb/ksu/bin/headless-service
