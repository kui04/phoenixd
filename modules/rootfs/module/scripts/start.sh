#!/system/bin/sh
#
# Starts Layer 1. Android keeps the host network namespace; Layer 1 joins the
# named netns "l1" and then creates its own mount, PID, IPC, and UTS
# namespaces. control.sh runs this script detached and redirected to the log.
#
# Layer 1 shares the PID namespace of Android: containerd 2.x cannot start
# inside a child PID namespace on kernel 4.14, because its pidfd probe waits
# forever there. OpenRC runs the runlevels, so no init process is needed.

MODDIR="$(cd "${0%/*}/.." && pwd)"
readonly MODDIR
. "${MODDIR}/scripts/common.sh"

#######################################
# Exit unless the Layer 0 transport exists. The network agent owns it.
#######################################
require_netns() {
  if ! "${IP}" netns list 2>/dev/null | awk '{ print $1 }' | grep -qx "${NETNS}"; then
    die "no netns ${NETNS}, run: rootfs-service start"
  fi
}

#######################################
# Join the netns, create the other namespaces, and hand over to launch.sh.
#######################################
main() {
  require_busybox
  [ -f "${IMAGE_PATH}" ] || die "no image: ${IMAGE_PATH}"
  require_netns
  cd / || die 'cannot enter /'
  exec "${IP}" netns exec "${NETNS}" "${BUSYBOX}" unshare -m -u -i \
    "${BUSYBOX}" sh "${MODDIR}/scripts/launch.sh"
}

main "$@"
