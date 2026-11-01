#!/system/bin/sh
#
# Best-effort removal of everything the rootfs module created.

MODDIR="$(cd "${0%/*}/.." && pwd)"
readonly MODDIR
ROOTFS_DIR=/data/adb/rootfs
BUSYBOX="${ROOTFS_DIR}/bin/busybox"
[ -x "${BUSYBOX}" ] || BUSYBOX=/data/adb/ksu/bin/busybox
readonly BUSYBOX ROOTFS_DIR

#######################################
# Stop the supervisor and container.
# Globals:
#   MODDIR
#######################################
stop_supervisor() {
  sh "${MODDIR}/scripts/control.sh" stop >/dev/null 2>&1
}

#######################################
# Remove the hierarchies that rootfs mounted: devices, freezer, pids.
# Globals:
#   BUSYBOX
#   ROOTFS_DIR
#######################################
delete_cgroup_hierarchies() {
  local hierarchy
  for hierarchy in devices freezer pids; do
    "${BUSYBOX}" unshare -m --propagation private sh -c '
      mkdir -p "$2"
      mount -t cgroup -o "$1" "$1" "$2" 2>/dev/null || exit 0
      for cgroup in "$2"/*; do
        [ -d "${cgroup}" ] && rmdir "${cgroup}" 2>/dev/null
      done
      umount "$2"
    ' _ "${hierarchy}" "${ROOTFS_DIR}/run/cgtmp" 2>/dev/null
  done
}

#######################################
# Remove the wrappers and the data directory.
# Globals:
#   ROOTFS_DIR
#######################################
delete_data() {
  rm -f /data/adb/ksu/bin/rootfs-service /data/adb/ksu/bin/rootfs-exec
  rm -rf "${ROOTFS_DIR:?}"
}

#######################################
# Execute full cleanup.
#######################################
main() {
  stop_supervisor
  delete_cgroup_hierarchies
  delete_data
}

main "$@"

