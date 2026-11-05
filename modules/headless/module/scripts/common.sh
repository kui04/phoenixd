#!/system/bin/sh
#
# Shared paths, settings and helpers. Sourced by the other scripts.

HEADLESS_DIR=/data/adb/headless
BIN_DIR="${HEADLESS_DIR}/bin"
RUN_DIR="${HEADLESS_DIR}/run"
ROOTFS_HOME="${ROOTFS_HOME:-/data/adb/rootfs}"
SERVICE_DIR="${ROOTFS_HOME}/host-service"
WIFI_CONF="${HEADLESS_DIR}/wifi.conf"
LOG_FILE="${RUN_DIR}/headless.log"
DISABLED_FILE="${HEADLESS_DIR}/disabled"
PATH="${BIN_DIR}:${PATH}"
readonly BIN_DIR DISABLED_FILE HEADLESS_DIR LOG_FILE ROOTFS_HOME RUN_DIR
readonly SERVICE_DIR WIFI_CONF
export PATH

[ -f "${HEADLESS_DIR}/settings.sh" ] && . "${HEADLESS_DIR}/settings.sh"
: "${AUTOSTART:=1}"
: "${WIFI_IFACE:=wlan0}"
: "${WIFI_TIMEOUT:=60}"
: "${WIFI_SERVICES:=wpa_supplicant wificond vendor.wifi_hal_legacy}"
: "${ANDROID_SERVICES:=zygote zygote_secondary surfaceflinger audioserver \
cameraserver media mediaextractor media.swcodec mediametrics \
vendor.hwcomposer-2-4}"
: "${DOCKER_BRIDGE:=docker0}"
: "${DOCKER_SUBNET:=172.17.0.0/16}"
: "${RULE_PREF:=9500}"
: "${CHARGE_CONTROL:=1}"
: "${CHARGE_START_LEVEL:=50}"
: "${CHARGE_STOP_LEVEL:=65}"
: "${CHARGE_INTERVAL:=60}"
: "${FAST_CHARGE:=0}"
: "${CHARGE_RESTRICT_CUR:=1200000}"
: "${BATTERY_DIR:=/sys/class/power_supply/battery}"
: "${DISPLAY_ENABLED:=1}"
: "${DISPLAY_TIMEOUT:=30}"
: "${DISPLAY_BRIGHTNESS:=1024}"

#######################################
# Append a time-stamped message to the log file.
# Globals:
#   LOG_FILE
# Arguments:
#   Message.
#######################################
log() {
  mkdir -p "${RUN_DIR}"
  echo "$(date '+%F %T') $*" >>"${LOG_FILE}"
}

#######################################
# Check whether charging is suspended.
# Globals:
#   BATTERY_DIR
# Returns:
#   0 if suspended, 1 otherwise.
#######################################
is_suspended() {
  [ -d "${BATTERY_DIR}" ] || return 1
  if [ -f "${BATTERY_DIR}/input_suspend" ]; then
    [ "$(cat "${BATTERY_DIR}/input_suspend" 2>/dev/null)" = 1 ]
    return
  fi
  if [ -f "${BATTERY_DIR}/charging_enabled" ]; then
    [ "$(cat "${BATTERY_DIR}/charging_enabled" 2>/dev/null)" = 0 ]
    return
  fi
  if [ -f "${BATTERY_DIR}/battery_charging_enabled" ]; then
    [ "$(cat "${BATTERY_DIR}/battery_charging_enabled" 2>/dev/null)" = 0 ]
    return
  fi
  return 1
}

#######################################
# Set the hardware charging state.
# Globals:
#   BATTERY_DIR
# Arguments:
#   1 to suspend charging, 0 to allow charging.
#######################################
set_charge_state() {
  local state="${1}"
  [ -d "${BATTERY_DIR}" ] || return 0
  if [ -f "${BATTERY_DIR}/input_suspend" ]; then
    echo "${state}" >"${BATTERY_DIR}/input_suspend" 2>/dev/null
    return
  fi
  if [ -f "${BATTERY_DIR}/charging_enabled" ]; then
    echo "$(( 1 - state ))" >"${BATTERY_DIR}/charging_enabled" 2>/dev/null
    return
  fi
  if [ -f "${BATTERY_DIR}/battery_charging_enabled" ]; then
    echo "$(( 1 - state ))" \
      >"${BATTERY_DIR}/battery_charging_enabled" 2>/dev/null
    return
  fi
}

#######################################
# Enable or disable fast charging.
# Globals:
#   BATTERY_DIR
#   CHARGE_RESTRICT_CUR
# Arguments:
#   1 to enable fast charging, 0 to restrict current.
#######################################
set_fast_charge() {
  local enable="${1}"
  if [ -d /sys/class/qcom-battery ]; then
    if [ "${enable}" = 1 ]; then
      echo 0 >/sys/class/qcom-battery/restrict_chg 2>/dev/null
    else
      echo "${CHARGE_RESTRICT_CUR}" \
        >/sys/class/qcom-battery/restrict_cur 2>/dev/null
      echo 1 >/sys/class/qcom-battery/restrict_chg 2>/dev/null
    fi
  elif [ -f "${BATTERY_DIR}/slowly_charging" ]; then
    if [ "${enable}" = 1 ]; then
      echo 0 >"${BATTERY_DIR}/slowly_charging" 2>/dev/null
    else
      echo 1 >"${BATTERY_DIR}/slowly_charging" 2>/dev/null
    fi
  fi
  if [ -f /sys/class/power_supply/charge_pump_master/cp_enable ]; then
    echo "${enable}" \
      >/sys/class/power_supply/charge_pump_master/cp_enable 2>/dev/null
  fi
  if [ -f /sys/class/power_supply/usb/fastcharge_mode ]; then
    echo "${enable}" \
      >/sys/class/power_supply/usb/fastcharge_mode 2>/dev/null
  fi
}
