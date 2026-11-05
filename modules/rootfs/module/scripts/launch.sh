#!/system/bin/sh
#
# Runs inside the new mount, UTS, and IPC namespaces. It checks the image,
# mounts it, stages /dev, mounts /proc, /sys, the cgroup view, /run, and
# /tmp, applies the declared binds, and then execs the supervisor. It must not
# return: the supervisor owns the namespace.

MODDIR="$(cd "${0%/*}/.." && pwd)"
readonly MODDIR
. "${MODDIR}/scripts/common.sh"

# Device nodes that the launcher copies from Android. ION is used instead of
# dma_heap on this kernel, and video and drm depend on the firmware.
DEV_NODES='null zero full random urandom tty console ptmx tun kmsg fuse kgsl-3d0 ion'
DEV_GLOBS='/dev/video* /dev/dri/*'
DEV_SIZE='16m'
readonly DEV_GLOBS DEV_NODES DEV_SIZE

LOOP_NODE=''
HOST_PID=''

#######################################
# Mount the image read-write on the new root.
# Globals:
#   IMAGE_PATH
#   ROOT_MNT
#######################################
mount_image() {
  if ! LOOP_NODE="$(image_attach)"; then
    die 'no free loop device, or losetup failed'
  fi
  mkdir -p "${ROOT_MNT}" || die "cannot create ${ROOT_MNT}"
  if ! image_mount "${LOOP_NODE}" "${ROOT_MNT}"; then
    die 'cannot mount the image'
  fi
  printf '%s\n' "${LOOP_NODE}" >"${RUN_DIR}/loop" 2>/dev/null
}

#######################################
# Check the image before the mount and print the recovery command on failure.
# Globals:
#   IMAGE_PATH
#######################################
check_image() {
  if ! image_fsck; then
    die 'the image needs a manual check, run: rootfs-service image fsck'
  fi
}

#######################################
# Stage /dev as a tmpfs with the nodes that Layer 1 needs. /data is mounted
# nodev, and a bind mount keeps that flag, so a device node on the image
# cannot be opened. A tmpfs keeps the nodes usable.
# Globals:
#   BUSYBOX
#   DEV_GLOBS
#   DEV_NODES
#   DEV_SIZE
#   ROOT_MNT
#######################################
stage_dev() {
  local node
  if ! "${BUSYBOX}" mount -t tmpfs -o "mode=0755,dev,suid,size=${DEV_SIZE}" \
    tmpfs "${ROOT_MNT}/dev"; then
    die 'cannot mount /dev'
  fi
  for node in ${DEV_NODES}; do
    cp -a "/dev/${node}" "${ROOT_MNT}/dev/" 2>/dev/null
  done
  for node in ${DEV_GLOBS}; do
    [ -e "${node}" ] || continue
    cp -a "${node}" "${ROOT_MNT}/dev/" 2>/dev/null
  done
  mkdir -p "${ROOT_MNT}/dev/pts" "${ROOT_MNT}/dev/shm" \
    "${ROOT_MNT}/dev/mqueue"
  if ! "${BUSYBOX}" mount -t devpts -o newinstance,mode=0620 devpts \
    "${ROOT_MNT}/dev/pts"; then
    die 'cannot mount devpts'
  fi
  if ! "${BUSYBOX}" mount -t tmpfs -o mode=1777,dev,suid tmpfs \
    "${ROOT_MNT}/dev/shm"; then
    die 'cannot mount /dev/shm'
  fi
  # runc mounts every cgroup subsystem that the daemon sees, and it takes the
  # source of each hierarchy from the matching /dev path. All of them are
  # bound, not only the three that are mounted under /sys/fs/cgroup, because
  # a container start fails when one source is missing (cpuset, stune).
  for node in cpuset stune cpuctl memcg blkio; do
    [ -d "/dev/${node}" ] || continue
    mkdir -p "${ROOT_MNT}/dev/${node}"
    "${BUSYBOX}" mount --bind "/dev/${node}" "${ROOT_MNT}/dev/${node}" \
      2>/dev/null || err "cannot bind /dev/${node}"
  done
  if ! "${BUSYBOX}" mount -t mqueue mqueue "${ROOT_MNT}/dev/mqueue" \
    2>/dev/null; then
    err 'cannot mount /dev/mqueue'
  fi
  ln -sf /proc/self/fd "${ROOT_MNT}/dev/fd"
  ln -sf /proc/self/fd/0 "${ROOT_MNT}/dev/stdin"
  ln -sf /proc/self/fd/1 "${ROOT_MNT}/dev/stdout"
  ln -sf /proc/self/fd/2 "${ROOT_MNT}/dev/stderr"
}

#######################################
# Mount a fresh procfs. The PID namespace must exist first, which is why the
# procfs is mounted here and not by the host.
# Globals:
#   BUSYBOX
#   ROOT_MNT
#######################################
mount_proc() {
  if ! "${BUSYBOX}" mount -t proc proc "${ROOT_MNT}/proc"; then
    die 'cannot mount /proc'
  fi
}

#######################################
# Mount a fresh sysfs. A bind of the Android sysfs would show the host
# devices and the host cgroup tree.
# Globals:
#   BUSYBOX
#   ROOT_MNT
#######################################
mount_sys() {
  if ! "${BUSYBOX}" mount -t sysfs sysfs "${ROOT_MNT}/sys"; then
    die 'cannot mount /sys'
  fi
}

#######################################
# Mount the cgroup v1 view: three binds of the hierarchies that Android
# already mounted, and three fresh hierarchies. cpuset is left out because
# Android mounts it with noprefix.
# Globals:
#   BUSYBOX
#   ROOT_MNT
#######################################
mount_cgroups() {
  local name source spec
  "${BUSYBOX}" mount -t tmpfs -o mode=0755 cgroup \
    "${ROOT_MNT}/sys/fs/cgroup" || die 'cannot mount the cgroup tree'
  for spec in cpu:/dev/cpuctl memory:/dev/memcg blkio:/dev/blkio; do
    name="${spec%%:*}"
    source="${spec#*:}"
    mkdir -p "${ROOT_MNT}/sys/fs/cgroup/${name}"
    "${BUSYBOX}" mount -o bind "${source}" \
      "${ROOT_MNT}/sys/fs/cgroup/${name}" || err "cannot bind ${name}"
  done
  for name in devices freezer pids; do
    mkdir -p "${ROOT_MNT}/sys/fs/cgroup/${name}"
    "${BUSYBOX}" mount -t cgroup -o "${name}" "${name}" \
      "${ROOT_MNT}/sys/fs/cgroup/${name}" || err "cannot mount ${name}"
  done
}

#######################################
# Mount /run and /tmp as tmpfs, and make /var/run and /var/lock real
# directories on top of it. supervise-daemon and OpenRC write their pid files
# through /var/run; a symlink there resolves through a stale mount root in
# this namespace and fails with ENOENT, so the directories are bind mounted.
# Globals:
#   BUSYBOX
#   ROOT_MNT
#######################################
mount_runtime() {
  local name target
  "${BUSYBOX}" mount -t tmpfs -o mode=0755,nodev,nosuid tmpfs \
    "${ROOT_MNT}/run" || die 'cannot mount /run'
  "${BUSYBOX}" mount -t tmpfs -o mode=1777,nodev,nosuid tmpfs \
    "${ROOT_MNT}/tmp" || die 'cannot mount /tmp'
  for name in run lock; do
    target="${name}"
    [ "${name}" = 'lock' ] && target='run/lock'
    mkdir -p "${ROOT_MNT}/${target}" "${ROOT_MNT}/var"
    rm -rf "${ROOT_MNT:?}/var/${name:?}"
    mkdir -p "${ROOT_MNT}/var/${name}"
    "${BUSYBOX}" mount --bind "${ROOT_MNT}/${target}" \
      "${ROOT_MNT}/var/${name}" || die "cannot bind /var/${name}"
  done
}

#######################################
# Check one mount declaration line and bind it.
# Arguments:
#   Source path, destination path, mode, and bind kind.
# Globals:
#   BUSYBOX
#   ROOT_MNT
#######################################
apply_mount() {
  local src="${1}" dst="${2}" mode="${3}" kind="${4}" opt
  case "${src}${dst}" in
    *..*)
      err "relative path in mounts.d: ${src} ${dst}"
      return 1
      ;;
  esac
  case "${src}" in
    /*) ;;
    *)
      err "not an absolute source: ${src}"
      return 1
      ;;
  esac
  case "${dst}" in
    /*) ;;
    *)
      err "not an absolute destination: ${dst}"
      return 1
      ;;
  esac
  case "${mode}" in
    rw | ro) ;;
    *)
      err "unknown mode in mounts.d: ${mode}"
      return 1
      ;;
  esac
  if [ ! -e "${src}" ]; then
    err "missing mount source: ${src}"
    return 1
  fi
  opt='bind'
  if [ "${kind}" = 'recursive' ]; then
    opt='rbind'
  fi
  mkdir -p "${ROOT_MNT}${dst}" || return 1
  if ! "${BUSYBOX}" mount -o "${opt}" "${src}" "${ROOT_MNT}${dst}"; then
    err "cannot bind ${src} to ${dst}"
    return 1
  fi
  if [ "${mode}" = 'ro' ]; then
    if ! "${BUSYBOX}" mount -o remount,ro,bind "${ROOT_MNT}${dst}"; then
      err "cannot make ${dst} read-only"
    fi
  fi
}

#######################################
# Apply every declaration in mounts.d. This file is the only source of /data
# paths inside Layer 1.
# Globals:
#   ROOTFS_HOME
#######################################
apply_mounts() {
  local dst file kind mode src
  for file in "${ROOTFS_HOME}/mounts.d"/*.conf; do
    [ -f "${file}" ] || continue
    while read -r src dst mode kind; do
      case "${src}" in
        '' | '#'*) continue ;;
      esac
      apply_mount "${src}" "${dst}" "${mode}" "${kind}"
    done <"${file}"
  done
}

#######################################
# Switch to the image as the one root and drop the path to Android.
#
# The image is bind mounted onto itself so that pivot_root can put the old
# root on the same mount point (pivot_root(2), "pivot_root(".", ".")"). A
# lazy umount then detaches the whole Android tree at once; the older form,
# which put the old root on a subdirectory, left every Android mount visible
# there.
# Globals:
#   BUSYBOX
#   ROOT_MNT
#######################################
pivot() {
  cd "${ROOT_MNT}" || die 'cannot enter the image root'
  printf '%s\n' "${HOST_PID}" >"${RUN_DIR}/l1.pid" 2>/dev/null
  if ! "${BUSYBOX}" mount --bind . .; then
    die 'cannot bind the image root'
  fi
  if ! "${BUSYBOX}" pivot_root . .; then
    die 'pivot_root failed'
  fi
  "${BUSYBOX}" umount -l . 2>/dev/null
  cd / || die 'cannot enter the new root'
  return 0
}

#######################################
# Start BusyBox init as PID 1 with a clean environment. A leaked TMPDIR that
# points at an Android path breaks docker run, so the environment is empty.
# Globals:
#   L1_PATH
#######################################
exec_init() {
  exec /bin/busybox env -i \
    "PATH=${L1_PATH}" \
    HOME=/root \
    TMPDIR=/tmp \
    TERM=xterm \
    /bin/sh /sbin/l1-supervisor
}

#######################################
# Prepare the root and hand over to init.
#######################################
main() {
  require_busybox
  HOST_PID="$$"
  [ -d "/proc/${HOST_PID}" ] || die 'cannot read the PID'
  [ -f "${IMAGE_PATH}" ] || die "no image: ${IMAGE_PATH}"
  "${BUSYBOX}" mount --make-rprivate / || die 'cannot make / private'
  check_image
  mount_image
  "${BUSYBOX}" hostname "${L1_HOSTNAME}" || err 'cannot set the hostname'
  # An earlier boot left this mount point behind; the new pivot does not use it.
  rm -rf "${ROOT_MNT}/.oldroot" 2>/dev/null
  # supervise-daemon and OpenRC write through /var/run and /var/lock. The
  # minirootfs has no such links, and a directory left on the image would not
  # point at the /run tmpfs.
  for link in run lock; do
    if [ ! -e "${ROOT_MNT}/var/${link}" ]; then
      mkdir -p "${ROOT_MNT}/var"
      ln -s "../${link}" "${ROOT_MNT}/var/${link}"
    fi
  done
  mkdir -p "${ROOT_MNT}/proc" "${ROOT_MNT}/sys/fs/cgroup" "${ROOT_MNT}/run" \
    "${ROOT_MNT}/tmp" "${ROOT_MNT}/dev" || die 'cannot create the mount points'
  stage_dev
  mount_proc
  mount_sys
  mount_cgroups
  mount_runtime
  apply_mounts
  pivot
  exec_init
}

main "$@"
