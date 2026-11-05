#!/system/bin/sh
#
# Controls the sing-box proxy host service and checks its routing objects.
# Commands: start, stop, status, log, check. Restart is stop then start.
#
# The service runs under the host runsvdir of modules/rootfs. This module owns
# only the proxy: Layer 1, the netns, NAT, and table 9500 belong to rootfs.

SINGBOX_DIR=/data/adb/singbox
ROOTFS_HOME="${ROOTFS_HOME:-/data/adb/rootfs}"
SERVICE_DIR="${ROOTFS_HOME}/host-service/singbox"
LOG_FILE="${ROOTFS_HOME}/run/singbox.log"
BUSYBOX=/data/adb/rootfs/bin/busybox
[ -x "${BUSYBOX}" ] || BUSYBOX=/data/adb/ksu/bin/busybox
readonly BUSYBOX LOG_FILE ROOTFS_HOME SERVICE_DIR SINGBOX_DIR

#######################################
# Print a message to stderr.
# Arguments:
#   Message.
#######################################
err() {
  echo "$*" >&2
}

#######################################
# Require the host service directory.
#######################################
require_service() {
  if [ ! -d "${SERVICE_DIR}" ]; then
    err "no host service at ${SERVICE_DIR}, reinstall the module"
    exit 1
  fi
}

#######################################
# Ensure the host supervisor of modules/rootfs runs. KernelSU starts the
# module scripts in an undefined order.
#######################################
ensure_supervisor() {
  local control=/data/adb/modules/rootfs/scripts/host.sh
  [ -f "${control}" ] || return 0
  if ! "${BUSYBOX}" sv status "${SERVICE_DIR}" >/dev/null 2>&1; then
    sh "${control}" start >/dev/null 2>&1
  fi
}

#######################################
# Start or stop the service.
# Arguments:
#   sv action.
#######################################
sv_action() {
  require_service
  case "${1}" in
    start)
      ensure_supervisor
      # A previous instance can still hold the tun device and the API port,
      # and the next one then dies with TUNSETIFF or "address already in use".
      if ! wait_proxy_release; then
        kill_leftovers
      fi
      ;;
    restart)
      ensure_supervisor
      # `sv restart` starts the new instance before the old one released the
      # tun device, so sing-box fails with TUNSETIFF: device or resource busy.
      # Stop, wait for the device to disappear, then start.
      "${BUSYBOX}" sv -w 15 down "${SERVICE_DIR}" >/dev/null 2>&1
      # A leftover instance keeps the API port and the tun device, and the new
      # one then dies with "bind: address already in use" or TUNSETIFF.
      if ! wait_proxy_release; then
        kill_leftovers
      fi
      "${BUSYBOX}" sv up "${SERVICE_DIR}"
      return
      ;;
  esac
  "${BUSYBOX}" sv -w 15 "${1}" "${SERVICE_DIR}"
}

#######################################
# Report whether something listens on the sing-box API port. Port 9090 is
# 2382 hex and a listening socket has state 0A in /proc/net/tcp.
#######################################
api_port_busy() {
  awk 'NR > 1 && $2 ~ /:2382$/ && $4 == "0A" { found = 1 }
    END { exit !found }' /proc/net/tcp /proc/net/tcp6 2>/dev/null
}

#######################################
# Wait until the previous instance released the tun device and the API port.
# The kernel keeps the device until every descriptor is closed.
#######################################
wait_proxy_release() {
  local count=0
  while [ "${count}" -lt 15 ]; do
    if ! ip link show tun0 >/dev/null 2>&1 && ! api_port_busy; then
      return 0
    fi
    sleep 1
    count=$(( count + 1 ))
  done
  return 1
}

#######################################
# End the instances that outlived their supervisor. runsv cannot reach them,
# and they hold the port and the device that the new instance needs.
#######################################
kill_leftovers() {
  local child count
  for count in 1 2; do
    for child in $("${BUSYBOX}" pgrep -f 'sing-box run -D' 2>/dev/null); do
      if [ "${count}" -eq 1 ]; then
        kill -TERM "${child}" 2>/dev/null
      else
        kill -KILL "${child}" 2>/dev/null
      fi
    done
    sleep 2
  done
  ip link del tun0 2>/dev/null
  sleep 1
}

#######################################
# Print the state of the service and of the proxy route objects.
#######################################
show_status() {
  require_service
  "${BUSYBOX}" sv status "${SERVICE_DIR}" 2>/dev/null
}

#######################################
# Print the last lines of the proxy log.
# Arguments:
#   Number of lines, 40 by default.
#######################################
show_log() {
  local lines="${1:-40}"
  if [ ! -f "${LOG_FILE}" ]; then
    err "no log yet: ${LOG_FILE}"
    return 1
  fi
  tail -n "${lines}" "${LOG_FILE}"
}

#######################################
# Check the three proxy invariants. A violation is reported, not fixed.
# Returns:
#   0 when every invariant holds, 1 otherwise.
#######################################
check_proxy() {
  local rc=0 running=0 status
  status="$("${BUSYBOX}" sv status "${SERVICE_DIR}" 2>/dev/null)"
  case "${status}" in
    run:*)
      running=1
      if ! ip -o link show tun0 >/dev/null 2>&1; then
        err 'check: the service runs, but tun0 does not exist'
        rc=1
      fi
      ;;
    *) echo 'check: sing-box is not running' ;;
  esac
  if ip rule show 2>/dev/null \
    | awk -F: '$1 >= 8900 && $1 <= 9600' \
    | grep -q suppress_prefixlength; then
    err 'check: a suppress_prefixlength rule shadows the Layer 0 and 1 rules'
    rc=1
  fi
  if ip route show table 2022 2>/dev/null | grep -q '^10\.0\.0\.0/24'; then
    err 'check: table 2022 routes 10.0.0.0/24 through the proxy'
    rc=1
  fi
  if [ "${running}" = 0 ]; then
    echo 'check: the proxy is stopped, Layer 1 fails open through table 9500'
  elif [ "${rc}" -eq 0 ]; then
    echo 'check: ok'
  fi
  return "${rc}"
}

#######################################
# Print the command usage.
#######################################
usage() {
  err "usage: $0 start|stop|status|log [lines]|check"
  exit 1
}

#######################################
# Dispatch the command line arguments.
#######################################
main() {
  case "${1:-}" in
    start | stop) sv_action "${1}" ;;
    restart)
      # `sv restart` starts the new instance before the old one released the
      # tun device and the API port, so it fails. Use stop, then start.
      err 'restart is not supported: run stop, then start'
      exit 1
      ;;
    status) show_status ;;
    log) show_log "${2:-}" ;;
    check) check_proxy ;;
    *) usage ;;
  esac
}

main "$@"
