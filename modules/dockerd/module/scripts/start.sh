#!/system/bin/sh
#
# Runs dockerd inside the Layer 1 pivot container.
# Invoked by runsv from /service/dockerd/run.

MODDIR="$(cd "${0%/*}/.." && pwd)"
readonly MODDIR
DOCKERD_DIR=/data/adb/dockerd
IP_FORWARD_FILE=/data/adb/dockerd_ip_forward
RUN_DIR="${DOCKERD_DIR}/run"
DATA_DIR="${DOCKERD_DIR}/data"
HOST_BUSYBOX="${DOCKERD_DIR}/bin/busybox"
[ -x "${HOST_BUSYBOX}" ] || HOST_BUSYBOX=/bin/busybox
readonly DATA_DIR DOCKERD_DIR HOST_BUSYBOX IP_FORWARD_FILE RUN_DIR

[ -f "${DOCKERD_DIR}/settings.sh" ] && . "${DOCKERD_DIR}/settings.sh"
: "${STORAGE_DRIVER:=overlay2}"
: "${BRIDGE:=docker0}"
: "${BRIDGE_SUBNET:=172.17.0.0/16}"
: "${PROXY:=}"

#######################################
# Print a message to stderr.
# Arguments:
#   Message.
#######################################
log() {
  echo "$*" >&2
}

#######################################
# Refuse to run outside the Layer 1 container.
#######################################
check_namespace() {
  local init_ns self_ns
  self_ns="$(readlink /proc/self/ns/mnt)"
  init_ns="$(readlink /proc/1/ns/mnt)"
  if [ "${self_ns}" = "${init_ns}" ]; then
    log 'dockerd must run inside the rootfs container'
    exit 1
  fi
}

#######################################
# Exit when a daemon of this module is already alive.
# Globals:
#   DOCKERD_DIR
#   RUN_DIR
#######################################
check_running() {
  local exe pid
  [ -f "${RUN_DIR}/dockerd.pid" ] || return 0
  pid="$(cat "${RUN_DIR}/dockerd.pid" 2>/dev/null)"
  [ -n "${pid}" ] && kill -0 "${pid}" 2>/dev/null || return 0
  exe="$(readlink "/proc/${pid}/exe" 2>/dev/null)"
  case "${exe% (deleted)}" in
    "${DOCKERD_DIR}/bin/dockerd" | /bin/dockerd)
      exit 0
      ;;
  esac
}

#######################################
# Bind-mount data directory to /var/lib/docker.
# Globals:
#   DATA_DIR
#   HOST_BUSYBOX
#######################################
setup_storage() {
  mkdir -p "${DATA_DIR}" /var/lib/docker
  if ! "${HOST_BUSYBOX}" mountpoint -q /var/lib/docker 2>/dev/null; then
    "${HOST_BUSYBOX}" mount -o bind "${DATA_DIR}" /var/lib/docker || exit 1
  fi
}

#######################################
# Copy configuration to /etc/daemon.json.
# Globals:
#   DOCKERD_DIR
#######################################
setup_config() {
  if [ -f "${DOCKERD_DIR}/daemon.json" ]; then
    cp "${DOCKERD_DIR}/daemon.json" /etc/daemon.json
  elif [ ! -f /etc/daemon.json ]; then
    echo '{}' >/etc/daemon.json
  fi
}

#######################################
# Save ip_forward before dockerd enables forwarding itself.
# Globals:
#   IP_FORWARD_FILE
#######################################
save_ip_forward() {
  [ -f "${IP_FORWARD_FILE}" ] && return 0
  cat /proc/sys/net/ipv4/ip_forward >"${IP_FORWARD_FILE}" 2>/dev/null
}

#######################################
# Set net_args from BRIDGE and BRIDGE_SUBNET.
# Globals:
#   BRIDGE
#   BRIDGE_SUBNET
#   HOST_BUSYBOX
# Outputs:
#   Sets net_args in the caller shell.
#######################################
set_network_args() {
  local bridge_ip
  bridge_ip="$(
    printf '%s' "${BRIDGE_SUBNET}" \
      | "${HOST_BUSYBOX}" awk -F'[./]' '
        NF == 5 {
          printf "%s.%s.%s.%d/%s", $1, $2, $3, $4 + 1, $5
        }
      '
  )"
  [ -n "${bridge_ip}" ] || bridge_ip='172.17.0.1/16'
  case "${BRIDGE}" in
    docker0) net_args="--bip=${bridge_ip}" ;;
    none) net_args='--bridge=none' ;;
    *) net_args="--bridge=${BRIDGE}" ;;
  esac
}

#######################################
# Validate environment and replace the shell with dockerd.
# Globals:
#   DOCKERD_DIR
#   HOST_BUSYBOX
#   MODDIR
#   PROXY
#   RUN_DIR
#   STORAGE_DRIVER
#######################################
main() {
  mkdir -p "${RUN_DIR}"
  check_namespace
  check_running
  setup_storage
  setup_config
  save_ip_forward
  set_network_args

  rm -f "${RUN_DIR}/docker.sock" "${RUN_DIR}/dockerd.pid"

  "${HOST_BUSYBOX}" setsid sh "${MODDIR}/scripts/net.sh" \
    >>"${RUN_DIR}/dockerd.log" 2>&1 </dev/null &

  exec /bin/busybox env -i \
    PATH="${DOCKERD_DIR}/bin:/bin:/system/bin:/usr/bin:/sbin" \
    HOME=/root \
    HTTP_PROXY="${PROXY}" HTTPS_PROXY="${PROXY}" \
    http_proxy="${PROXY}" https_proxy="${PROXY}" \
    "${DOCKERD_DIR}/bin/dockerd" \
    --data-root=/var/lib/docker \
    --exec-root="${RUN_DIR}/docker-exec" \
    --host="unix://${RUN_DIR}/docker.sock" \
    --pidfile="${RUN_DIR}/dockerd.pid" \
    --config-file=/etc/daemon.json \
    --iptables=true \
    --ip6tables=false \
    "${net_args}" \
    --userland-proxy=false \
    --storage-driver="${STORAGE_DRIVER}" \
    --log-level=info
}

main "$@"
