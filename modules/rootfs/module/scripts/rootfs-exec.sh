#!/system/bin/sh
#
# Enters the Layer 1 pivot container mount namespace and root directory.
# Usage: rootfs-exec <cmd> [args...]

ROOTFS_DIR=/data/adb/rootfs
BUSYBOX="${ROOTFS_DIR}/bin/busybox"
[ -x "${BUSYBOX}" ] || BUSYBOX=/data/adb/ksu/bin/busybox
PID_FILE="${ROOTFS_DIR}/run/rootfs.pid"
SERVICE_DIR="${ROOTFS_DIR}/service"
readonly BUSYBOX PID_FILE ROOTFS_DIR SERVICE_DIR

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
# Verify that rootfs is running.
# Globals:
#   PID_FILE
# Returns:
#   0 if running, 1 otherwise.
#######################################
is_running() {
  local pid
  [ -f "${PID_FILE}" ] || return 1
  pid="$(cat "${PID_FILE}" 2>/dev/null)"
  [ -n "${pid}" ] || return 1
  kill -0 "${pid}" 2>/dev/null || return 1
  is_ours "${pid}"
}

#######################################
# Ensure rootfs is running, then exec into its mount namespace.
#######################################
main() {
  local pid
  if [ "$#" -eq 0 ]; then
    err "usage: $0 <command> [args...]"
    exit 1
  fi
  if ! is_running; then
    sh "/data/adb/modules/rootfs/scripts/control.sh" start >/dev/null 2>&1
  fi
  if ! is_running; then
    err 'rootfs container is not running'
    exit 1
  fi
  pid="$(cat "${PID_FILE}" 2>/dev/null)"
  exec "${BUSYBOX}" nsenter -t "${pid}" -m -r -w -F "$@"
}

main "$@"

