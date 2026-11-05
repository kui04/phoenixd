#!/system/bin/sh
#
# Shared settings and helpers for the rootfs module. Source this file, do not
# run it.
#
# ROOTFS_HOME overrides the runtime directory. The default is the installed
# location. A spike sets it to a scratch directory, so that a running module
# stays untouched.

ROOTFS_HOME="${ROOTFS_HOME:-/data/adb/rootfs}"
readonly ROOTFS_HOME

# The boot environment has a minimal PATH, so set a known one. The platform
# comes first: BusyBox has a small `ip` applet without `netns`, and the module
# bin follows so that runsvdir can start runsv by name.
PATH="/system/bin:/system/xbin:${ROOTFS_HOME}/bin:/sbin:/bin"
export PATH
IMAGE_PATH="${ROOTFS_HOME}/alpine.img"
IMAGE_MNT="${ROOTFS_HOME}/mnt"
ROOT_MNT="${ROOTFS_HOME}/root"
LOOP_FILE="${RUN_DIR}/loop"
DOCKER_DATA="${DOCKER_DATA:-/data/adb/dockerd/data}"
DOCKER_META="${DOCKER_DATA}/containerd/daemon/io.containerd.metadata.v1.bolt/meta.db"
RUN_DIR="${ROOTFS_HOME}/run"
readonly DOCKER_DATA DOCKER_META IMAGE_MNT IMAGE_PATH LOOP_FILE ROOT_MNT \
  RUN_DIR

IMAGE_DEFAULT_MB=2048
IMAGE_MIN_MB=512
IMAGE_MAX_MB=65536
IMAGE_LABEL='phoenixd'
LOG_MAX_BYTES=8388608
L1_HOSTNAME='phoenixd'
L1_PATH='/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
NETNS='l1'
# Android's iproute2 keeps the named namespace as a mount on this file.
NETNS_FILE="/mnt/run/${NETNS}"
readonly IMAGE_DEFAULT_MB IMAGE_LABEL IMAGE_MAX_MB IMAGE_MIN_MB
readonly LOG_MAX_BYTES
readonly L1_HOSTNAME L1_PATH NETNS

# The netns, veth, and rule objects exist in Android's iproute2 only. BusyBox
# ships an ip applet without netns, so name the binary instead of trusting the
# search order of PATH.
IP='/system/bin/ip'
LOSETUP='/system/bin/losetup'
MKE2FS='/system/bin/mke2fs'
E2FSCK='/system/bin/e2fsck'
RESIZE2FS='/system/bin/resize2fs'
TUNE2FS='/system/bin/tune2fs'
CHROOT='/system/bin/chroot'
TAR='/system/bin/tar'
GZIP='/system/bin/gzip'
readonly CHROOT E2FSCK GZIP IP LOSETUP NETNS NETNS_FILE MKE2FS RESIZE2FS TAR TUNE2FS

#######################################
# Print a message to stdout.
# Arguments:
#   Message.
#######################################
log() {
  echo "$*"
}

#######################################
# Print a message to stderr.
# Arguments:
#   Message.
#######################################
err() {
  echo "$*" >&2
}

#######################################
# Print a message to stderr and exit with status 1.
# Arguments:
#   Message.
#######################################
die() {
  err "$*"
  exit 1
}

#######################################
# Print the path of the BusyBox binary that the module ships. Another
# BusyBox is not a substitute: it has a different applet set, and its output
# formats differ.
# Globals:
#   ROOTFS_HOME
# Returns:
#   0 and prints the path, 1 when the module BusyBox is missing.
#######################################
find_busybox() {
  local candidate="${ROOTFS_HOME}/bin/busybox"
  [ -x "${candidate}" ] || return 1
  echo "${candidate}"
}

BUSYBOX="$(find_busybox)" || BUSYBOX=''
readonly BUSYBOX

#######################################
# Exit unless the module BusyBox is available.
#######################################
require_busybox() {
  [ -n "${BUSYBOX}" ] || die 'busybox is missing, reinstall the module'
}

#######################################
# Print the free space of the filesystem that holds a directory, in MB.
# Arguments:
#   Directory on the target filesystem.
# Returns:
#   0 and prints the free space, 1 when df gives no answer.
#######################################
free_mb() {
  local avail_kb
  avail_kb="$(df -k "${1}" 2>/dev/null | awk 'NR == 2 { print $4 }')"
  [ -n "${avail_kb}" ] || return 1
  echo $(( avail_kb / 1024 ))
}

