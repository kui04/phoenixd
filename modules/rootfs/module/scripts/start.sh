#!/system/bin/sh
#
# Runs the Layer 1 pivot root container and the runsvdir supervisor.
# Called by control.sh under: busybox unshare -m --propagation private

ROOTFS_DIR=/data/adb/rootfs
ROOT_DIR="${ROOTFS_DIR}/root"
RUN_DIR="${ROOTFS_DIR}/run"
SERVICE_DIR="${ROOTFS_DIR}/service"
HOST_BUSYBOX="${ROOTFS_DIR}/bin/busybox"
readonly HOST_BUSYBOX ROOTFS_DIR ROOT_DIR RUN_DIR SERVICE_DIR

[ -f "${ROOTFS_DIR}/settings.sh" ] && . "${ROOTFS_DIR}/settings.sh"
: "${DNS1:=1.1.1.1}"
: "${DNS2:=223.5.5.5}"

#######################################
# Print a message to stderr.
# Arguments:
#   Message.
#######################################
log() {
  echo "$*" >&2
}

#######################################
# Run busybox mount.
# Arguments:
#   Mount arguments.
#######################################
bb_mount() {
  "${HOST_BUSYBOX}" mount "$@"
}

#######################################
# Refuse to touch the host mount namespace.
#######################################
check_namespace() {
  local init_ns self_ns
  self_ns="$(readlink /proc/self/ns/mnt)"
  init_ns="$(readlink /proc/1/ns/mnt)"
  if [ "${self_ns}" = "${init_ns}" ]; then
    log 'start.sh must run in a private mount namespace'
    exit 1
  fi
}

#######################################
# Exit when rootfs is already alive.
# Globals:
#   RUN_DIR
#   SERVICE_DIR
#######################################
check_running() {
  local cmdline pid
  [ -f "${RUN_DIR}/rootfs.pid" ] || return 0
  pid="$(cat "${RUN_DIR}/rootfs.pid" 2>/dev/null)"
  [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null || return 0
  cmdline="$(tr '\0' ' ' <"/proc/${pid}/cmdline" 2>/dev/null)"
  case "${cmdline}" in
    *"runsvdir"*"${SERVICE_DIR}"* | *"runsvdir"*"/service"*)
      exit 0
      ;;
  esac
}

#######################################
# Build the pivoted root and bind the host directories.
# Globals:
#   HOST_BUSYBOX
#   ROOTFS_DIR
#   ROOT_DIR
#   RUN_DIR
#   SERVICE_DIR
#######################################
setup_root() {
  local subdir
  mkdir -p "${ROOT_DIR}" "${RUN_DIR}" "${SERVICE_DIR}"
  bb_mount -t tmpfs -o mode=0755,size=64m tmpfs "${ROOT_DIR}" || exit 1
  for subdir in bin etc/ssl/certs run service tmp proc dev sys/fs/cgroup \
    var/lib/docker data storage sdcard system apex vendor linkerconfig; do
    mkdir -p "${ROOT_DIR}/${subdir}"
  done

  bb_mount -o bind "${ROOTFS_DIR}/bin" "${ROOT_DIR}/bin"
  if [ -d "${ROOTFS_DIR}/lib" ]; then
    mkdir -p "${ROOT_DIR}/lib"
    bb_mount -o bind "${ROOTFS_DIR}/lib" "${ROOT_DIR}/lib"
  fi
  if [ -d "${ROOTFS_DIR}/share/vulkan" ]; then
    mkdir -p "${ROOT_DIR}/usr/share/vulkan"
    bb_mount -o bind "${ROOTFS_DIR}/share/vulkan" \
      "${ROOT_DIR}/usr/share/vulkan"
  fi
  bb_mount -o bind "${RUN_DIR}" "${ROOT_DIR}/run"
  bb_mount -o bind "${SERVICE_DIR}" "${ROOT_DIR}/service"
  bb_mount -t tmpfs -o size=64m tmpfs "${ROOT_DIR}/tmp"
  bb_mount -o bind /proc "${ROOT_DIR}/proc"
  bb_mount -o bind /dev "${ROOT_DIR}/dev"
  bb_mount -o rbind /sys "${ROOT_DIR}/sys"
  for subdir in data storage sdcard system apex vendor linkerconfig; do
    if [ -d "/${subdir}" ]; then
      bb_mount -o rbind "/${subdir}" "${ROOT_DIR}/${subdir}"
    fi
  done
}

