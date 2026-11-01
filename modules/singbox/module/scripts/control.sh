#!/system/bin/sh
#
# Controls the sing-box daemon: start, stop, restart, status, log, check.
#
# POSIX sh only: KernelSU runs this with Android's /system/bin/sh (mksh) and
# busybox ash.

SINGBOX_DIR=/data/adb/singbox
BIN="${SINGBOX_DIR}/bin/sing-box"
CONFIG="${SINGBOX_DIR}/config.json"
RUN_DIR="${SINGBOX_DIR}/run"
PID_FILE="${RUN_DIR}/singbox.pid"
LOG_FILE="${RUN_DIR}/singbox.log"
BUSYBOX=/data/adb/rootfs/bin/busybox
[ -x "${BUSYBOX}" ] || BUSYBOX=/data/adb/ksu/bin/busybox
SERVICE_DIR=/data/adb/rootfs/service/singbox
readonly BIN BUSYBOX CONFIG LOG_FILE PID_FILE RUN_DIR SERVICE_DIR SINGBOX_DIR

#######################################
# Print an error message to stderr.
# Arguments:
#   Message.
#######################################
err() {
  echo "$*" >&2
}

#######################################
# Check whether a process is this module's sing-box.
# Globals:
#   BIN
# Arguments:
#   Process ID.
# Returns:
#   0 if the executable is the module binary, 1 otherwise.
#######################################
is_ours() {
  local exe
  exe="$(readlink "/proc/$1/exe" 2>/dev/null)"
  exe="${exe% (deleted)}"
  [ "${exe}" = "${BIN}" ]
}

#######################################
# Get the active process ID from supervise or pid file.
# Globals:
#   PID_FILE
#   SERVICE_DIR
# Outputs:
#   Writes the process ID to stdout.
#######################################
get_pid() {
  local pid=''
  if [ -f "${SERVICE_DIR}/supervise/pid" ]; then
    pid="$(cat "${SERVICE_DIR}/supervise/pid" 2>/dev/null)"
  fi
  if [ -z "${pid}" ] && [ -f "${PID_FILE}" ]; then
    pid="$(cat "${PID_FILE}" 2>/dev/null)"
  fi
  printf '%s' "${pid}"
}

#######################################
# Check whether the pid file names a live sing-box of this module.
# Globals:
#   PID_FILE
#   SERVICE_DIR
# Returns:
#   0 if the daemon runs, 1 otherwise.
#######################################
is_running() {
  local pid
  pid="$(get_pid)"
  [ -n "${pid}" ] || return 1
  kill -0 "${pid}" 2>/dev/null || return 1
  is_ours "${pid}"
}

#######################################
# Check for a sing-box of this module without a usable pid file.
# Returns:
#   0 if one is alive, 1 otherwise.
#######################################
any_daemon_is_ours() {
  local pid
  for pid in $(pidof sing-box 2>/dev/null); do
    is_ours "${pid}" && return 0
  done
  return 1
}

#######################################
# Validate the config with the binary that will run it.
# Globals:
#   BIN
#   CONFIG
#   RUN_DIR
# Returns:
#   0 if the config loads, 1 otherwise.
#######################################
check_config() {
  if [ ! -f "${CONFIG}" ]; then
    err "${CONFIG} is missing, reinstall the module"
    return 1
  fi
  mkdir -p "${RUN_DIR}"
  "${BIN}" check -D "${RUN_DIR}" -c "${CONFIG}"
}

#######################################
# Keep the previous run's log as singbox.log.1.
# Globals:
#   LOG_FILE
#######################################
rotate_log() {
  if [ -s "${LOG_FILE}" ]; then
    mv -f "${LOG_FILE}" "${LOG_FILE}.1"
  fi
  : >"${LOG_FILE}"
}

#######################################
# Wait until the daemon reports that it started.
# Globals:
#   LOG_FILE
#   SERVICE_DIR
# Returns:
#   0 if sing-box started, 1 if it exited during the wait.
#######################################
wait_started() {
  local i
  i=0
  while [ "${i}" -lt 20 ]; do
    if is_running; then
      if grep -q 'sing-box started' "${LOG_FILE}" 2>/dev/null; then
        return 0
      fi
    fi
    sleep 0.5
    i=$(( i + 1 ))
  done
  is_running
}

