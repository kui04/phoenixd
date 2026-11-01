#!/system/bin/sh
#
# Controls the headless setup: start, stop, restart, status, log.

MODDIR="$(cd "${0%/*}/.." && pwd)"
readonly MODDIR
. "${MODDIR}/scripts/common.sh"

#######################################
# Print an error message to stderr.
# Arguments:
#   Message.
#######################################
err() {
  echo "$*" >&2
}

#######################################
# Check whether Wi-Fi services run.
# Globals:
#   SERVICE_DIR
# Returns:
#   0 if running, 1 otherwise.
#######################################
is_running() {
  sv status "${SERVICE_DIR}/wifi" 2>/dev/null | grep -q '^run:'
}

#######################################
# Check whether runsv holds a service lock.
# Globals:
#   SERVICE_DIR
# Returns:
#   0 if a lock is held, 1 otherwise.
#######################################
service_locked() {
  local lock
  for lock in "${SERVICE_DIR}/wifi/supervise/lock" \
    "${SERVICE_DIR}/dhcp/supervise/lock" \
    "${SERVICE_DIR}/dns-forwarder/supervise/lock" \
    "${SERVICE_DIR}/charge/supervise/lock" \
    "${SERVICE_DIR}/display/supervise/lock"; do
    [ -e "${lock}" ] || continue
    busybox flock -n "${lock}" true 2>/dev/null || return 0
  done
  return 1
}

#######################################
# Check that wifi.conf holds at least one network.
# Globals:
#   WIFI_CONF
# Returns:
#   0 if configured, 1 otherwise.
#######################################
is_configured() {
  grep -q '^[[:space:]]*ssid=' "${WIFI_CONF}" 2>/dev/null
}

#######################################
# Wait until Android finished boot and the Wi-Fi firmware loader runs.
# Returns:
#   1 on timeout.
#######################################
wait_boot() {
  local i=0
  while [ "${i}" -lt 180 ]; do
    if [ "$(getprop sys.boot_completed)" = 1 ] \
      && [ "$(getprop init.svc.cnss-daemon)" = running ]; then
      return 0
    fi
    i=$(( i + 1 ))
    sleep 1
  done
  return 1
}

#######################################
# Stop Android services.
# Arguments:
#   Service names.
#######################################
stop_services() {
  local name
  for name in "$@"; do
    stop "${name}" 2>/dev/null
  done
}

#######################################
# Start Android services in the order given.
# Arguments:
#   Service names.
#######################################
start_services() {
  local name
  for name in "$@"; do
    start "${name}" 2>/dev/null
  done
}

#######################################
# Register and start Wi-Fi and DHCP services under runsvdir.
# Globals:
#   CHARGE_CONTROL
#   LOG_FILE
#   MODDIR
#   SERVICE_DIR
#######################################
start_supervisor() {
  local i name svcs
  svcs='wifi dhcp dns-forwarder'
  [ "${CHARGE_CONTROL}" = 1 ] && svcs="${svcs} charge"
  [ "${DISPLAY_ENABLED}" = 1 ] && svcs="${svcs} display"
  sh /data/adb/modules/rootfs/scripts/control.sh start >/dev/null 2>&1
  if [ ! -f "${HEADLESS_DIR}/resolv.conf" ]; then
    {
      printf 'nameserver 223.5.5.5\n'
      printf 'nameserver 223.6.6.6\n'
    } >"${HEADLESS_DIR}/resolv.conf"
  fi
  mkdir -p "${SERVICE_DIR}"
  for name in ${svcs}; do
    mkdir -p "${SERVICE_DIR}/${name}"
    rm -f "${SERVICE_DIR}/${name}/run" "${SERVICE_DIR}/${name}/down"
    {
      printf '#!/system/bin/sh\n'
      printf 'exec >>"%s" 2>&1\n' "${LOG_FILE}"
      printf 'exec sh "%s/scripts/service/%s.sh"\n' "${MODDIR}" "${name}"
    } >"${SERVICE_DIR}/${name}/run"
    chmod 755 "${SERVICE_DIR}/${name}/run"
  done
  for name in ${svcs}; do
    i=0
    while [ "${i}" -lt 10 ]; do
      [ -e "${SERVICE_DIR}/${name}/supervise/ok" ] && break
      i=$(( i + 1 ))
      sleep 1
    done
    sv up "${SERVICE_DIR}/${name}" >/dev/null 2>&1
  done
}

#######################################
# Stop monitored services and wait until service locks are released.
# Globals:
#   SERVICE_DIR
#######################################
stop_supervisor() {
  local i name
  for name in wifi dhcp dns-forwarder charge display; do
    if [ -d "${SERVICE_DIR}/${name}" ]; then
      touch "${SERVICE_DIR}/${name}/down"
      sv -w 5 down "${SERVICE_DIR}/${name}" >/dev/null 2>&1
      sv -w 5 exit "${SERVICE_DIR}/${name}" >/dev/null 2>&1
    fi
  done
  i=0
  while service_locked && [ "${i}" -lt 10 ]; do
    sleep 1
    i=$(( i + 1 ))
  done
  rm -rf "${SERVICE_DIR}/wifi" "${SERVICE_DIR}/dhcp" \
    "${SERVICE_DIR}/dns-forwarder" "${SERVICE_DIR}/charge" \
    "${SERVICE_DIR}/display"
}

#######################################
# Wait for an IPv4 address and a default route on the Wi-Fi interface.
# Globals:
#   WIFI_IFACE
#   WIFI_TIMEOUT
# Returns:
#   1 on timeout.
#######################################
wait_network() {
  local i=0
  while [ "${i}" -lt "${WIFI_TIMEOUT}" ]; do
    if ip -4 addr show dev "${WIFI_IFACE}" | grep -q 'inet ' \
      && ip route show default dev "${WIFI_IFACE}" | grep -q default; then
      return 0
    fi
    i=$(( i + 1 ))
    sleep 1
  done
  return 1
}

#######################################
# Start Android services and its Wi-Fi again.
# Globals:
#   ANDROID_SERVICES
#   WIFI_SERVICES
#######################################
restore_android() {
  local i=0
  local state=''
  log 'restoring Android services'
  set_charge_state 0
  set_fast_charge 1
  echo 0 >/sys/class/backlight/panel0-backlight/bl_power 2>/dev/null
  echo 2048 >/sys/class/backlight/panel0-backlight/brightness 2>/dev/null
  start vendor.hwcomposer-2-4 2>/dev/null
  while [ "${i}" -lt 30 ]; do
    state="$(getprop init.svc.vendor.hwcomposer-2-4)"
    if [ -z "${state}" ] || [ "${state}" = 'running' ]; then
      break
    fi
    i=$(( i + 1 ))
    sleep 1
  done
  if [ -e /dev/socket/dnsproxyd.netd ]; then
    mv -f /dev/socket/dnsproxyd.netd /dev/socket/dnsproxyd 2>/dev/null || true
  fi
  start_services ${ANDROID_SERVICES} ${WIFI_SERVICES}
  echo headless_lock >/sys/power/wake_unlock 2>/dev/null
  i=0
  while [ "${i}" -lt 60 ]; do
    cmd -l 2>/dev/null | grep -q '^wifi$' && break
    i=$(( i + 1 ))
    sleep 1
  done
  svc wifi enable 2>/dev/null
}

#######################################
# Stop Android, bring Wi-Fi up from this module, or restore Android.
# Globals:
#   ANDROID_SERVICES
#   BIN_DIR
#   DISABLED_FILE
#   WIFI_CONF
#   WIFI_IFACE
#   WIFI_SERVICES
#   WIFI_TIMEOUT
# Outputs:
#   Writes the result to stdout.
# Returns:
#   1 if the module is not configured or the network does not come up.
#######################################
start_headless() {
  local i=0
  local state=''
  if is_running; then
    echo 'headless already running'
    exit 0
  fi
  rm -f "${DISABLED_FILE}"
  if ! is_configured; then
    err "no network in ${WIFI_CONF}, Android left unchanged"
    exit 1
  fi
  if [ ! -x "${BIN_DIR}/wpa_supplicant" ]; then
    err 'wpa_supplicant is missing, reinstall the module'
    exit 1
  fi
  if ! wait_boot; then
    err 'boot did not complete'
    exit 1
  fi
  log 'stopping Android'
  echo headless_lock >/sys/power/wake_lock
  stop vendor.hwcomposer-2-4 2>/dev/null
  stop_services ${WIFI_SERVICES}
  stop_services ${ANDROID_SERVICES}
  while [ "${i}" -lt 30 ]; do
    state="$(getprop init.svc.vendor.hwcomposer-2-4)"
    if [ -z "${state}" ] || [ "${state}" = 'stopped' ]; then
      break
    fi
    i=$(( i + 1 ))
    sleep 1
  done
  if [ -e /dev/socket/dnsproxyd ]; then
    mv -f /dev/socket/dnsproxyd /dev/socket/dnsproxyd.netd 2>/dev/null || true
  fi
  sh "${MODDIR}/scripts/net.sh" add
  ip link set "${WIFI_IFACE}" up
  start_supervisor
  if wait_network; then
    sh "${MODDIR}/scripts/net.sh" add
    echo 'headless started'
    log 'network is up'
    return 0
  fi
  err "no network on ${WIFI_IFACE} after ${WIFI_TIMEOUT} s"
  log 'network did not come up'
  stop_supervisor
  restore_android
  exit 1
}

#######################################
# Stop the supervisor, remove the rules and bring Android back.
# Globals:
#   DISABLED_FILE
#   MODDIR
#   WIFI_IFACE
#######################################
stop_headless() {
  touch "${DISABLED_FILE}"
  stop_supervisor
  set_charge_state 0
  set_fast_charge 1
  sh "${MODDIR}/scripts/net.sh" del
  ip addr flush dev "${WIFI_IFACE}" 2>/dev/null
  restore_android
  echo 'headless stopped'
}

#######################################
# Print battery and charge control status.
# Globals:
#   BATTERY_DIR
#######################################
show_battery() {
  local cap fast stat susp
  [ -d "${BATTERY_DIR}" ] || return 0
  cap="$(cat "${BATTERY_DIR}/capacity" 2>/dev/null)"
  stat="$(cat "${BATTERY_DIR}/status" 2>/dev/null)"
  if is_suspended; then
    susp='suspended'
  else
    susp='allowed'
  fi
  if [ -f /sys/class/qcom-battery/restrict_chg ] \
    && [ "$(cat /sys/class/qcom-battery/restrict_chg 2>/dev/null)" = 1 ]; then
    fast='slow'
  elif [ -f "${BATTERY_DIR}/slowly_charging" ] \
    && [ "$(cat "${BATTERY_DIR}/slowly_charging" 2>/dev/null)" = 1 ]; then
    fast='slow'
  else
    fast='normal'
  fi
  echo "battery: ${cap}% (${stat}, charge: ${susp}, speed: ${fast})"
}

#######################################
# Print the status.
# Globals:
#   SERVICE_DIR
#   WIFI_IFACE
# Returns:
#   1 if Wi-Fi services do not run.
#######################################
show_status() {
  local svcs
  if ! is_running; then
    echo 'headless stopped'
    show_battery
    return 1
  fi
  echo 'headless running'
  svcs="${SERVICE_DIR}/wifi ${SERVICE_DIR}/dhcp"
  [ -d "${SERVICE_DIR}/dns-forwarder" ] && \
    svcs="${svcs} ${SERVICE_DIR}/dns-forwarder"
  [ -d "${SERVICE_DIR}/charge" ] && svcs="${svcs} ${SERVICE_DIR}/charge"
  [ -d "${SERVICE_DIR}/display" ] && svcs="${svcs} ${SERVICE_DIR}/display"
  sv status ${svcs} 2>/dev/null
  ip -br addr show dev "${WIFI_IFACE}"
  show_battery
}

#######################################
# Print the last lines of the log.
# Globals:
#   LOG_FILE
# Arguments:
#   Number of lines, 40 by default.
#######################################
show_log() {
  tail -n "${1:-40}" "${LOG_FILE}"
}

#######################################
# Dispatch the first argument to a subcommand.
#######################################
main() {
  case "${1:-}" in
    start) start_headless ;;
    stop) stop_headless ;;
    restart)
      stop_headless
      start_headless
      ;;
    status) show_status ;;
    log) show_log "${2:-}" ;;
    *)
      err "usage: $0 {start|stop|restart|status|log [lines]}"
      exit 1
      ;;
  esac
}

main "$@"
