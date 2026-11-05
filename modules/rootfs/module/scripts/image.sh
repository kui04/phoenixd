#!/system/bin/sh
#
# Image lifecycle: create, fsck, resize, backup, restore, status, update.
# The image holds the Layer 1 root filesystem.

MODDIR="$(cd "${0%/*}/.." && pwd)"
readonly MODDIR
. "${MODDIR}/scripts/common.sh"

#######################################
# Create a new image and build the root filesystem in it.
# Arguments:
#   Size in MB, 2048 by default.
# Globals:
#   IMAGE_PATH
#######################################
create_image() {
  local size_mb="${1:-${IMAGE_DEFAULT_MB}}"
  validate_image_mb "${size_mb}"
  if [ -e "${IMAGE_PATH}" ]; then
    die "the image exists: ${IMAGE_PATH}, remove it first"
  fi
  mkdir -p "${ROOTFS_HOME}" || die "cannot create ${ROOTFS_HOME}"
  require_space $(( size_mb * 2 ))
  log "creating ${IMAGE_PATH}, ${size_mb} MB sparse"
  truncate -s "${size_mb}M" "${IMAGE_PATH}" || die 'truncate failed'
  if ! "${MKE2FS}" -q -t ext4 -F -m 1 -L "${IMAGE_LABEL}" "${IMAGE_PATH}"; then
    rm -f "${IMAGE_PATH}"
    die 'mke2fs failed'
  fi
  if ! sh "${MODDIR}/scripts/build-image.sh" create; then
    rm -f "${IMAGE_PATH}"
    die 'the image build failed, the partial image is removed'
  fi
  image_fsck || exit 1
  log 'image created'
}

#######################################
# Check the image filesystem and print the result.
# Globals:
#   IMAGE_PATH
#######################################
check_image() {
  [ -f "${IMAGE_PATH}" ] || die "no image: ${IMAGE_PATH}"
  require_image_idle
  image_fsck "${1:-quick}" || exit 1
}

#######################################
# Grow the image and its filesystem. Shrinking needs a new build, so it is
# refused here.
# Arguments:
#   New size in MB.
# Globals:
#   IMAGE_PATH
#   RESIZE2FS
#######################################
resize_image() {
  local size_mb="${1:-}" old_mb
  [ -n "${size_mb}" ] || die 'usage: image resize MB'
  validate_image_mb "${size_mb}"
  [ -f "${IMAGE_PATH}" ] || die "no image: ${IMAGE_PATH}"
  require_image_idle
  old_mb="$(image_mb)" || die 'cannot read the image size'
  if [ "${size_mb}" -le "${old_mb}" ]; then
    die "shrinking is not supported, the image is ${old_mb} MB"
  fi
  require_space $(( size_mb * 2 - old_mb ))
  log "growing ${IMAGE_PATH} from ${old_mb} to ${size_mb} MB"
  truncate -s "${size_mb}M" "${IMAGE_PATH}" || die 'truncate failed'
  image_fsck force || exit 1
  "${RESIZE2FS}" "${IMAGE_PATH}" || die 'resize2fs failed'
  image_fsck || exit 1
  log 'image resized'
}

#######################################
# Write the image to a gzip stream.
# Arguments:
#   Absolute path of the backup file.
# Globals:
#   GZIP
#   IMAGE_PATH
#######################################
backup_image() {
  local target="${1:-}"
  [ -n "${target}" ] || die 'usage: image backup PATH'
  case "${target}" in
    /*) ;;
    *) die 'the backup path must be absolute' ;;
  esac
  [ -f "${IMAGE_PATH}" ] || die "no image: ${IMAGE_PATH}"
  require_image_idle
  if [ -e "${target}" ]; then
    die "the target exists: ${target}"
  fi
  log "writing ${target}"
  if ! "${GZIP}" -1 -c <"${IMAGE_PATH}" >"${target}"; then
    rm -f "${target}"
    die 'gzip failed, the partial backup is removed'
  fi
  log "backup written: $(du -h "${target}" | awk 'NR == 1 { print $1 }')"
}

#######################################
# Replace the image with a gzip stream. The new image is checked before it
# replaces the old one, so a bad backup leaves the old image in place.
# Arguments:
#   Absolute path of the backup file.
# Globals:
#   GZIP
#   IMAGE_PATH
#######################################
restore_image() {
  local source="${1:-}" staging
  [ -n "${source}" ] || die 'usage: image restore PATH'
  [ -f "${source}" ] || die "no backup: ${source}"
  require_image_idle
  staging="${IMAGE_PATH}.restore"
  log "reading ${source}"
  if ! "${GZIP}" -dc <"${source}" >"${staging}"; then
    rm -f "${staging}"
    die 'gzip failed, the image is unchanged'
  fi
  if ! fsck_path "${staging}"; then
    rm -f "${staging}"
    die 'the backup holds no clean filesystem, the image is unchanged'
  fi
  mv -f "${staging}" "${IMAGE_PATH}" || die 'cannot replace the image'
  log 'image restored'
}

#######################################
# Print one field of the image superblock.
# Arguments:
#   Field name, for example 'Block count'.
# Globals:
#   IMAGE_PATH
#   TUNE2FS
# Returns:
#   0 and prints the value, 1 when the field is absent.
#######################################
superblock_field() {
  local value
  value="$("${TUNE2FS}" -l "${IMAGE_PATH}" 2>/dev/null |
    sed -n "s/^${1}: *//p")"
  [ -n "${value}" ] || return 1
  echo "${value}"
}

