#!/system/bin/sh
#
# Supervises the Layer 0 host services under /data/adb/rootfs/host-service
# with BusyBox runsvdir. Commands: start, stop, status.

MODDIR="$(cd "${0%/*}/.." && pwd)"
readonly MODDIR
. "${MODDIR}/scripts/common.sh"

HOST_DIR="${ROOTFS_HOME}/host-service"
HOST_PID_FILE="${RUN_DIR}/host.pid"
HOST_LOG="${RUN_DIR}/host.log"
readonly HOST_DIR HOST_LOG HOST_PID_FILE

#######################################
# Check whether a process is the host runsvdir.
# Arguments:
#   Process ID.
#######################################
is_ours() {
  local cmdline
  cmdline="$(tr '\0' ' ' <"/proc/${1}/cmdline" 2>/dev/null)"
  case "${cmdline}" in
    *runsvdir*"${HOST_DIR}"*) return 0 ;;
  esac
  return 1
}

#######################################
# Print the host runsvdir PID, when it runs.
#######################################
host_pid() {
  local pid
  pid="$(cat "${HOST_PID_FILE}" 2>/dev/null)"
  [ -n "${pid}" ] || return 1
  kill -0 "${pid}" 2>/dev/null || return 1
  is_ours "${pid}" || return 1
  echo "${pid}"
}

#######################################
# Start the host supervisor, unless it runs.
# Globals:
#   HOST_DIR
#   HOST_LOG
#   HOST_PID_FILE
#######################################
host_start() {
  local count=0 pid
  if host_pid >/dev/null; then
    log 'host supervisor already runs'
    return 0
  fi
  mkdir -p "${HOST_DIR}" "${RUN_DIR}"
  log "starting the host supervisor over ${HOST_DIR}"
  "${BUSYBOX}" setsid "${BUSYBOX}" runsvdir -P "${HOST_DIR}" \
    >>"${HOST_LOG}" 2>&1 </dev/null &
  while [ "${count}" -lt 15 ]; do
    pid="$("${BUSYBOX}" pgrep -f "runsvdir -P ${HOST_DIR}" | head -n 1)"
    if [ -n "${pid}" ]; then
      printf '%s\n' "${pid}" >"${HOST_PID_FILE}"
      log "host supervisor started (pid ${pid})"
      return 0
    fi
    sleep 1
    count=$(( count + 1 ))
  done
  err 'the host supervisor did not start'
  return 1
}

#######################################
# Stop every host service, then the supervisor.
# Globals:
#   HOST_DIR
#   HOST_PID_FILE
#######################################
host_stop() {
  local child count=0 pid
  pid="$(host_pid)" || pid=''
  if [ -z "${pid}" ]; then
    log 'host supervisor is stopped'
    rm -f "${HOST_PID_FILE}"
    return 0
  fi
  if [ -d "${HOST_DIR}" ]; then
    "${BUSYBOX}" sv -w 10 exit "${HOST_DIR}"/* >/dev/null 2>&1
  fi
  kill -TERM "${pid}" 2>/dev/null
  while kill -0 "${pid}" 2>/dev/null; do
    if [ "${count}" -ge 10 ]; then
      kill -KILL "${pid}" 2>/dev/null
      break
    fi
    sleep 1
    count=$(( count + 1 ))
  done
  # runsvdir leaves a runsv per service, and an orphaned runsv keeps the
  # service alive after this script returns. Later generations then talk to
  # the wrong supervisor and cannot stop the old process.
  stop_stale_children
  rm -f "${HOST_PID_FILE}"
  log 'host supervisor stopped'
}

#######################################
# Kill the runsv tree that serves this directory, whichever generation it
# belongs to. A child that outlives its supervisor holds the ports and the
# tun device of its service.
#######################################
stop_stale_children() {
  local count=0 pids
  while [ "${count}" -lt 10 ]; do
    pids="$("${BUSYBOX}" pgrep -f "runsv ${HOST_DIR}/" 2>/dev/null)"
    [ -n "${pids}" ] || break
    for child in ${pids}; do
      kill -TERM "${child}" 2>/dev/null
    done
    sleep 1
    count=$(( count + 1 ))
  done
  for child in $("${BUSYBOX}" pgrep -f "runsv ${HOST_DIR}/" 2>/dev/null); do
    kill -KILL "${child}" 2>/dev/null
  done
}

#######################################
# Print the state of the host services.
# Globals:
#   HOST_DIR
#######################################
host_status() {
  local pid
  pid="$(host_pid)" || pid=''
  if [ -z "${pid}" ]; then
    log 'host supervisor: stopped'
    return 1
  fi
  log "host supervisor: running (pid ${pid})"
  "${BUSYBOX}" sv status "${HOST_DIR}"/* 2>/dev/null
}

#######################################
# Dispatch the command line arguments.
#######################################
main() {
  require_busybox
  case "${1:-}" in
    start) host_start ;;
    stop) host_stop ;;
    status) host_status ;;
    *)
      err "usage: $0 start|stop|status"
      exit 1
      ;;
  esac
}

main "$@"
