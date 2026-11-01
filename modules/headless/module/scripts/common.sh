#!/system/bin/sh
#
# Shared paths, settings and helpers. Sourced by the other scripts.

HEADLESS_DIR=/data/adb/headless
BIN_DIR="${HEADLESS_DIR}/bin"
RUN_DIR="${HEADLESS_DIR}/run"
SERVICE_DIR=/data/adb/rootfs/service
WIFI_CONF="${HEADLESS_DIR}/wifi.conf"
LOG_FILE="${RUN_DIR}/headless.log"
DISABLED_FILE="${HEADLESS_DIR}/disabled"
PATH="${BIN_DIR}:${PATH}"
readonly BIN_DIR DISABLED_FILE HEADLESS_DIR LOG_FILE RUN_DIR
readonly SERVICE_DIR WIFI_CONF
export PATH

[ -f "${HEADLESS_DIR}/settings.sh" ] && . "${HEADLESS_DIR}/settings.sh"
: "${AUTOSTART:=1}"
: "${WIFI_IFACE:=wlan0}"
: "${WIFI_TIMEOUT:=60}"
: "${WIFI_SERVICES:=wpa_supplicant wificond vendor.wifi_hal_legacy}"
: "${ANDROID_SERVICES:=zygote zygote_secondary surfaceflinger audioserver \
cameraserver media mediaextractor media.swcodec mediametrics}"
: "${DOCKER_BRIDGE:=docker0}"
: "${DOCKER_SUBNET:=172.17.0.0/16}"
: "${RULE_PREF:=9500}"

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
