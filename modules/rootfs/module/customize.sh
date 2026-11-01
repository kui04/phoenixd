#!/system/bin/sh
#
# KernelSU installer script. Installs the static BusyBox binary, creates the
# runtime directories, installs the wrappers and default settings, and asks for
# a hot install.
# Sourced by the KernelSU installer, which provides MODPATH, ARCH, ui_print,
# abort, set_perm and set_perm_recursive.

SKIPUNZIP=0
export MODULE_HOT_INSTALL_REQUEST=true
export MODULE_HOT_RUN_SCRIPT='hotinstall.sh'

ROOTFS_DIR=/data/adb/rootfs
BIN_DIR="${ROOTFS_DIR}/bin"
KSU_BIN_DIR=/data/adb/ksu/bin

[ "${ARCH}" = 'arm64' ] || abort '! arm64 devices only'

ui_print '- Installing rootfs'

if [ -x "${BIN_DIR}/busybox" ]; then
  ui_print '- Stopping running rootfs'
  sh "${MODPATH}/scripts/control.sh" stop >/dev/null 2>&1
fi

mkdir -p "${BIN_DIR}" "${ROOTFS_DIR}/run" "${ROOTFS_DIR}/service"

ui_print '- Installing binaries'
cp -f "${MODPATH}/files/busybox" "${BIN_DIR}/busybox" \
  || abort '! Failed to install busybox'
chmod 755 "${BIN_DIR}/busybox"

for name in sh runsv runsvdir sv nsenter; do
  ln -sf busybox "${BIN_DIR}/${name}"
done
rm -rf "${MODPATH}/files"

if [ ! -f "${ROOTFS_DIR}/settings.sh" ]; then
  cp -f "${MODPATH}/scripts/settings.sh" "${ROOTFS_DIR}/settings.sh"
fi

if [ -d "${KSU_BIN_DIR}" ]; then
  cp -f "${MODPATH}/scripts/rootfs-service.sh" \
    "${KSU_BIN_DIR}/rootfs-service"
  cp -f "${MODPATH}/scripts/rootfs-exec.sh" \
    "${KSU_BIN_DIR}/rootfs-exec"
  chmod 755 "${KSU_BIN_DIR}/rootfs-service" "${KSU_BIN_DIR}/rootfs-exec"
fi

set_perm_recursive "${BIN_DIR}" 0 0 0755 0755
set_perm "${ROOTFS_DIR}/settings.sh" 0 0 0644
set_perm_recursive "${MODPATH}/scripts" 0 0 0755 0755
set_perm "${MODPATH}/scripts/settings.sh" 0 0 0644
set_perm "${MODPATH}/service.sh" 0 0 0755
set_perm "${MODPATH}/action.sh" 0 0 0755
set_perm "${MODPATH}/uninstall.sh" 0 0 0755
set_perm "${MODPATH}/hotinstall.sh" 0 0 0755

ui_print '- Control: rootfs-service start|stop|restart|status|log'
ui_print '- Execute in container: rootfs-exec <cmd> [args...]'

