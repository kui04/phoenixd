#!/system/bin/sh
#
# Removes the files that the rootfs module installs. The image and the bind
# declarations stay, so that a reinstall keeps its data.

MODDIR="$(cd "${0%/*}/.." && pwd)"
. "${MODDIR}/scripts/common.sh"
readonly MODDIR
KSU_BIN_DIR=/data/adb/ksu/bin
readonly KSU_BIN_DIR

#######################################
# Stop Layer 1 and detach the image. The detach is skipped when a process
# still holds the image, so that an uninstall cannot corrupt a live system.
# Globals:
#   MODDIR
#######################################
stop_layer1() {
  local loop
  sh "${MODDIR}/scripts/host.sh" stop >/dev/null 2>&1
  if l1_running; then
    sh "${MODDIR}/scripts/control.sh" stop >/dev/null 2>&1
  fi
  if l1_running; then
    echo 'Layer 1 still runs, the image stays attached'
    return 0
  fi
  loop="$(image_loop_device)"
  if [ -n "${loop}" ]; then
    image_release "${loop}"
  fi
}

#######################################
# Remove the wrappers that this module installs.
# Globals:
#   KSU_BIN_DIR
#######################################
remove_wrappers() {
  rm -f "${KSU_BIN_DIR}/rootfs-service" "${KSU_BIN_DIR}/rootfs-exec"
}

#######################################
# Remove only what this module owns: its two host services, its binaries, its
# run state, and the cache. The host-service directory itself stays, because
# the headless and singbox modules keep their services there.
# Globals:
#   IMAGE_PATH
#   ROOTFS_HOME
#######################################
remove_runtime_tree() {
  local entry
  for entry in bin drivers run state api_version; do
    rm -rf "${ROOTFS_HOME:?}/${entry:?}"
  done
  for entry in network dns; do
    rm -rf "${ROOTFS_HOME:?}/host-service/${entry:?}"
  done
  # A tree from an older build may still hold module payloads.
  for entry in lib share service settings.sh; do
    rm -rf "${ROOTFS_HOME:?}/${entry:?}"
  done
}

#######################################
# Print the paths that survive the uninstall.
# Globals:
#   IMAGE_PATH
#   ROOTFS_HOME
#######################################
print_kept() {
  echo 'kept:'
  echo "  ${IMAGE_PATH}"
  echo "  ${ROOTFS_HOME}/mounts.d"
}

#######################################
# Remove the module from the device.
#######################################
main() {
  stop_layer1
  remove_wrappers
  remove_runtime_tree
  print_kept
}

main "$@"