#######################################
# Print the image file size in MB. awk does the division, because the shell
# arithmetic of Android is 32-bit and an image exceeds 2 GB.
# Globals:
#   IMAGE_PATH
# Returns:
#   0 and prints the size, 1 when the image is missing.
#######################################
image_mb() {
  local bytes
  [ -f "${IMAGE_PATH}" ] || return 1
  bytes="$(wc -c <"${IMAGE_PATH}")" || return 1
  awk -v bytes="${bytes}" 'BEGIN { printf "%d\n", bytes / 1048576 }'
}

#######################################
# Print the allocated size of the image file in MB. A sparse file reports
# much less than its logical size.
# Globals:
#   IMAGE_PATH
# Returns:
#   0 and prints the size, 1 when the image is missing.
#######################################
image_allocated_mb() {
  local blocks
  [ -f "${IMAGE_PATH}" ] || return 1
  blocks="$(du -k "${IMAGE_PATH}" 2>/dev/null | awk 'NR == 1 { print $1 }')"
  [ -n "${blocks}" ] || return 1
  echo $(( blocks / 1024 ))
}

#######################################
# Exit unless a size in MB is a whole number inside the allowed range.
# Arguments:
#   Size in MB.
#######################################
validate_image_mb() {
  local size_mb="${1}"
  case "${size_mb}" in
    '' | *[!0-9]*)
      die "invalid size: '${size_mb}', give a whole number of MB"
      ;;
  esac
  if [ "${size_mb}" -lt "${IMAGE_MIN_MB}" ]; then
    die "the size must be at least ${IMAGE_MIN_MB} MB"
  fi
  if [ "${size_mb}" -gt "${IMAGE_MAX_MB}" ]; then
    die "the size must be at most ${IMAGE_MAX_MB} MB"
  fi
}

#######################################
# Exit unless the filesystem that holds the runtime directory has enough
# space. Keeping one more image free leaves room for a backup and for
# filesystem growth.
# Arguments:
#   Required free space in MB.
# Globals:
#   ROOTFS_HOME
#######################################
require_space() {
  local need_mb="${1}" avail_mb
  if ! avail_mb="$(free_mb "${ROOTFS_HOME}")"; then
    die "cannot read the free space of ${ROOTFS_HOME}"
  fi
  if [ "${avail_mb}" -lt "${need_mb}" ]; then
    die "not enough space: need ${need_mb} MB free, ${avail_mb} MB available"
  fi
}

#######################################
# Print the loop device that holds the image, when one exists. sysfs names
# the backing file of every loop device, so this works when losetup -a cannot
# open the Android nodes.
# Globals:
#   IMAGE_PATH
# Returns:
#   0 and prints the node, 1 when the image is not attached.
#######################################
image_loop_device() {
  local file name node
  for name in /sys/block/loop*/loop/backing_file; do
    [ -r "${name}" ] || continue
    file="$(cat "${name}" 2>/dev/null)"
    # A device that was attached before pivot_root records the path below the
    # old root, so the suffix is compared, not the whole string.
    case "${file}" in
      *"${IMAGE_PATH}") ;;
      *) continue ;;
    esac
    node="/dev/block/$(echo "${name}" | cut -d/ -f4)"
    [ -b "${node}" ] || continue
    echo "${node}"
    return 0
  done
  return 1
}

#######################################
# Print the loop node that this session recorded, when it still exists.
# Globals:
#   LOOP_FILE
#   LOSETUP
#######################################
recorded_loop() {
  local node
  node="$(cat "${LOOP_FILE}" 2>/dev/null)"
  [ -n "${node}" ] || return 1
  "${LOSETUP}" -a 2>/dev/null | grep -qF "${node}:" || return 1
  echo "${node}"
}

#######################################
# Print a loop node that already holds the image, from losetup or sysfs.
# Globals:
#   IMAGE_PATH
#   LOSETUP
#######################################
existing_loop() {
  local node
  node="$(image_loop_device)"
  if [ -n "${node}" ]; then
    echo "${node}"
    return 0
  fi
  node="$("${LOSETUP}" -a 2>/dev/null |
    grep -F "(${IMAGE_PATH})" |
    cut -d: -f1 |
    head -n 1)"
  [ -n "${node}" ] || return 1
  echo "${node}"
}

