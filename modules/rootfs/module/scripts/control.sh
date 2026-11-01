#!/system/bin/sh
#
# Controls the rootfs container and supervisor: start, stop, restart,
# status, log.

MODDIR="$(cd "${0%/*}/.." && pwd)"
readonly MODDIR
ROOTFS_DIR=/data/adb/rootfs
BUSYBOX="${ROOTFS_DIR}/bin/busybox"
[ -x "${BUSYBOX}" ] || BUSYBOX=/data/adb/ksu/bin/busybox
PID_FILE="${ROOTFS_DIR}/run/rootfs.pid"
LOG_FILE="${ROOTFS_DIR}/run/rootfs.log"
SERVICE_DIR="${ROOTFS_DIR}/service"
readonly BUSYBOX LOG_FILE PID_FILE ROOTFS_DIR SERVICE_DIR

#######################################
# Print an error message to stderr.
# Arguments:
#   Message.
#######################################
err() {
  echo "$*" >&2
}

#######################################
# Check whether a process is the rootfs supervisor.
# Arguments:
#   Process ID.
# Returns:
#   0 if the process matches, 1 otherwise.
#######################################
is_ours() {
  local cmdline
  cmdline="$(tr '\0' ' ' <"/proc/$1/cmdline" 2>/dev/null)"
  case "${cmdline}" in
    *"runsvdir"*"${SERVICE_DIR}"* | *"runsvdir"*"/service"*)
      return 0
      ;;
  esac
  return 1
}

#######################################
# Check whether the supervisor runs.
# Globals:
#   PID_FILE
# Returns:
#   0 if it runs, 1 otherwise.
#######################################
is_running() {
  local pid
  [ -f "${PID_FILE}" ] || return 1
  pid="$(cat "${PID_FILE}" 2>/dev/null)"
  [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null && is_ours "${pid}"
}

#######################################
# Check whether a runsv process still holds a service lock.
# Globals:
#   BUSYBOX
#   SERVICE_DIR
# Returns:
#   0 if a lock is held, 1 otherwise.
#######################################
service_locked() {
  local lock
  for lock in "${SERVICE_DIR}"/*/supervise/lock; do
    [ -e "${lock}" ] || continue
    "${BUSYBOX}" flock -n "${lock}" true 2>/dev/null || return 0
  done
  return 1
}

#######################################
# Start the rootfs container and supervisor.
# Globals:
#   BUSYBOX
#   LOG_FILE
#   MODDIR
#   PID_FILE
#   ROOTFS_DIR
# Returns:
#   1 if startup fails.
#######################################
start_daemon() {
  local i
  if is_running; then
    echo 'rootfs already running'
    return 0
  fi
  if [ ! -x "${BUSYBOX}" ]; then
    err 'busybox is missing, reinstall the module'
    return 1
  fi
  mkdir -p "${ROOTFS_DIR}/run" "${ROOTFS_DIR}/service"

  i=0
  while ! mkdir "${ROOTFS_DIR}/run/start.lock.d" 2>/dev/null; do
    if is_running; then
      echo 'rootfs already running'
      return 0
    fi
    i=$(( i + 1 ))
    if [ "${i}" -ge 30 ]; then
      rm -rf "${ROOTFS_DIR}/run/start.lock.d"
      break
    fi
    sleep 1
  done

  if is_running; then
    rm -rf "${ROOTFS_DIR}/run/start.lock.d"
    echo 'rootfs already running'
    return 0
  fi

  rm -f "${PID_FILE}"
  "${BUSYBOX}" setsid "${BUSYBOX}" unshare -m --propagation private \
    "${BUSYBOX}" sh "${MODDIR}/scripts/start.sh" \
    >>"${LOG_FILE}" 2>&1 </dev/null &
  i=0
  while [ "${i}" -lt 30 ]; do
    if is_running; then
      rm -rf "${ROOTFS_DIR}/run/start.lock.d"
      echo 'rootfs started'
      return 0
    fi
    i=$(( i + 1 ))
    sleep 1
  done
  rm -rf "${ROOTFS_DIR}/run/start.lock.d"
  err "rootfs failed to start, see ${LOG_FILE}"
  return 1
}

#######################################
# Stop the supervisor and all monitored services.
# Globals:
#   BUSYBOX
#   PID_FILE
#   SERVICE_DIR
#######################################
stop_daemon() {
  local i pid
  pid=''
  if is_running; then
    pid="$(cat "${PID_FILE}" 2>/dev/null)"
  fi
  if [ -d "${SERVICE_DIR}" ]; then
    "${BUSYBOX}" sv -w 15 exit "${SERVICE_DIR}"/* >/dev/null 2>&1
  fi
  if [ -n "${pid}" ]; then
    kill "${pid}" 2>/dev/null
    i=0
    while kill -0 "${pid}" 2>/dev/null && [ "${i}" -lt 10 ]; do
      sleep 1
      i=$(( i + 1 ))
    done
    if kill -0 "${pid}" 2>/dev/null; then
      kill -9 "${pid}" 2>/dev/null
    fi
  fi
  i=0
  while service_locked && [ "${i}" -lt 10 ]; do
    sleep 1
    i=$(( i + 1 ))
  done
  rm -f "${PID_FILE}"
  echo 'rootfs stopped'
}

#######################################
# Print the status of the container and its services.
# Globals:
#   BUSYBOX
#   PID_FILE
#   SERVICE_DIR
# Returns:
#   1 if rootfs is stopped.
#######################################
show_status() {
  local pid
  if ! is_running; then
    echo 'rootfs stopped'
    return 1
  fi
  pid="$(cat "${PID_FILE}" 2>/dev/null)"
  echo "rootfs running (runsvdir pid ${pid})"
  "${BUSYBOX}" sv status "${SERVICE_DIR}"/* 2>/dev/null
}

#######################################
# Print the last lines of the log.
# Globals:
#   LOG_FILE
# Arguments:
#   Number of lines, 40 by default.
#######################################
show_log() {
  local lines="${1:-40}"
  tail -n "${lines}" "${LOG_FILE}"
}

#######################################
# Dispatch the command line arguments.
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
    *)
      err "usage: $0 {start|stop|restart|status|log [lines]}"
      exit 1
      ;;
  esac
}

main "$@"

