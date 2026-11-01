#!/system/bin/sh
#
# KernelSU installer script. Installs the static binaries, the helper and the
# default settings. It does not start anything: run headless-service start or
# reboot after you set the network in /data/adb/headless/wifi.conf.
# Sourced by the KernelSU installer, which provides MODPATH, ARCH, ui_print,
# abort, set_perm and set_perm_recursive.

SKIPUNZIP=0
export MODULE_HOT_INSTALL_REQUEST=true
export MODULE_HOT_RUN_SCRIPT='hotinstall.sh'

HEADLESS_DIR=/data/adb/headless
BIN_DIR="${HEADLESS_DIR}/bin"
KSU_BIN_DIR=/data/adb/ksu/bin

[ "${ARCH}" = 'arm64' ] || abort '! arm64 devices only'

ui_print '- Installing headless'

if [ -x "${BIN_DIR}/wpa_supplicant" ]; then
  ui_print '- Stopping running headless'
  sh "${MODPATH}/scripts/control.sh" stop >/dev/null 2>&1
fi

mkdir -p "${BIN_DIR}" "${HEADLESS_DIR}/run"

ui_print '- Installing binaries'
for name in busybox wpa_supplicant wpa_cli iw phx-statusd; do
  cp -f "${MODPATH}/files/${name}" "${BIN_DIR}/${name}" \
    || abort "! Failed to install ${name}"
  chmod 755 "${BIN_DIR}/${name}"
done
for name in runsv runsvdir sv; do
  ln -sf busybox "${BIN_DIR}/${name}"
done
rm -rf "${MODPATH}/files"

if [ ! -f "${HEADLESS_DIR}/settings.sh" ]; then
  cp -f "${MODPATH}/scripts/settings.sh" "${HEADLESS_DIR}/settings.sh"
else
  if ! grep -q 'vendor\.hwcomposer' "${HEADLESS_DIR}/settings.sh"; then
    ui_print '- Migrating settings.sh for hwcomposer service'
    sed -i 's/mediametrics/mediametrics vendor.hwcomposer-2-4/' \
      "${HEADLESS_DIR}/settings.sh" 2>/dev/null || true
  fi
  if ! grep -q 'DISPLAY_ENABLED' "${HEADLESS_DIR}/settings.sh"; then
    ui_print '- Migrating settings.sh for display support'
    printf '\n' >>"${HEADLESS_DIR}/settings.sh"
    cat <<'EOF' >>"${HEADLESS_DIR}/settings.sh"
DISPLAY_ENABLED='1'
DISPLAY_TIMEOUT='30'
DISPLAY_BRIGHTNESS='1024'
EOF
  fi
fi
if [ ! -f "${HEADLESS_DIR}/wifi.conf" ]; then
  cp -f "${MODPATH}/etc/wifi.conf" "${HEADLESS_DIR}/wifi.conf"
fi

if [ -d "${KSU_BIN_DIR}" ]; then
  cp -f "${MODPATH}/scripts/headless-service.sh" \
    "${KSU_BIN_DIR}/headless-service"
  chmod 755 "${KSU_BIN_DIR}/headless-service"
fi

set_perm_recursive "${BIN_DIR}" 0 0 0755 0755
set_perm "${HEADLESS_DIR}/settings.sh" 0 0 0644
set_perm "${HEADLESS_DIR}/wifi.conf" 0 0 0600
set_perm_recursive "${MODPATH}/scripts" 0 0 0755 0755
set_perm "${MODPATH}/scripts/settings.sh" 0 0 0644
set_perm "${MODPATH}/boot-completed.sh" 0 0 0755
set_perm "${MODPATH}/action.sh" 0 0 0755
set_perm "${MODPATH}/uninstall.sh" 0 0 0755
set_perm "${MODPATH}/hotinstall.sh" 0 0 0755

ui_print "- Set your network in ${HEADLESS_DIR}/wifi.conf"
ui_print '- Control: headless-service start|stop|status|log'
ui_print '- Start stops the Android UI. Keep USB adb connected at first.'
