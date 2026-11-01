#!/system/bin/sh
#
# KernelSU installer script. Extracts the engine, installs the wrappers and
# the CLI plugins, and asks for a hot install.
# Sourced by the KernelSU installer, which provides MODPATH, ARCH, ui_print,
# abort, set_perm and set_perm_recursive.

SKIPUNZIP=0
export MODULE_HOT_INSTALL_REQUEST=true
export MODULE_HOT_RUN_SCRIPT='hotinstall.sh'

DOCKERD_DIR=/data/adb/dockerd
KSU_BIN_DIR=/data/adb/ksu/bin
CONFIG_DIR="${DOCKERD_DIR}/config"
CA_BUNDLE="${CONFIG_DIR}/ca-certificates.crt"

[ "${ARCH}" = 'arm64' ] || abort '! arm64 devices only'

ui_print '- Installing dockerd'

if [ -x "${DOCKERD_DIR}/bin/dockerd" ]; then
  ui_print '- Stopping running dockerd'
  sh "${MODPATH}/scripts/control.sh" stop >/dev/null 2>&1
fi

mkdir -p "${DOCKERD_DIR}/bin" "${DOCKERD_DIR}/run" "${DOCKERD_DIR}/data" \
  "${CONFIG_DIR}/cli-plugins"

ui_print '- Extracting docker binaries'
chmod 755 "${MODPATH}/files/busybox"
if ! "${MODPATH}/files/busybox" tar -xf "${MODPATH}/files/docker.tar.xz" \
  -C "${DOCKERD_DIR}"; then
  abort '! Failed to extract docker binaries'
fi
rm -f "${MODPATH}/files/docker.tar.xz"
if [ -f "${DOCKERD_DIR}/bin/docker" ]; then
  mv -f "${DOCKERD_DIR}/bin/docker" "${DOCKERD_DIR}/bin/docker-cli"
fi
cp -f "${MODPATH}/files/busybox" "${DOCKERD_DIR}/bin/busybox"
chmod 755 "${DOCKERD_DIR}/bin/busybox"
rm -f "${MODPATH}/files/busybox"

ui_print '- Installing cli plugins'
if ! cp -af "${MODPATH}/files/cli-plugins/." "${CONFIG_DIR}/cli-plugins/"; then
  ui_print '! Failed to install cli plugins'
fi
rm -rf "${MODPATH}/files/cli-plugins"

ui_print '- Installing helpers'
cp -f "${MODPATH}/scripts/docker-cli.sh" "${DOCKERD_DIR}/bin/docker"
cp -f "${MODPATH}/scripts/dockerd-service.sh" \
  "${DOCKERD_DIR}/bin/dockerd-service"

# Concatenate the system CA store, APEX first, for the CLI.
ca_tmp="${CA_BUNDLE}.tmp"
: >"${ca_tmp}"
for ca_dir in /apex/com.android.conscrypt/cacerts \
  /system/etc/security/cacerts; do
  [ -d "${ca_dir}" ] || continue
  cat "${ca_dir}"/*.[0-9]* >>"${ca_tmp}" 2>/dev/null
  [ -s "${ca_tmp}" ] && break
done
if [ -s "${ca_tmp}" ]; then
  mv -f "${ca_tmp}" "${CA_BUNDLE}"
else
  rm -f "${ca_tmp}"
fi
unset ca_tmp ca_dir

if [ ! -f "${DOCKERD_DIR}/settings.sh" ]; then
  cp -f "${MODPATH}/scripts/settings.sh" "${DOCKERD_DIR}/settings.sh"
fi
if [ ! -f "${DOCKERD_DIR}/daemon.json" ]; then
  cp -f "${MODPATH}/etc/daemon.json" "${DOCKERD_DIR}/daemon.json"
fi

if [ -d "${KSU_BIN_DIR}" ]; then
  cp -f "${DOCKERD_DIR}/bin/docker" "${KSU_BIN_DIR}/docker"
  cp -f "${DOCKERD_DIR}/bin/dockerd-service" \
    "${KSU_BIN_DIR}/dockerd-service"
  chmod 755 "${KSU_BIN_DIR}/docker" "${KSU_BIN_DIR}/dockerd-service"
fi

set_perm_recursive "${DOCKERD_DIR}/bin" 0 0 0755 0755
set_perm_recursive "${CONFIG_DIR}/cli-plugins" 0 0 0755 0755
if [ -f "${CA_BUNDLE}" ]; then
  set_perm "${CA_BUNDLE}" 0 0 0644
fi
set_perm "${DOCKERD_DIR}/settings.sh" 0 0 0644
set_perm "${DOCKERD_DIR}/daemon.json" 0 0 0644
set_perm_recursive "${MODPATH}/scripts" 0 0 0755 0755
set_perm "${MODPATH}/scripts/settings.sh" 0 0 0644
set_perm "${MODPATH}/service.sh" 0 0 0755
set_perm "${MODPATH}/boot-completed.sh" 0 0 0755
set_perm "${MODPATH}/action.sh" 0 0 0755
set_perm "${MODPATH}/uninstall.sh" 0 0 0755
set_perm "${MODPATH}/hotinstall.sh" 0 0 0755
rmdir "${MODPATH}/files" 2>/dev/null

ui_print '- Run: docker run --rm hello-world'
ui_print '- Control: dockerd-service start|stop|status|log'
ui_print "- Settings: ${DOCKERD_DIR}/settings.sh, ${DOCKERD_DIR}/daemon.json"