#######################################
# Attach the image to a free loop device. /dev/loop-control allocates a new
# device, which is the only reliable source on this device: after a boot
# Android holds every existing node, and losetup -a cannot enumerate them.
# Globals:
#   IMAGE_PATH
#   LOSETUP
# Returns:
#   0 and prints the node, 1 when the kernel refuses to allocate one.
#######################################
image_attach() {
  local node
  # Reuse the recorded node, then any attachment, then ask the kernel for a
  # new device. A device that a dead namespace still holds cannot be
  # detached, so a second attach would leak another one.
  node="$(recorded_loop)" && { echo "${node}"; return 0; }
  node="$(existing_loop)" && { echo "${node}"; return 0; }
  node="$("${LOSETUP}" -f 2>/dev/null)"
  if [ -n "${node}" ] && "${LOSETUP}" "${node}" "${IMAGE_PATH}" 2>/dev/null; then
    echo "${node}"
    return 0
  fi
  for node in /dev/block/loop*; do
    [ -b "${node}" ] || continue
    if "${LOSETUP}" "${node}" "${IMAGE_PATH}" 2>/dev/null; then
      echo "${node}"
      return 0
    fi
  done
  return 1
}

#######################################
# Mount the image read-write.
# Arguments:
#   Loop device node.
#   Mount point, IMAGE_MNT by default.
# Globals:
#   BUSYBOX
#   IMAGE_MNT
# Returns:
#   0 on success, 1 on failure.
#######################################
image_mount() {
  local node="${1}" target="${2:-${IMAGE_MNT}}"
  mkdir -p "${target}" || return 1
  "${BUSYBOX}" mount -t ext4 -o rw,noatime "${node}" "${target}"
}

#######################################
# Unmount the image and detach its loop device. Every step is best effort,
# because a cleanup path calls this after a partial failure.
# Arguments:
#   Loop device node.
# Globals:
#   BUSYBOX
#   IMAGE_MNT
#   LOSETUP
#######################################
image_release() {
  local node="${1}"
  "${BUSYBOX}" umount "${IMAGE_MNT}/apk-cache" 2>/dev/null
  "${BUSYBOX}" umount "${IMAGE_MNT}/proc" 2>/dev/null
  "${BUSYBOX}" umount "${IMAGE_MNT}" 2>/dev/null
  [ -n "${node}" ] && "${LOSETUP}" -d "${node}" 2>/dev/null
  rmdir "${IMAGE_MNT}" 2>/dev/null
  return 0
}

#######################################
# Print every process that lives in a mount namespace.
# Arguments:
#   Namespace identifier, as readlink prints it, for example mnt:[4026534000].
#######################################
namespace_pids() {
  local ns="${1}" pid
  for pid in /proc/[0-9]*; do
    [ "$(readlink "${pid}/ns/mnt" 2>/dev/null)" = "${ns}" ] || continue
    echo "${pid#/proc/}"
  done
}

#######################################
# Stop every process of a mount namespace. The namespace must be captured
# before its supervisor dies, because a dead process has no namespace link.
# Arguments:
#   Namespace identifier.
#######################################
kill_namespace() {
  local ns="${1}" count=0 pid pids=''
  [ -n "${ns}" ] || return 0
  for pid in $(namespace_pids "${ns}"); do
    kill -TERM "${pid}" 2>/dev/null
  done
  while [ "${count}" -lt 15 ]; do
    pids="$(namespace_pids "${ns}")"
    [ -n "${pids}" ] || return 0
    sleep 1
    count=$(( count + 1 ))
  done
  for pid in ${pids}; do
    kill -KILL "${pid}" 2>/dev/null
  done
  return 0
}

#######################################
# Exit unless no containerd holds the metadata lock. A containerd of an earlier
# Layer 1 keeps an exclusive flock on meta.db, and a second one then blocks in
# its bolt open until dockerd gives up.
# Globals:
#   BUSYBOX
#   DOCKER_META
#######################################
require_containerd_lock_free() {
  [ -e "${DOCKER_META}" ] || return 0
  if ! "${BUSYBOX}" flock -n "${DOCKER_META}" true 2>/dev/null; then
    die "a containerd of an earlier Layer 1 holds ${DOCKER_META}"
  fi
}

