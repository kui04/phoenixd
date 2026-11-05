#!/system/bin/sh
#
# KernelSU installer script. Installs the static BusyBox binary, the image
# payload, and the wrappers. An existing image is kept. When no image
# exists, this script creates one from the payload, without a network.
# Sourced by the KernelSU installer, which provides MODPATH, ARCH, ui_print,
# abort, set_perm and set_perm_recursive.

SKIPUNZIP=0
export MODULE_HOT_INSTALL_REQUEST=true
export MODULE_HOT_RUN_SCRIPT='hotinstall.sh'

ROOTFS_HOME=/data/adb/rootfs
export ROOTFS_HOME
BIN_DIR="${ROOTFS_HOME}/bin"
DRIVER_DIR="${ROOTFS_HOME}/drivers"
KSU_BIN_DIR=/data/adb/ksu/bin
IMAGE_PATH="${ROOTFS_HOME}/alpine.img"

[ "${ARCH}" = 'arm64' ] || abort '! arm64 devices only'

ui_print '- Installing rootfs'

if [ -f /data/adb/modules/rootfs/scripts/control.sh ]; then
  ui_print '- Stopping the installed module'
  sh /data/adb/modules/rootfs/scripts/control.sh stop >/dev/null 2>&1 || true
fi

mkdir -p "${BIN_DIR}" "${ROOTFS_HOME}/run" "${ROOTFS_HOME}/mounts.d" \
  "${ROOTFS_HOME}/settings.d" "${ROOTFS_HOME}/state" \
  "${ROOTFS_HOME}/host-service" "${DRIVER_DIR}"

# The KernelSU installer does not keep the executable bit of the overlay, and
# the image copies its modes, so set the modes that the overlay needs.
chmod 755 "${MODPATH}/overlay/etc/init.d/net" \
  "${MODPATH}/overlay/etc/init.d/docker" \
  "${MODPATH}/overlay/sbin/reboot" \
  "${MODPATH}/overlay/sbin/poweroff" \
  "${MODPATH}/overlay/sbin/halt" 2>/dev/null

ui_print '- Installing binaries'
if ! cp -f "${MODPATH}/files/busybox" "${BIN_DIR}/busybox"; then
  abort '! Failed to install busybox'
fi
chmod 755 "${BIN_DIR}/busybox"
for name in sh runsv runsvdir sv; do
  ln -sf busybox "${BIN_DIR}/${name}"
done

if [ -f "${MODPATH}/files/dns-forwarder" ]; then
  if ! cp -f "${MODPATH}/files/dns-forwarder" "${BIN_DIR}/dns-forwarder"; then
    abort '! Failed to install the DNS forwarder'
  fi
  chmod 755 "${BIN_DIR}/dns-forwarder"
fi

if [ -d "${MODPATH}/files/drivers" ]; then
  ui_print '- Installing hardware acceleration drivers'
  if ! cp -af "${MODPATH}/files/drivers/." "${DRIVER_DIR}/"; then
    abort '! Failed to install the drivers'
  fi
fi

if [ ! -f "${IMAGE_PATH}" ]; then
  ui_print '- Creating the Alpine image, this takes about one minute'
  if ! sh "${MODPATH}/scripts/control.sh" image create; then
    abort '! Failed to create the image'
  fi
else
  ui_print '- Keeping the existing image'
fi

printf '1\n' >"${ROOTFS_HOME}/api_version"

if [ -d "${MODPATH}/host-service" ]; then
  if ! cp -af "${MODPATH}/host-service/." \
    "${ROOTFS_HOME}/host-service/"; then
    abort '! Failed to install the host services'
  fi
  find "${ROOTFS_HOME}/host-service" "${MODPATH}/host-service" \
    -type f -exec chmod 755 {} +
fi

if [ ! -f "${ROOTFS_HOME}/state/network" ]; then
  printf 'down\n' >"${ROOTFS_HOME}/state/network"
fi

mkdir -p /data/adb/dockerd/data

if [ ! -f "${ROOTFS_HOME}/mounts.d/20-docker.conf" ]; then
  cat >"${ROOTFS_HOME}/mounts.d/20-docker.conf" <<'END'
# Docker data is much larger than the image, so it stays on /data. The static
# binaries of the v1 bundle run the daemon; see /etc/conf.d/docker.
/data/adb/dockerd/data  /var/lib/docker  rw
/data/adb/dockerd/bin  /opt/phoenixd/docker-bin  ro
END
fi

if [ ! -f "${ROOTFS_HOME}/mounts.d/10-drivers.conf" ]; then
  cat >"${ROOTFS_HOME}/mounts.d/10-drivers.conf" <<'END'
# The GPU and codec payload. Docker compose uses this path.
/data/adb/rootfs/drivers  /opt/phoenixd/drivers  ro
END
fi

if [ -d "${KSU_BIN_DIR}" ]; then
  cp -f "${MODPATH}/scripts/rootfs-service.sh" \
    "${KSU_BIN_DIR}/rootfs-service"
  chmod 755 "${KSU_BIN_DIR}/rootfs-service"
  # v1 installed a rootfs-exec wrapper. v2 provides exec and shell through
  # rootfs-service, so the old wrapper must not stay behind.
  rm -f "${KSU_BIN_DIR}/rootfs-exec"
  cat >"${KSU_BIN_DIR}/docker" <<'END'
#!/system/bin/sh
# Docker client inside Layer 1.
exec /data/adb/ksu/bin/rootfs-service exec docker "$@"
END
  cat >"${KSU_BIN_DIR}/dockerd-service" <<'END'
#!/system/bin/sh
# Compatibility wrapper for the v1 control command.
exec /data/adb/ksu/bin/rootfs-service docker "$@"
END
  chmod 755 "${KSU_BIN_DIR}/docker" "${KSU_BIN_DIR}/dockerd-service"
fi

set_perm_recursive "${BIN_DIR}" 0 0 0755 0755
set_perm_recursive "${DRIVER_DIR}" 0 0 0755 0644
set_perm_recursive "${MODPATH}/scripts" 0 0 0755 0755
set_perm "${ROOTFS_HOME}/api_version" 0 0 0644
set_perm "${MODPATH}/service.sh" 0 0 0755
set_perm "${MODPATH}/action.sh" 0 0 0755
set_perm "${MODPATH}/uninstall.sh" 0 0 0755
set_perm "${MODPATH}/hotinstall.sh" 0 0 0755

ui_print '- Control: rootfs-service start|stop|restart|status|log'
ui_print '- Image: rootfs-service image create|fsck|resize|backup|restore'
