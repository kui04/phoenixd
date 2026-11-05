#!/system/bin/sh
#
# Controls the headless host services: the Wi-Fi handover, the charge control,
# and the display daemon. This module never starts or stops Layer 1, the netns,
# the veth pair, NAT, table 9500, or the proxy.
#
# Commands: start, stop, restart, restore, status, log.

MODDIR="$(cd "${0%/*}/.." && pwd)"
readonly MODDIR
. "${MODDIR}/scripts/common.sh"

#######################################
# Print a message to stderr.
# Arguments:
#   Message.
#######################################
err() {
  echo "$*" >&2
}

#######################################
# Run init actions on a list of Android services.
# Arguments:
#   Action (start or stop) and the service names.
#######################################
android_services() {
  local action="${1}"
  shift
  for service in "$@"; do
    "${action}" "${service}" >/dev/null 2>&1
  done
}

#######################################
# Wait until Android lets go of the interface. `stop` only asks; the vendor
# stack keeps the interface until its own teardown finishes, and a supplicant
# that starts in between fails with "device or resource busy" and leaves the
# interface without an address.
#######################################
wait_wifi_release() {
  local count=0 service
  while [ "${count}" -lt 20 ]; do
    for service in ${WIFI_SERVICES}; do
      if [ "$(getprop "init.svc.${service}")" != stopped ]; then
        break
      fi
      if [ "${service}" = "${WIFI_SERVICES##* }" ]; then
        return 0
      fi
    done
    sleep 1
    count=$(( count + 1 ))
  done
  return 1
}

#######################################
# Ensure the host supervisor of modules/rootfs runs. KernelSU starts the
# module scripts in an undefined order, so a service of this module may run
# before that supervisor exists.
#######################################
ensure_supervisor() {
  local control=/data/adb/modules/rootfs/scripts/host.sh
  [ -f "${control}" ] || return 0
  if ! "${BUSYBOX}" sv status "${SERVICE_DIR}" >/dev/null 2>&1; then
    sh "${control}" start >/dev/null 2>&1
  fi
}

#######################################
# Control one host service under the host runsvdir.
# Arguments:
#   Action for sv, then the service name.
#######################################
host_service() {
  local action="${1}" name="${2}"
  if [ ! -d "${SERVICE_DIR}/${name}" ]; then
    err "no host service ${name}, reinstall the module"
    return 1
  fi
  "${BIN_DIR}/sv" "-w" 15 "${action}" "${SERVICE_DIR}/${name}"
}

#######################################
# Remove the marker that a manual stop writes.
#######################################
clear_disabled() {
  rm -f "${DISABLED_FILE}"
}

#######################################
# Check whether the interface has an address.
#######################################
wifi_ready() {
  ip -4 -o addr show "${WIFI_IFACE}" 2>/dev/null | grep -q ' inet '
}

#######################################
# Hand wlan0 back to Android.
#######################################
restore_android() {
  local count=0
  log 'restoring Android'
  set_charge_state 0
  set_fast_charge 1
  echo 0 >/sys/class/backlight/panel0-backlight/bl_power 2>/dev/null
  start vendor.hwcomposer-2-4 2>/dev/null
  android_services start ${ANDROID_SERVICES} ${WIFI_SERVICES}
}

#######################################
# Start the host services and wait for the association. On failure, hand the
# interface back to Android.
#######################################
start_headless() {
  local count=0
  clear_disabled
  ensure_supervisor
  if wifi_ready; then
    log 'wlan0 already has an address'
  fi
  log 'stopping the Android UI and Wi-Fi services'
  android_services stop ${ANDROID_SERVICES} ${WIFI_SERVICES}
  wait_wifi_release || log 'wlan0 is still held, starting anyway'
  log 'starting the host services'
  host_service up wifi || return 1
  host_service up charge
  host_service up display
  while [ "${count}" -lt "${WIFI_TIMEOUT}" ]; do
    if wifi_ready; then
      log "wlan0 is up: $(ip -4 -o addr show "${WIFI_IFACE}" |
        awk '{ print $4 }')"
      return 0
    fi
    sleep 1
    count=$(( count + 1 ))
  done
  err "no address on ${WIFI_IFACE} after ${WIFI_TIMEOUT} seconds"
  stop_headless
  restore_android
  return 1
}

#######################################
# Stop the host services and hand wlan0 back to Android.
#######################################
stop_headless() {
  local name
  for name in wifi charge display; do
    host_service down "${name}" >/dev/null 2>&1
  done
  return 0
}

#######################################
# Print the state of the host services.
#######################################
show_status() {
  local name
  for name in wifi charge display; do
    if [ -d "${SERVICE_DIR}/${name}" ]; then
      "${BIN_DIR}/sv" status "${SERVICE_DIR}/${name}" 2>/dev/null
    else
      log "${name}: not installed"
    fi
  done
  log "address: $(ip -4 -o addr show "${WIFI_IFACE}" 2>/dev/null |
    awk '{ print $4 }')"
}

#######################################
# Print the last lines of a service log.
# Arguments:
#   Number of lines, 40 by default.
#######################################
show_log() {
  local lines="${1:-40}"
  if [ -f "${RUN_DIR}/wifi.log" ]; then
    tail -n "${lines}" "${RUN_DIR}/wifi.log"
  else
    err "no log yet: ${RUN_DIR}/wifi.log"
    return 1
  fi
}

#######################################
# Print the command usage.
#######################################
usage() {
  err "usage: $0 start|stop|restart|restore|status|log [lines]"
  exit 1
}

#######################################
# Dispatch the command line arguments.
#######################################
main() {
  case "${1:-}" in
    start) start_headless ;;
    stop)
      stop_headless
      restore_android
      ;;
    restart)
      stop_headless
      start_headless
      ;;
    restore)
      stop_headless
      restore_android
      ;;
    status) show_status ;;
    log) show_log "${2:-}" ;;
    *) usage ;;
  esac
}

main "$@"
