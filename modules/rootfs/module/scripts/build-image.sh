#!/system/bin/sh
#
# Builds or updates the Layer 1 root filesystem inside the ext4 image.
# Usage: build-image.sh create|update
#
# apk runs in a chroot and needs /proc inside it: musl emulates
# fchmodat(AT_SYMLINK_NOFOLLOW) through /proc/self/fd, so the setuid bits of
# packages such as mount do not apply without it.

MODDIR="$(cd "${0%/*}/.." && pwd)"
readonly MODDIR
. "${MODDIR}/scripts/common.sh"

PAYLOAD_DIR="${MODDIR}/files"
APK_CACHE="${PAYLOAD_DIR}/apk-cache"
OVERLAY="${MODDIR}/overlay"
readonly APK_CACHE OVERLAY PAYLOAD_DIR

LOOP_NODE=''

#######################################
# Print the minirootfs archive that the module ships.
# Globals:
#   PAYLOAD_DIR
# Returns:
#   0 and prints the path, 1 when it is missing or ambiguous.
#######################################
minirootfs_archive() {
  local archive='' candidate
  for candidate in "${PAYLOAD_DIR}"/alpine-minirootfs-*.tar.gz; do
    [ -f "${candidate}" ] || continue
    [ -z "${archive}" ] || return 1
    archive="${candidate}"
  done
  [ -n "${archive}" ] || return 1
  echo "${archive}"
}

#######################################
# Mount /proc and the package cache inside the image, so that the chroot can
# install the packages.
# Globals:
#   APK_CACHE
#   BUSYBOX
#   IMAGE_MNT
# Returns:
#   0 on success, 1 on failure.
#######################################
mount_chroot_fs() {
  mkdir -p "${IMAGE_MNT}/proc" "${IMAGE_MNT}/apk-cache" || return 1
  "${BUSYBOX}" mount -t proc proc "${IMAGE_MNT}/proc" || return 1
  "${BUSYBOX}" mount -o bind "${APK_CACHE}" "${IMAGE_MNT}/apk-cache"
}

#######################################
# Unmount /proc and the package cache. Both steps are best effort, because a
# failure path calls this twice.
# Globals:
#   BUSYBOX
#   IMAGE_MNT
#######################################
unmount_chroot_fs() {
  "${BUSYBOX}" umount "${IMAGE_MNT}/apk-cache" 2>/dev/null
  "${BUSYBOX}" umount "${IMAGE_MNT}/proc" 2>/dev/null
  rmdir "${IMAGE_MNT}/apk-cache" 2>/dev/null
  return 0
}

#######################################
# Extract the Alpine minirootfs into the image. tar runs as root, so the
# ownership of /etc/shadow and the ownership of the other files are kept.
# Globals:
#   IMAGE_MNT
#   TAR
#######################################
unpack_rootfs() {
  local archive
  if ! archive="$(minirootfs_archive)"; then
    die 'the minirootfs archive is missing or ambiguous'
  fi
  log "unpacking $(basename "${archive}")"
  if ! "${TAR}" -xzf "${archive}" -C "${IMAGE_MNT}"; then
    die 'cannot unpack the minirootfs'
  fi
}

#######################################
# Install the cached packages into the image.
# Globals:
#   APK_CACHE
#   CHROOT
#   IMAGE_MNT
#######################################
install_packages() {
  local count
  count="$(find "${APK_CACHE}" -maxdepth 1 -name '*.apk' | wc -l)"
  [ "${count}" -gt 0 ] || die 'the apk cache is empty'
  mount_chroot_fs || die 'cannot prepare the chroot'
  log "installing ${count} cached packages"
  "${CHROOT}" "${IMAGE_MNT}" /bin/busybox sh -c '
    PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
    export PATH
    apk add --no-network --allow-untrusted /apk-cache/*.apk
  ' || die 'apk add failed'
  unmount_chroot_fs
}

#######################################
# Add one service to one runlevel.
# Arguments:
#   Service name and runlevel name.
# Globals:
#   CHROOT
#   IMAGE_MNT
#   L1_PATH
#######################################
add_runlevel() {
  "${CHROOT}" "${IMAGE_MNT}" /bin/busybox env -i "PATH=${L1_PATH}" \
    /sbin/rc-update add "${1}" "${2}"
}

#######################################
# Add the OpenRC runlevel entries with rc-update, so that the image does not
# depend on how a zip tool restores a symlink.
# Globals:
#   IMAGE_MNT
#######################################
setup_runlevels() {
  local entry level service
  mount_chroot_fs || die 'cannot prepare the chroot'
  log 'adding the runlevel entries'
  for entry in loopback:boot net:boot local:default docker:default; do
    service="${entry%%:*}"
    level="${entry#*:}"
    if ! add_runlevel "${service}" "${level}"; then
      unmount_chroot_fs
      die "cannot add ${service} to ${level}"
    fi
  done
  unmount_chroot_fs
}

#######################################
# Copy the module overlay into the image. Every destination is removed first:
# cp follows a symlink destination and would overwrite the file it points at,
# and the image holds /sbin/reboot as a symlink to BusyBox.
# Globals:
#   BUSYBOX
#   IMAGE_MNT
#   OVERLAY
#######################################
apply_overlay() {
  local path
  [ -d "${OVERLAY}" ] || die "the overlay directory is missing: ${OVERLAY}"
  log 'applying the overlay'
  for path in $("${BUSYBOX}" find "${OVERLAY}" -mindepth 1 ! -type d); do
    rm -rf "${IMAGE_MNT:?}/${path#"${OVERLAY}"}"
  done
  if ! "${BUSYBOX}" cp -a "${OVERLAY}/." "${IMAGE_MNT}/"; then
    die 'cannot apply the overlay'
  fi
  # The KernelSU installer drops the executable bit, and the image copies the
  # modes of the module, so restore it for the scripts that OpenRC runs.
  for path in "${IMAGE_MNT}/etc/init.d/"*; do
    [ -f "${path}" ] && chmod 755 "${path}"
  done
  for path in reboot poweroff halt; do
    [ -f "${IMAGE_MNT}/sbin/${path}" ] && chmod 755 "${IMAGE_MNT}/sbin/${path}"
  done
}

#######################################
# Compare every overlay file and symlink with its copy in the image.
# Globals:
#   BUSYBOX
#   IMAGE_MNT
#   OVERLAY
# Returns:
#   0 when everything matches, 1 otherwise after printing the first
#   mismatch.
#######################################
verify_overlay() {
  local path target expected actual
  for path in $("${BUSYBOX}" find "${OVERLAY}" -type f); do
    target="${IMAGE_MNT}/${path#"${OVERLAY}"}"
    if ! "${BUSYBOX}" cmp -s "${path}" "${target}"; then
      err "overlay mismatch: ${path#"${OVERLAY}"}"
      return 1
    fi
  done
  for path in $("${BUSYBOX}" find "${OVERLAY}" -type l); do
    target="${IMAGE_MNT}/${path#"${OVERLAY}"}"
    expected="$("${BUSYBOX}" readlink "${path}")"
    actual="$("${BUSYBOX}" readlink "${target}")"
    if [ "${expected}" != "${actual}" ]; then
      err "overlay link mismatch: ${path#"${OVERLAY}"}"
      return 1
    fi
  done
  log 'overlay verified'
}

#######################################
# Attach, mount, build, and release the image. The EXIT trap releases every
# resource, including on a failure path.
#######################################
main() {
  local mode="${1:-}"
  require_busybox
  case "${mode}" in
    create | update) ;;
    *)
      err "usage: $0 create|update"
      exit 1
      ;;
  esac
  [ -f "${IMAGE_PATH}" ] || die "no image: ${IMAGE_PATH}"
  trap 'image_release "${LOOP_NODE}"' EXIT
  if ! LOOP_NODE="$(image_attach)"; then
    die 'no free loop device, or losetup failed'
  fi
  if ! image_mount "${LOOP_NODE}"; then
    die 'cannot mount the image'
  fi
  if [ "${mode}" = 'create' ]; then
    unpack_rootfs
  fi
  install_packages
  apply_overlay
  setup_runlevels
  verify_overlay || exit 1
  log 'root filesystem ready'
}

main "$@"
