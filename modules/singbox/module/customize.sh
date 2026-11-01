#!/system/bin/sh
#
# KernelSU installer script. Installs the sing-box binary, keeps the existing
# config unless there is none, and asks for a hot install.
# Sourced by the KernelSU installer, which provides MODPATH, ARCH, ui_print,
# abort, set_perm and set_perm_recursive.

SKIPUNZIP=0
export MODULE_HOT_INSTALL_REQUEST=true
export MODULE_HOT_RUN_SCRIPT='hotinstall.sh'

SINGBOX_DIR=/data/adb/singbox
KSU_BIN_DIR=/data/adb/ksu/bin

[ "${ARCH}" = 'arm64' ] || abort '! arm64 devices only'

ui_print '- Installing singbox'

if [ -x "${SINGBOX_DIR}/bin/sing-box" ]; then
  ui_print '- Stopping running sing-box'
  sh "${MODPATH}/scripts/control.sh" stop >/dev/null 2>&1
fi

mkdir -p "${SINGBOX_DIR}/bin" "${SINGBOX_DIR}/run"
cp -f "${MODPATH}/files/sing-box" "${SINGBOX_DIR}/bin/sing-box"
chmod 755 "${SINGBOX_DIR}/bin/sing-box"
rm -rf "${MODPATH}/files"

if [ ! -f "${SINGBOX_DIR}/config.json" ]; then
  cp -f "${MODPATH}/etc/config.json" "${SINGBOX_DIR}/config.json"
fi

if [ -d "${KSU_BIN_DIR}" ]; then
  cp -f "${MODPATH}/scripts/singbox-service.sh" \
    "${KSU_BIN_DIR}/singbox-service"
  set_perm "${KSU_BIN_DIR}/singbox-service" 0 0 0755
fi

set_perm_recursive "${SINGBOX_DIR}/bin" 0 0 0755 0755
set_perm "${SINGBOX_DIR}/config.json" 0 0 0600
set_perm_recursive "${MODPATH}/scripts" 0 0 0755 0755
set_perm "${MODPATH}/service.sh" 0 0 0755
set_perm "${MODPATH}/action.sh" 0 0 0755
set_perm "${MODPATH}/uninstall.sh" 0 0 0755
set_perm "${MODPATH}/hotinstall.sh" 0 0 0755
rmdir "${MODPATH}/files" 2>/dev/null

ui_print "- Config: ${SINGBOX_DIR}/config.json"
ui_print '- Control: singbox-service start|stop|restart|status|log|check'
