#!/system/bin/sh
#
# Controls Layer 1: start, stop, restart, status, log, exec, shell, host,
# image, docker. The image subcommands delegate to image.sh, and the Layer 0
# network objects belong to network.sh.

MODDIR="$(cd "${0%/*}/.." && pwd)"
. "${MODDIR}/scripts/common.sh"
readonly MODDIR
LOG_FILE="${RUN_DIR}/l1.log"
NETWORK_STATE="${ROOTFS_HOME}/state/network"
START_LOCK="${RUN_DIR}/start.lock.d"
START_TIMEOUT=30
# A supervisor that dies within this window is a failed start.
START_SETTLE=5
readonly LOG_FILE NETWORK_STATE START_LOCK START_SETTLE START_TIMEOUT

#######################################
# Take the start lock, or exit with a clear message. A second start while the
# first one runs must not touch the objects of the first one.
# Globals:
#   START_LOCK
#######################################
lock_start() {
  local count=0
  mkdir -p "${RUN_DIR}"
  while ! mkdir "${START_LOCK}" 2>/dev/null; do
    count=$(( count + 1 ))
    if [ "${count}" -ge 30 ]; then
      err 'taking over a stale start lock'
      rm -rf "${START_LOCK}"
      count=0
    fi
    sleep 1
  done
}

#######################################
# Release the start lock.
# Globals:
#   START_LOCK
#######################################
unlock_start() {
  rm -rf "${START_LOCK}"
}

#######################################
# Detach a loop device that a previous run left behind, so that a start after
# a crash converges.
# Globals:
#   IMAGE_PATH
#######################################
release_stale_image() {
  if [ -n "$(image_loop_device)" ]; then
    log 'releasing every loop device of the image'
    release_all_loops || err 'a loop device is still attached'
  fi
}

#######################################
# Start Layer 1: converge the Layer 0 transport, then start the launcher.
#######################################
start_l1() {
  local count=0 pid
  [ -f "${IMAGE_PATH}" ] || die "no image: ${IMAGE_PATH}, run: image create"
  # The lock covers the running check as well: two starts that both saw a
  # stopped Layer 1 would each mount the image and pick a supervisor.
  lock_start
  trap 'unlock_start' 0
  if l1_running; then
    trap - 0
    unlock_start
    log 'Layer 1 already runs'
    return 0
  fi
  release_stale_image
  mkdir -p "${ROOTFS_HOME}/state"
  printf 'up\n' >"${NETWORK_STATE}"
  if ! sh "${MODDIR}/scripts/host.sh" start; then
    die 'the host supervisor did not start'
  fi
  # A service that a manual `sv down` stopped stays down across a supervisor
  # restart, so this module puts its own services back up.
  for service in network dns; do
    "${BUSYBOX}" sv up "${ROOTFS_HOME}/host-service/${service}" \
      >/dev/null 2>&1
  done
  log 'converging the Layer 0 network'
  if ! sh "${MODDIR}/scripts/network.sh" converge; then
    sh "${MODDIR}/scripts/network.sh" down >/dev/null 2>&1
    die 'the Layer 0 network setup failed'
  fi
  log 'starting Layer 1'
  "${BUSYBOX}" setsid "${BUSYBOX}" sh "${MODDIR}/scripts/start.sh" \
    >>"${LOG_FILE}" 2>&1 </dev/null &
  while [ "${count}" -lt "${START_TIMEOUT}" ]; do
    if l1_running; then
      # A supervisor that dies right after it appears leaves the loop attached
      # and the next start would report a dead instance as running, so the
      # start only succeeds after the supervisor stays up for a moment.
      pid="$(l1_pid)"
      sleep "${START_SETTLE}"
      if ! l1_running || [ "$(l1_pid)" != "${pid}" ]; then
        log "Layer 1 (pid ${pid}) left right after it started"
        break
      fi
      trap - 0
      unlock_start
      log "Layer 1 started (pid ${pid})"
      return 0
    fi
    sleep 1
    count=$(( count + 1 ))
  done
  unlock_start
  release_stale_image
  sh "${MODDIR}/scripts/network.sh" down >/dev/null 2>&1
  err 'Layer 1 did not start, see: rootfs-service log'
  return 1
}

#######################################
# Ask PID 1 to stop the services, then stop PID 1.
# Arguments:
#   Host PID of PID 1.
#######################################
stop_pid1() {
  local pid="${1}" count=0
  log 'stopping the Layer 1 services'
  "${BUSYBOX}" nsenter -t "${pid}" -m -u -i -n -p -r -w -- \
    /sbin/openrc shutdown >/dev/null 2>&1
  kill -TERM "${pid}" 2>/dev/null
  while kill -0 "${pid}" 2>/dev/null; do
    if [ "${count}" -ge 10 ]; then
      break
    fi
    sleep 1
    count=$(( count + 1 ))
  done
  if kill -0 "${pid}" 2>/dev/null; then
    kill -KILL "${pid}" 2>/dev/null
  fi
}

#######################################
# Stop Layer 1: stop PID 1, release the image, and remove the Layer 0
# objects. The order keeps the image available while the namespace lives.
#######################################
stop_l1() {
  local count=0 ns='' pid
  lock_start
  trap 'unlock_start' 0
  pid="$(l1_pid)" || pid=''
  if [ -n "${pid}" ]; then
    ns="$(readlink "/proc/${pid}/ns/mnt" 2>/dev/null)"
    stop_pid1 "${pid}"
  fi
  # The supervisor is not an init process here, so its services outlive it.
  # The whole mount namespace is stopped, which releases the containerd lock
  # and the loop device.
  if [ -n "${ns}" ]; then
    log 'stopping the processes of the Layer 1 namespace'
    kill_namespace "${ns}"
  fi
  if ! release_all_loops; then
    err 'a loop device is still attached, a reboot clears it'
  fi
  rm -f "${RUN_DIR}/loop"
  printf 'down\n' >"${NETWORK_STATE}"
  sh "${MODDIR}/scripts/network.sh" down || err 'cannot remove every object'
  trap - 0
  unlock_start
  log 'Layer 1 stopped, the host supervisor keeps running'
}

#######################################
# Print the state of Layer 1, the image, and the Layer 0 objects.
# Globals:
#   MODDIR
#######################################
show_status() {
  local loop pid
  pid="$(l1_pid)" || pid=''
  if [ -n "${pid}" ]; then
    log "layer 1: running (pid ${pid})"
  else
    log 'layer 1: stopped'
  fi
  echo
  sh "${MODDIR}/scripts/image.sh" status
  if [ -z "${pid}" ]; then
    loop="$(image_loop_device)"
    if [ -n "${loop}" ]; then
      log "attention: the image is attached to ${loop}"
      log 'a pending loop device is released by a phone reboot only'
    fi
  fi
  echo
  sh "${MODDIR}/scripts/network.sh" status
  echo
  sh "${MODDIR}/scripts/host.sh" status
}

#######################################
# Print the last lines of the Layer 1 log.
# Globals:
#   LOG_FILE
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
# Require a running Layer 1 and print its host PID.
#######################################
require_pid1() {
  l1_pid || die 'Layer 1 is not running'
}

#######################################
# Run a command with the namespaces and the root of PID 1.
# Arguments:
#   Command and arguments.
#######################################
exec_l1() {
  local pid
  [ "$#" -gt 0 ] || die 'usage: rootfs-service exec <command> [args...]'
  pid="$(require_pid1)"
  exec "${BUSYBOX}" nsenter -t "${pid}" -m -u -i -n -p -r -w -- \
    /bin/busybox env -i "PATH=${L1_PATH}" HOME=/root TERM=xterm "$@"
}

#######################################
# Open a shell with the namespaces and the root of PID 1.
#######################################
shell_l1() {
  local pid
  pid="$(require_pid1)"
  exec "${BUSYBOX}" nsenter -t "${pid}" -m -u -i -n -p -r -w -- \
    /bin/busybox env -i "PATH=${L1_PATH}" HOME=/root TERM="${TERM:-xterm}" \
    /bin/sh -c 'cd "${HOME}"; exec /bin/sh'
}


#######################################
# Control Docker inside Layer 1 with its OpenRC service.
# Globals:
#   BUSYBOX
#   L1_PATH
#######################################
control_docker() {
  local action="${1:-status}" pid
  pid="$(require_pid1)"
  case "${action}" in
    log)
      exec "${BUSYBOX}" nsenter -t "${pid}" -m -u -i -n -p -r -w -- \
        /bin/busybox tail -n "${2:-40}" /var/log/docker.log
      ;;
    start | stop | restart | status)
      exec "${BUSYBOX}" nsenter -t "${pid}" -m -u -i -n -p -r -w -- \
        /bin/busybox env -i "PATH=${L1_PATH}" /sbin/rc-service docker \
        "${action}"
      ;;
    *)
      die 'usage: rootfs-service docker start|stop|restart|status|log [lines]'
      ;;
  esac
}

#######################################
# Print the command usage.
#######################################
usage() {
  cat >&2 <<'END'
usage: rootfs-service <command> [argument]

  start                 start Layer 1 and the host supervisor
  stop                  stop Layer 1 and the host supervisor
  restart               stop, then start
  status                print the state of Layer 1, the image, and the network
  health                run the health checks
  log [lines]           print the last log lines
  exec <command>        run a command inside Layer 1
  shell                 open a shell inside Layer 1
  host <command>        start, stop, or print the host supervisor
  image <command>       manage the image, see: image help
  docker <command>      start, stop, restart, print, or log Docker
END
}

#######################################
# Dispatch the command line arguments.
#######################################
main() {
  local action="${1:-}"
  [ -n "${action}" ] || {
    usage
    exit 1
  }
  shift
  case "${action}" in
    image)
      exec sh "${MODDIR}/scripts/image.sh" "$@"
      ;;
    start)
      require_busybox
      start_l1
      ;;
    stop)
      require_busybox
      stop_l1
      ;;
    restart)
      require_busybox
      stop_l1
      start_l1
      ;;
    status)
      require_busybox
      show_status
      ;;
    health)
      exec sh "${MODDIR}/scripts/health.sh"
      ;;
    log)
      show_log "${1:-}"
      ;;
    exec)
      exec_l1 "$@"
      ;;
    shell)
      shell_l1
      ;;
    host)
      exec sh "${MODDIR}/scripts/host.sh" "$@"
      ;;
    docker)
      control_docker "$@"
      ;;
    *)
      usage
      exit 1
      ;;
  esac
}

main "$@"