#######################################
# Start the daemon under runsvdir.
# Globals:
#   BIN
#   BUSYBOX
#   CONFIG
#   LOG_FILE
#   PID_FILE
#   RUN_DIR
#   SERVICE_DIR
# Returns:
#   1 if the binary, config or startup fails.
#######################################
start_daemon() {
  local i pid
  if is_running || any_daemon_is_ours; then
    echo 'sing-box already running'
    return 0
  fi
  if [ ! -x "${BIN}" ]; then
    err 'sing-box is not installed, reinstall the module'
    return 1
  fi
  if ! check_config; then
    return 1
  fi
  sh /data/adb/modules/rootfs/scripts/control.sh start >/dev/null 2>&1
  mkdir -p "${RUN_DIR}" "${SERVICE_DIR}"
  rm -f "${PID_FILE}" "${SERVICE_DIR}/down"
  rotate_log
  {
    printf '#!/system/bin/sh\n'
    printf 'exec >>"%s" 2>&1\n' "${LOG_FILE}"
    printf 'exec "%s" run -D "%s" -c "%s"\n' \
      "${BIN}" "${RUN_DIR}" "${CONFIG}"
  } >"${SERVICE_DIR}/run"
  chmod 755 "${SERVICE_DIR}/run"

  i=0
  while [ "${i}" -lt 10 ]; do
    [ -e "${SERVICE_DIR}/supervise/ok" ] && break
    i=$(( i + 1 ))
    sleep 1
  done
  "${BUSYBOX}" sv up "${SERVICE_DIR}" >/dev/null 2>&1

  if wait_started; then
    pid="$(get_pid)"
    [ -n "${pid}" ] && printf '%s' "${pid}" >"${PID_FILE}"
    echo "sing-box started (pid ${pid})"
    return 0
  fi
  err "sing-box failed to start, see ${LOG_FILE}"
  tail -n 20 "${LOG_FILE}"
  return 1
}

#######################################
# Terminate every sing-box of this module that is still alive.
#######################################
kill_ours() {
  local pid
  for pid in $(pidof sing-box 2>/dev/null); do
    is_ours "${pid}" && kill "${pid}" 2>/dev/null
  done
  return 0
}

#######################################
# Stop the daemon and wait for its cleanup of the tun and iptables rules.
# Globals:
#   BUSYBOX
#   PID_FILE
#   SERVICE_DIR
# Outputs:
#   Writes the result to stdout.
#######################################
stop_daemon() {
  local i pid
  pid=''
  if is_running; then
    pid="$(get_pid)"
  fi
  if [ -d "${SERVICE_DIR}" ]; then
    touch "${SERVICE_DIR}/down"
    "${BUSYBOX}" sv -w 15 down "${SERVICE_DIR}" >/dev/null 2>&1
  fi
  if [ -n "${pid}" ]; then
    kill "${pid}" 2>/dev/null
    i=0
    while kill -0 "${pid}" 2>/dev/null && [ "${i}" -lt 15 ]; do
      sleep 1
      i=$(( i + 1 ))
    done
    if kill -0 "${pid}" 2>/dev/null; then
      kill -9 "${pid}" 2>/dev/null
    fi
  fi
  kill_ours
  rm -f "${PID_FILE}"
  echo 'sing-box stopped'
}

#######################################
# Print the daemon status.
# Globals:
#   BUSYBOX
#   PID_FILE
#   SERVICE_DIR
# Outputs:
#   Writes the status to stdout.
# Returns:
#   1 if the daemon is stopped.
#######################################
show_status() {
  local pid
  if ! is_running; then
    echo 'sing-box stopped'
    return 1
  fi
  pid="$(get_pid)"
  echo "sing-box running (pid ${pid})"
  "${BUSYBOX}" sv status "${SERVICE_DIR}" 2>/dev/null
}

#######################################
# Print the last lines of the daemon log.
# Globals:
#   LOG_FILE
# Outputs:
#   Writes the log lines to stdout.
# Arguments:
#   Number of lines, 40 by default.
#######################################
show_log() {
  local lines="${1:-40}"
  [ -f "${LOG_FILE}" ] || return 0
  tail -n "${lines}" "${LOG_FILE}"
}

#######################################
# Validate the config and report the result.
# Returns:
#   1 if the config is invalid.
#######################################
show_check() {
  check_config || return 1
  echo 'config is valid'
}

#######################################
# Dispatch the first argument to a subcommand.
#######################################
main() {
  case "${1:-}" in
    start)
      start_daemon
      ;;
    stop)
      stop_daemon
      ;;
    restart)
      stop_daemon
      start_daemon
      ;;
    status)
      show_status
      ;;
    log)
      show_log "${2:-}"
      ;;
    check)
      show_check
      ;;
    *)
      err "usage: $0 {start|stop|restart|status|log [lines]|check}"
      exit 1
      ;;
  esac
}

main "$@"
