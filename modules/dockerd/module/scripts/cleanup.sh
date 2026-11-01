#!/system/bin/sh
#
# Best-effort removal of everything the module created outside its directory.

DOCKERD_DIR=/data/adb/dockerd
IP_FORWARD_FILE=/data/adb/dockerd_ip_forward
BUSYBOX="${DOCKERD_DIR}/bin/busybox"
[ -x "${BUSYBOX}" ] || BUSYBOX=/data/adb/ksu/bin/busybox
SERVICE_DIR=/data/adb/rootfs/service/dockerd
readonly BUSYBOX DOCKERD_DIR IP_FORWARD_FILE SERVICE_DIR

[ -f "${DOCKERD_DIR}/settings.sh" ] && . "${DOCKERD_DIR}/settings.sh"
: "${BRIDGE:=docker0}"
: "${BRIDGE_SUBNET:=172.17.0.0/16}"

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
# Stop the daemon and wait for it to exit.
# Globals:
#   BUSYBOX
#   DOCKERD_DIR
#   SERVICE_DIR
#######################################
stop_daemon() {
  local i pid
  if [ -d "${SERVICE_DIR}" ]; then
    touch "${SERVICE_DIR}/down"
    "${BUSYBOX}" sv -w 15 down "${SERVICE_DIR}" >/dev/null 2>&1
    "${BUSYBOX}" sv -w 5 exit "${SERVICE_DIR}" >/dev/null 2>&1
    rm -rf "${SERVICE_DIR}"
  fi
  [ -f "${DOCKERD_DIR}/run/dockerd.pid" ] || return 0
  pid="$(cat "${DOCKERD_DIR}/run/dockerd.pid" 2>/dev/null)"
  if [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null && is_ours "${pid}"; then
    kill "${pid}" 2>/dev/null
    i=0
    while is_ours "${pid}" && [ "${i}" -lt 20 ]; do
      i=$(( i + 1 ))
      sleep 1
    done
    is_ours "${pid}" && kill -9 "${pid}" 2>/dev/null
  fi
}

#######################################
# Kill every process left in a Docker cgroup.
# Globals:
#   BUSYBOX
#######################################
kill_cgroup_procs() {
  local hierarchy file pid
  for hierarchy in /dev/cpuctl /dev/memcg /dev/blkio; do
    [ -d "${hierarchy}/docker" ] || continue
    "${BUSYBOX}" find "${hierarchy}/docker" -name cgroup.procs \
      2>/dev/null \
      | while read -r file; do
      while read -r pid; do
        kill -9 "${pid}" 2>/dev/null
      done <"${file}" 2>/dev/null
    done
  done
}

#######################################
# Kill the daemons, shims and helpers that belong to this module.
# Globals:
#   DOCKERD_DIR
#######################################
kill_daemons() {
  local name pid
  for name in dockerd containerd containerd-shim-runc-v2 docker-proxy runc \
    docker-init; do
    for pid in $(pidof "${name}" 2>/dev/null); do
      is_ours "${pid}" && kill -9 "${pid}" 2>/dev/null
    done
  done
}

#######################################
# Delete the Docker iptables chains and jump rules.
# Globals:
#   BRIDGE
#######################################
delete_iptables_rules() {
  local chain chains rule table
  for table in filter nat; do
    iptables -w -t "${table}" -S 2>/dev/null \
    | "${BUSYBOX}" awk '
          /^-A (FORWARD|INPUT|OUTPUT|PREROUTING|POSTROUTING) / &&
          /-j DOCKER/ { sub(/^-A /, ""); print }' \
      | while read -r rule; do
      iptables -w -t "${table}" -D ${rule} 2>/dev/null
    done
  done
  iptables -w -t nat -S POSTROUTING 2>/dev/null \
    | grep -E 'MASQUERADE' \
    | grep -E "docker0|br-|${BRIDGE}" \
    | sed 's/^-A //' \
    | while read -r rule; do
    iptables -w -t nat -D ${rule} 2>/dev/null
  done
  # Hairpin rules name no bridge: they map one container address onto itself.
  iptables -w -t nat -S POSTROUTING 2>/dev/null \
  | awk '
        {
          src = ""; dst = ""; masq = 0
          for (i = 1; i <= NF; i++) {
            if ($i == "-s") src = $(i + 1)
            if ($i == "-d") dst = $(i + 1)
            if ($i == "MASQUERADE") masq = 1
          }
          if (masq && src == dst && src ~ /\/32$/) {
            sub(/^-A /, "")
            print
          }
        }' \
    | while read -r rule; do
    iptables -w -t nat -D ${rule} 2>/dev/null
  done
  chains='DOCKER-USER DOCKER-FORWARD DOCKER-CT DOCKER-INTERNAL'
  chains="${chains} DOCKER-BRIDGE DOCKER DOCKER-ISOLATION-STAGE-1"
  chains="${chains} DOCKER-ISOLATION-STAGE-2 DOCKER-ISOLATION DOCKER-INGRESS"
  for chain in ${chains}; do
    for table in filter nat; do
      iptables -w -t "${table}" -F "${chain}" 2>/dev/null
    done
  done
  for chain in ${chains}; do
    for table in filter nat; do
      iptables -w -t "${table}" -X "${chain}" 2>/dev/null
    done
  done
}

#######################################
# Remove the netd registrations and the bridge links.
# Globals:
#   BRIDGE
#   BRIDGE_SUBNET
#   DOCKERD_DIR
#######################################
delete_netd_state() {
  local bridge bridges
  if [ -f "${DOCKERD_DIR}/run/upstream" ]; then
    ndc ipfwd remove "${BRIDGE}" \
      "$(cat "${DOCKERD_DIR}/run/upstream")" >/dev/null 2>&1
  fi
  ndc network route remove local "${BRIDGE}" "${BRIDGE_SUBNET}" >/dev/null 2>&1
  ndc network interface remove local "${BRIDGE}" >/dev/null 2>&1
  ndc ipfwd disable docker >/dev/null 2>&1
  bridges="$(
    ip -o link show 2>/dev/null \
      | sed -n 's/^[0-9]*: \(br-[0-9a-f]*\):.*/\1/p'
  )"
  for bridge in "${BRIDGE}" ${bridges}; do
    ip link del "${bridge}" 2>/dev/null
  done
}

