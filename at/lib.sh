#!/system/bin/sh
#
# Shared helpers for the acceptance cases. Every case runs on the device as
# root and prints one line per assertion. Exit 0 is PASS, 77 is SKIP, and any
# other status is FAIL.

BB=/data/adb/rootfs/bin/busybox
ROOTFS_HOME=/data/adb/rootfs

#######################################
# Print the current assertion and stop the case on failure.
# Arguments:
#   Description and the command result.
#######################################
assert() {
  local what="${1}"
  shift
  if "$@"; then
    echo "ok   ${what}"
  else
    echo "FAIL ${what}"
    exit 1
  fi
}

#######################################
# Print a value that the runner records.
# Arguments:
#   Label and value.
#######################################
show() {
  echo "     ${1}: ${2}"
}

#######################################
# Skip the case with a reason.
# Arguments:
#   Reason.
#######################################
skip() {
  echo "SKIP ${*}"
  exit 77
}

#######################################
# Run a command inside Layer 1.
# Arguments:
#   Command and arguments.
#######################################
in_l1() {
  "${BB}" nsenter -t "$(l1_pid)" -m -u -i -n -p -r -w -- \
    /bin/busybox env -i \
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    HOME=/root "$@"
}

#######################################
# Print the host PID of the Layer 1 init process.
#######################################
l1_pid() {
  local pid
  [ -f "${ROOTFS_HOME}/run/l1.pid" ] || return 1
  pid="$(cat "${ROOTFS_HOME}/run/l1.pid" 2>/dev/null)"
  [ -n "${pid}" ] || return 1
  kill -0 "${pid}" 2>/dev/null || return 1
  ip netns pids l1 2>/dev/null | grep -qx "${pid}" || return 1
  echo "${pid}"
}

#######################################
# Check that a path exists inside Layer 1.
# Arguments:
#   Path.
#######################################
l1_has() {
  in_l1 test -e "${1}"
}

#######################################
# Check that a path does not exist inside Layer 1.
# Arguments:
#   Path.
#######################################
l1_lacks() {
  ! in_l1 test -e "${1}"
}

#######################################
# Run a shell snippet inside Layer 1 and report its status.
# Arguments:
#   Snippet.
#######################################
l1_runs() {
  in_l1 sh -c "${1}" >/dev/null 2>&1
}

#######################################
# Check that a shell snippet fails inside Layer 1.
# Arguments:
#   Snippet.
#######################################
l1_fails() {
  ! l1_runs "${1}"
}

#######################################
# Check that Layer 1 runs, or skip the case.
#######################################
require_l1() {
  l1_pid >/dev/null || skip 'Layer 1 is not running'
}

#######################################
# Check that a host service runs, or skip the case.
# Arguments:
#   Service name.
#######################################
require_service() {
  "${BB}" sv status "${ROOTFS_HOME}/host-service/${1}" 2>/dev/null |
    grep -q '^run:' || skip "the ${1} service is not running"
}
