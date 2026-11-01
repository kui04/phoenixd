#!/system/bin/sh
#
# runit service: controls battery charging thresholds.

MODDIR="$(cd "${0%/*}/../.." && pwd)"
readonly MODDIR
. "${MODDIR}/scripts/common.sh"

#######################################
# Resume charging and exit on signal.
#######################################
cleanup() {
  set_charge_state 0
  set_fast_charge 1
  exit 0
}

#######################################
# Check battery capacity and update charging state.
# Globals:
#   BATTERY_DIR
#   CHARGE_START_LEVEL
#   CHARGE_STOP_LEVEL
#   FAST_CHARGE
#######################################
check_charge() {
  local cap
  [ -d "${BATTERY_DIR}" ] || return 0
  cap="$(cat "${BATTERY_DIR}/capacity" 2>/dev/null)"
  case "${cap}" in
    ''|*[!0-9]*) return 0 ;;
  esac

  if [ "${cap}" -ge "${CHARGE_STOP_LEVEL}" ]; then
    if ! is_suspended; then
      set_charge_state 1
      log "charge: capacity ${cap}%, suspended (stop at ${CHARGE_STOP_LEVEL}%)"
    fi
  elif [ "${cap}" -le "${CHARGE_START_LEVEL}" ]; then
    if is_suspended; then
      set_charge_state 0
      set_fast_charge "${FAST_CHARGE}"
      log "charge: capacity ${cap}%, resumed (start at ${CHARGE_START_LEVEL}%)"
    fi
  fi
}

#######################################
# Main service loop.
# Globals:
#   BATTERY_DIR
#   CHARGE_CONTROL
#   CHARGE_INTERVAL
#   CHARGE_START_LEVEL
#   CHARGE_STOP_LEVEL
#   FAST_CHARGE
#######################################
main() {
  trap cleanup INT TERM

  if [ "${CHARGE_CONTROL}" != 1 ]; then
    set_charge_state 0
    set_fast_charge 1
    while true; do
      sleep 3600 &
      wait $!
    done
  fi

  if [ ! -d "${BATTERY_DIR}" ]; then
    log "charge: battery path ${BATTERY_DIR} not found"
    while true; do
      sleep 3600 &
      wait $!
    done
  fi

  case "${CHARGE_START_LEVEL}" in
    ''|*[!0-9]*) CHARGE_START_LEVEL=50 ;;
  esac
  case "${CHARGE_STOP_LEVEL}" in
    ''|*[!0-9]*) CHARGE_STOP_LEVEL=65 ;;
  esac
  case "${CHARGE_INTERVAL}" in
    ''|*[!0-9]*) CHARGE_INTERVAL=60 ;;
  esac
  if [ "${CHARGE_START_LEVEL}" -ge "${CHARGE_STOP_LEVEL}" ]; then
    CHARGE_START_LEVEL=50
    CHARGE_STOP_LEVEL=65
  fi

  set_fast_charge "${FAST_CHARGE}"
  log "charge: monitor started (${CHARGE_START_LEVEL}%-${CHARGE_STOP_LEVEL}%)" \
    "fast:${FAST_CHARGE}"

  while true; do
    check_charge
    sleep "${CHARGE_INTERVAL}" &
    wait $!
  done
}

main "$@"