#######################################
# Remove the cgroup directories from the Android hierarchies.
#######################################
delete_cgroups() {
  local cgroup hierarchy
  for hierarchy in /dev/cpuctl /dev/cpuset /dev/memcg /dev/blkio; do
    [ -d "${hierarchy}/docker" ] || continue
    for cgroup in "${hierarchy}"/docker/*; do
      [ -d "${cgroup}" ] && rmdir "${cgroup}" 2>/dev/null
    done
    rmdir "${hierarchy}/docker" 2>/dev/null
  done
}

#######################################
# Remove the hierarchies that only Docker mounted: devices, freezer, pids.
# Globals:
#   BUSYBOX
#   DOCKERD_DIR
#######################################
delete_cgroup_hierarchies() {
  local hierarchy
  for hierarchy in devices freezer pids; do
    "${BUSYBOX}" unshare -m --propagation private sh -c '
      mkdir -p "$2"
      mount -t cgroup -o "$1" "$1" "$2" 2>/dev/null || exit 0
      for cgroup in "$2"/docker/*; do
        [ -d "${cgroup}" ] && rmdir "${cgroup}" 2>/dev/null
      done
      rmdir "$2"/docker 2>/dev/null
      umount "$2"
    ' _ "${hierarchy}" "${DOCKERD_DIR}/run/cgtmp" 2>/dev/null
  done
}

#######################################
# Restore ip_forward. The saved value survives installs, not reboots.
# Globals:
#   IP_FORWARD_FILE
#######################################
restore_ip_forward() {
  [ -f "${IP_FORWARD_FILE}" ] || return 0
  cat "${IP_FORWARD_FILE}" >/proc/sys/net/ipv4/ip_forward 2>/dev/null
  rm -f "${IP_FORWARD_FILE}"
}

#######################################
# Remove the wrappers and the data directory.
# Globals:
#   DOCKERD_DIR
#######################################
delete_data() {
  rm -f /data/adb/ksu/bin/docker /data/adb/ksu/bin/dockerd-service
  rm -rf /data/adb/rootfs/service/dockerd
  rm -rf "${DOCKERD_DIR:?}"
}

#######################################
# Remove everything the module created outside its own directory.
#######################################
main() {
  stop_daemon
  kill_cgroup_procs
  kill_daemons
  delete_iptables_rules
  delete_netd_state
  delete_cgroups
  delete_cgroup_hierarchies
  restore_ip_forward
  delete_data
}

main "$@"
