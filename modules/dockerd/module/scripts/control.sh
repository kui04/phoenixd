#!/system/bin/sh
#
# Controls the dockerd daemon: start, stop, restart, status, log.

MODDIR="$(cd "${0%/*}/.." && pwd)"
readonly MODDIR
DOCKERD_DIR=/data/adb/dockerd
BUSYBOX="${DOCKERD_DIR}/bin/busybox"
[ -x "${BUSYBOX}" ] || BUSYBOX=/data/adb/rootfs/bin/busybox
[ -x "${BUSYBOX}" ] || BUSYBOX=/data/adb/ksu/bin/busybox
PID_FILE="${DOCKERD_DIR}/run/dockerd.pid"
SOCKET="${DOCKERD_DIR}/run/docker.sock"
LOG_FILE="${DOCKERD_DIR}/run/dockerd.log"
SERVICE_DIR=/data/adb/rootfs/service/dockerd
readonly BUSYBOX DOCKERD_DIR LOG_FILE PID_FILE SERVICE_DIR SOCKET

#######################################
# Print an error message to stderr.
# Arguments:
#   Message.
#######################################
err() {
  echo "$*" >&2
}

#######################################
# Check whether a process belongs to this module.
# Globals:
#   DOCKERD_DIR
# Arguments:
#   Process ID.
# Returns:
#   0 for a module binary or a daemon in the container, 1 otherwise.
#######################################
is_ours() {
  local exe
  exe="$(readlink "/proc/$1/exe" 2>/dev/null)"
  exe="${exe% (deleted)}"
  case "${exe}" in
    "${DOCKERD_DIR}"/bin/*) return 0 ;;
    /bin/dockerd | /bin/containerd | /bin/containerd-shim-runc-v2) return 0 ;;
    /bin/docker-proxy | /bin/runc | /bin/docker-init) return 0 ;;
  esac
  return 1
}

#######################################
# Check whether the pid file names a live daemon of this module.
# Globals:
#   PID_FILE
# Returns:
#   0 if the daemon runs, 1 otherwise.
#######################################
is_running() {
  local pid
  [ -f "${PID_FILE}" ] || return 1
  pid="$(cat "${PID_FILE}" 2>/dev/null)"
  [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null && is_ours "${pid}"
}

#######################################
# Check for a daemon of this module without a usable pid file.
# Returns:
#   0 if one is alive, 1 otherwise.
#######################################
any_daemon_is_ours() {
  local pid
  for pid in $(pidof dockerd 2>/dev/null); do
    is_ours "${pid}" && return 0
  done
  return 1
}

#######################################
# Kill every process left in a Docker cgroup.
# Globals:
#   BUSYBOX
#######################################
kill_cgroup_procs() {
  local file hierarchy pid
  for hierarchy in /dev/cpuctl /dev/memcg /dev/blkio; do
    [ -d "${hierarchy}/docker" ] || continue
    "${BUSYBOX}" find "${hierarchy}/docker" -name cgroup.procs 2>/dev/null \
      | while read -r file; do
      while read -r pid; do
        kill -9 "${pid}" 2>/dev/null
      done <"${file}" 2>/dev/null
    done
  done
}

#######################################
# Kill the daemons, shims and helpers that belong to this module.
#######################################
kill_ours() {
  local name pid
  for name in dockerd containerd containerd-shim-runc-v2 docker-proxy runc \
    docker-init; do
    for pid in $(pidof "${name}" 2>/dev/null); do
      is_ours "${pid}" && kill -9 "${pid}" 2>/dev/null
    done
  done
}

#######################################
# Start the daemon and wait for its socket.
# Globals:
#   BUSYBOX
#   DOCKERD_DIR
#   LOG_FILE
#   MODDIR
#   PID_FILE
#   SERVICE_DIR
#   SOCKET
# Outputs:
#   Writes the result to stdout.
# Returns:
#   1 if the daemon is missing or the socket does not appear.
#######################################
start_daemon() {
  local i
  if is_running || any_daemon_is_ours; then
    echo 'dockerd already running'
    return 0
  fi
  if [ ! -x "${DOCKERD_DIR}/bin/dockerd" ]; then
    err 'dockerd is not installed, reinstall the module'
    return 1
  fi
  sh /data/adb/modules/rootfs/scripts/control.sh start >/dev/null 2>&1
  mkdir -p "${DOCKERD_DIR}/run" "${SERVICE_DIR}"
  rm -f "${SOCKET}" "${PID_FILE}" "${SERVICE_DIR}/down"
  printf '#!/system/bin/sh\nexec >>"%s" 2>&1\nexec sh "%s/scripts/start.sh"\n' \
    "${LOG_FILE}" "${MODDIR}" >"${SERVICE_DIR}/run"
  chmod 755 "${SERVICE_DIR}/run"

  i=0
  while [ "${i}" -lt 10 ]; do
    [ -e "${SERVICE_DIR}/supervise/ok" ] && break
    i=$(( i + 1 ))
    sleep 1
  done
  "${BUSYBOX}" sv up "${SERVICE_DIR}" >/dev/null 2>&1

  i=0
  while [ "${i}" -lt 30 ]; do
    [ -S "${SOCKET}" ] && break
    i=$(( i + 1 ))
    sleep 1
  done
  if [ -S "${SOCKET}" ]; then
    echo 'dockerd started'
    "${BUSYBOX}" setsid sh "${MODDIR}/scripts/net.sh" \
      >>"${LOG_FILE}" 2>&1 </dev/null &
  else
    err "dockerd failed to start, see ${LOG_FILE}"
    return 1
  fi
}

#######################################
# Stop the daemon and everything it left behind.
# Globals:
#   BUSYBOX
#   PID_FILE
#   SERVICE_DIR
#   SOCKET
# Outputs:
#   Writes the result to stdout.
#######################################
stop_daemon() {
  local i pid
  pid=''
  if is_running; then
    pid="$(cat "${PID_FILE}" 2>/dev/null)"
  fi
  if [ -d "${SERVICE_DIR}" ]; then
    touch "${SERVICE_DIR}/down"
    "${BUSYBOX}" sv -w 15 down "${SERVICE_DIR}" >/dev/null 2>&1
  fi
  if [ -n "${pid}" ]; then
    kill "${pid}" 2>/dev/null
    i=0
    while kill -0 "${pid}" 2>/dev/null \
      && is_ours "${pid}" \
      && [ "${i}" -lt 15 ]; do
      i=$(( i + 1 ))
      sleep 1
    done
    if kill -0 "${pid}" 2>/dev/null && is_ours "${pid}"; then
      kill -9 "${pid}" 2>/dev/null
    fi
  fi
  kill_cgroup_procs
  kill_ours
  rm -f "${PID_FILE}" "${SOCKET}"
  echo 'dockerd stopped'
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
    echo 'dockerd stopped'
    return 1
  fi
  pid="$(cat "${PID_FILE}" 2>/dev/null)"
  if [ -n "${pid}" ]; then
    echo "dockerd running (pid ${pid})"
  else
    echo 'dockerd running'
  fi
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
  tail -n "${lines}" "${LOG_FILE}"
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
    *)
      err "usage: $0 {start|stop|restart|status|log [lines]}"
      exit 1
      ;;
  esac
}

main "$@"