#######################################
# Allow unprivileged access to GPU, video codec and allocator nodes.
#######################################
setup_device_permissions() {
  local node
  for node in /dev/kgsl-3d0 /dev/ion /dev/video* /dev/dri/*; do
    [ -e "${node}" ] && chmod 0666 "${node}" 2>/dev/null || true
  done
}

#######################################
# Mount cgroup v1. cpuset is left out because Android mounts it with noprefix.
# Globals:
#   HOST_BUSYBOX
#   ROOT_DIR
#######################################
setup_cgroups() {
  local name source spec
  bb_mount -t tmpfs cgroup "${ROOT_DIR}/sys/fs/cgroup"
  for spec in cpu:/dev/cpuctl memory:/dev/memcg blkio:/dev/blkio; do
    name="${spec%%:*}"
    source="${spec#*:}"
    mkdir -p "${ROOT_DIR}/sys/fs/cgroup/${name}"
    bb_mount -o bind "${source}" "${ROOT_DIR}/sys/fs/cgroup/${name}" \
      || log "bind ${name} failed"
  done
  for name in devices freezer pids; do
    mkdir -p "${ROOT_DIR}/sys/fs/cgroup/${name}"
    bb_mount -t cgroup -o "${name}" "${name}" \
      "${ROOT_DIR}/sys/fs/cgroup/${name}" || log "mount ${name} failed"
  done
}

#######################################
# Concatenate the system CA store into the pivoted root.
# Globals:
#   ROOT_DIR
#######################################
write_ca_bundle() {
  local bundle ca_dir
  bundle="${ROOT_DIR}/etc/ssl/certs/ca-certificates.crt"
  : >"${bundle}"
  for ca_dir in /apex/com.android.conscrypt/cacerts \
    /system/etc/security/cacerts; do
    [ -d "${ca_dir}" ] || continue
    cat "${ca_dir}"/*.[0-9]* >>"${bundle}" 2>/dev/null
    [ -s "${bundle}" ] && break
  done
  [ -s "${bundle}" ] || rm -f "${bundle}"
}

#######################################
# Write resolv.conf, hosts, passwd and group files.
# Globals:
#   DNS1
#   DNS2
#   ROOT_DIR
#######################################
write_root_files() {
  {
    echo "nameserver ${DNS1}"
    [ -n "${DNS2}" ] && echo "nameserver ${DNS2}"
  } >"${ROOT_DIR}/etc/resolv.conf"
  printf '127.0.0.1 localhost\n' >"${ROOT_DIR}/etc/hosts"
  printf 'root:x:0:0:root:/root:/bin/sh\n' >"${ROOT_DIR}/etc/passwd"
  printf 'root:x:0:\n' >"${ROOT_DIR}/etc/group"
  write_ca_bundle
}

#######################################
# Build the root and execute runsvdir.
# Globals:
#   HOST_BUSYBOX
#   ROOT_DIR
#   RUN_DIR
#######################################
main() {
  mkdir -p "${RUN_DIR}"
  if [ ! -x "${HOST_BUSYBOX}" ]; then
    log 'busybox is missing, reinstall the module'
    exit 1
  fi
  check_namespace
  check_running
  setup_device_permissions
  setup_root
  setup_cgroups
  write_root_files

  mkdir -p "${ROOT_DIR}/.oldroot"
  if ! "${HOST_BUSYBOX}" pivot_root "${ROOT_DIR}" "${ROOT_DIR}/.oldroot"; then
    log 'pivot_root failed'
    exit 1
  fi
  cd / || exit 1
  /bin/busybox umount -l /.oldroot 2>/dev/null
  /bin/busybox rmdir /.oldroot 2>/dev/null

  printf '%s' "$$" >/run/rootfs.pid

  exec /bin/busybox env -i \
    PATH=/bin:/system/bin:/usr/bin:/sbin \
    HOME=/root \
    /bin/busybox runsvdir -P /service
}

main "$@"

