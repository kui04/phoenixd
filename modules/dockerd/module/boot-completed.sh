#!/system/bin/sh
#
# Re-registers the Docker bridge with netd once boot has completed.

MODDIR="${0%/*}"
readonly MODDIR
DOCKERD_DIR=/data/adb/dockerd
BUSYBOX="${DOCKERD_DIR}/bin/busybox"
[ -x "${BUSYBOX}" ] || BUSYBOX=/data/adb/ksu/bin/busybox
[ -x "${BUSYBOX}" ] || exit 1
LOG_FILE="${DOCKERD_DIR}/run/dockerd.log"
readonly BUSYBOX DOCKERD_DIR LOG_FILE

"${BUSYBOX}" setsid sh "${MODDIR}/scripts/net.sh" \
  >>"${LOG_FILE}" 2>&1 </dev/null &