#######################################
# Print the image state and the filesystem usage.
# Globals:
#   IMAGE_PATH
#   ROOTFS_HOME
#   TUNE2FS
#######################################
show_status() {
  local avail blocks block_size free_blocks per_mb state used_mb total_mb
  avail="$(free_mb "${ROOTFS_HOME}")" || avail='unknown'
  log "image: ${IMAGE_PATH}"
  if [ ! -f "${IMAGE_PATH}" ]; then
    log 'state: missing'
    log "free on /data: ${avail} MB"
    return 1
  fi
  log "size: $(image_mb) MB, allocated: $(image_allocated_mb) MB"
  if image_in_use; then
    log 'state: in use'
    log "free on /data: ${avail} MB"
    return 0
  fi
  if ! "${TUNE2FS}" -l "${IMAGE_PATH}" >/dev/null 2>&1; then
    err 'cannot read the filesystem superblock'
    return 1
  fi
  state="$(superblock_field 'Filesystem state')" || state='unknown'
  log "filesystem: ${state}"
  blocks="$(superblock_field 'Block count')" || return 1
  free_blocks="$(superblock_field 'Free blocks')" || return 1
  block_size="$(superblock_field 'Block size')" || return 1
  # Divide before multiplying: the shell arithmetic of Android is 32-bit,
  # and blocks * block_size overflows it.
  per_mb=$(( 1048576 / block_size ))
  total_mb=$(( blocks / per_mb ))
  used_mb=$(( (blocks - free_blocks) / per_mb ))
  log "capacity: ${total_mb} MB, used: ${used_mb} MB"
  log "free on /data: ${avail} MB"
}

#######################################
# Upgrade the packages in the image from the module payload and apply the
# overlay again. apk keeps a modified /etc file and writes a .apk-new file
# next to it, so the overlay comes last.
# Globals:
#   IMAGE_PATH
#######################################
update_image() {
  [ -f "${IMAGE_PATH}" ] || die "no image: ${IMAGE_PATH}"
  require_image_idle
  sh "${MODDIR}/scripts/build-image.sh" update || exit 1
  image_fsck || exit 1
  log 'image updated'
}

#######################################
# Print the command usage.
#######################################
usage() {
  cat >&2 <<'END'
usage: rootfs-service image <command> [argument]

  create [MB]    create the image, 2048 MB by default
  fsck           check the filesystem
  resize MB      grow the image and its filesystem
  backup PATH    write the image to a gzip stream
  restore PATH   replace the image from a gzip stream
  status         print the image state
  update         upgrade the packages in the image
END
}

#######################################
# Dispatch the command line arguments.
#######################################
main() {
  local action="${1:-}"
  require_busybox
  [ -n "${action}" ] || {
    usage
    exit 1
  }
  shift
  case "${action}" in
    create) create_image "${1:-}" ;;
    fsck) check_image "${1:-}" ;;
    resize) resize_image "${1:-}" ;;
    backup) backup_image "${1:-}" ;;
    restore) restore_image "${1:-}" ;;
    status) show_status ;;
    update) update_image ;;
    help | -h | --help) usage ;;
    *)
      usage
      exit 1
      ;;
  esac
}

main "$@"