#######################################
# Detach every loop device of the image. A device that a live mount holds
# rejects the detach, so the loop is bounded and reports failure.
# Globals:
#   IMAGE_PATH
#   LOSETUP
# Returns:
#   0 when no device is left, 1 after the last attempt.
#######################################
release_all_loops() {
  local count=0 loop
  while [ "${count}" -lt 8 ]; do
    loop="$(image_loop_device)"
    [ -n "${loop}" ] || return 0
    "${LOSETUP}" -d "${loop}" 2>/dev/null
    count=$(( count + 1 ))
    sleep 1
  done
  return 1
}

#######################################
# Check whether a process holds the image.
# Globals:
#   IMAGE_MNT
# Returns:
#   0 when the image is attached or mounted, 1 otherwise.
#######################################
image_in_use() {
  if [ -n "$(image_loop_device)" ]; then
    return 0
  fi
  if grep -qF " ${IMAGE_MNT} " /proc/mounts 2>/dev/null; then
    return 0
  fi
  return 1
}

#######################################
# Print the host PID of the Layer 1 init process, when it is alive. A PID
# inside a child namespace is 1, so the host PID comes from the netns, and
# the command line identifies init among the processes that exec adds.
# Globals:
#   NETNS
# Returns:
#   0 and prints the PID, 1 when Layer 1 does not run.
#######################################
l1_pid() {
  local pid
  [ -f "${RUN_DIR}/l1.pid" ] || return 1
  pid="$(cat "${RUN_DIR}/l1.pid" 2>/dev/null)"
  [ -n "${pid}" ] || return 1
  kill -0 "${pid}" 2>/dev/null || return 1
  "${IP}" netns pids "${NETNS}" 2>/dev/null \
    | grep -qx "${pid}" || return 1
  echo "${pid}"
}

#######################################
# Check whether Layer 1 runs.
# Returns:
#   0 when it runs, 1 otherwise.
#######################################
l1_running() {
  l1_pid >/dev/null
}

#######################################
# Exit unless nothing uses the image.
# Globals:
#   IMAGE_MNT
#######################################
require_image_idle() {
  if l1_running; then
    die 'Layer 1 is running, run: rootfs-service stop'
  fi
  if image_in_use; then
    die 'the image is attached to a loop device, stop Layer 1 first'
  fi
}

#######################################
# Rotate a log file when it is larger than a limit. One older copy is kept,
# because the run directory and /var/log both live on the image.
# Arguments:
#   Log file path.
# Globals:
#   LOG_MAX_BYTES
#######################################
rotate_log() {
  local file="${1}" size
  [ -f "${file}" ] || return 0
  size="$(wc -c <"${file}" 2>/dev/null)" || return 0
  [ "${size}" -ge "${LOG_MAX_BYTES}" ] || return 0
  mv -f "${file}" "${file}.1" 2>/dev/null
}

#######################################
# Rotate every host log.
# Globals:
#   RUN_DIR
#######################################
rotate_host_logs() {
  local name
  for name in l1 network wifi dns singbox charge display host; do
    rotate_log "${RUN_DIR}/${name}.log"
  done
}

#######################################
# Check an ext4 filesystem file.
# Arguments:
#   Path of the filesystem image.
#   'force' runs a full check, any other value a quick check.
# Globals:
#   E2FSCK
# Returns:
#   0 when the filesystem is clean or was repaired, 1 otherwise.
#######################################
fsck_path() {
  local path="${1}" mode="${2:-quick}" output rc
  if [ "${mode}" = 'force' ]; then
    output="$("${E2FSCK}" -p -f "${path}" 2>&1)"
  else
    output="$("${E2FSCK}" -p "${path}" 2>&1)"
  fi
  rc=$?
  case "${rc}" in
    0) log 'filesystem clean' ;;
    1) log 'filesystem errors corrected' ;;
    2) log 'filesystem corrected, run fsck again' ;;
    *)
      err "${output}"
      err "e2fsck failed with exit status ${rc}"
      return 1
      ;;
  esac
  return 0
}

#######################################
# Check the image filesystem.
# Arguments:
#   'force' runs a full check, any other value a quick check.
# Globals:
#   IMAGE_PATH
# Returns:
#   0 when the filesystem is clean or was repaired, 1 otherwise.
#######################################
image_fsck() {
  fsck_path "${IMAGE_PATH}" "${1:-quick}"
}
