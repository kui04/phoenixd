#!/system/bin/sh
#
# Registers the Docker bridge with Android netd so the host can route to
# containers. Idempotent; safe to run again after boot completed.

DOCKERD_DIR=/data/adb/dockerd
IP_FORWARD_FILE=/data/adb/dockerd_ip_forward
SOCKET="${DOCKERD_DIR}/run/docker.sock"
UPSTREAM_FILE="${DOCKERD_DIR}/run/upstream"
LOCK_DIR="${DOCKERD_DIR}/run/net.lock.d"
readonly DOCKERD_DIR IP_FORWARD_FILE LOCK_DIR SOCKET UPSTREAM_FILE

[ -f "${DOCKERD_DIR}/settings.sh" ] && . "${DOCKERD_DIR}/settings.sh"
: "${BRIDGE:=docker0}"
: "${BRIDGE_SUBNET:=172.17.0.0/16}"

# No bridge means nothing to register with netd.
if [ "${BRIDGE}" = 'none' ]; then
  exit 0
fi

# control.sh and boot-completed.sh can start this script at the same time.
mkdir -p "${DOCKERD_DIR}/run"
if ! mkdir "${LOCK_DIR}" 2>/dev/null; then
  owner="$(cat "${LOCK_DIR}/pid" 2>/dev/null)"
  if [ -n "${owner}" ] && kill -0 "${owner}" 2>/dev/null; then
    exit 0
  fi
  rm -rf "${LOCK_DIR}"
  mkdir "${LOCK_DIR}" 2>/dev/null || exit 0
fi
echo $$ >"${LOCK_DIR}/pid"
trap 'rm -rf "${LOCK_DIR}" 2>/dev/null' EXIT

i=0
while [ "${i}" -lt 60 ]; do
  [ -S "${SOCKET}" ] && break
  i=$(( i + 1 ))
  sleep 1
done

if [ ! -S "${SOCKET}" ]; then
  echo 'docker socket did not appear' >&2
  exit 1
fi

i=0
while [ "${i}" -lt 30 ]; do
  ip link show "${BRIDGE}" >/dev/null 2>&1 && break
  i=$(( i + 1 ))
  sleep 1
done

if ! ip link show "${BRIDGE}" >/dev/null 2>&1; then
  echo "bridge ${BRIDGE} did not appear" >&2
  exit 1
fi

# Keep the pre-Docker value for cleanup if start.sh has not saved it yet.
if [ ! -f "${IP_FORWARD_FILE}" ]; then
  cat /proc/sys/net/ipv4/ip_forward >"${IP_FORWARD_FILE}" 2>/dev/null
fi
echo 1 >/proc/sys/net/ipv4/ip_forward 2>/dev/null

ndc network interface remove local "${BRIDGE}" >/dev/null 2>&1
ndc network interface add local "${BRIDGE}" >/dev/null 2>&1
ndc network route add local "${BRIDGE}" "${BRIDGE_SUBNET}" >/dev/null 2>&1
ndc ipfwd enable docker >/dev/null 2>&1

upstream=''
i=0
while [ "${i}" -lt 30 ]; do
  upstream="$(
    ip route get 8.8.8.8 2>/dev/null \
      | sed -n 's/.* dev \([^ ]*\).*/\1/p' \
      | head -n 1
  )"
  [ -n "${upstream}" ] && break
  i=$(( i + 1 ))
  sleep 1
done

if [ -n "${upstream}" ] && [ "${upstream}" != "${BRIDGE}" ]; then
  previous=''
  [ -f "${UPSTREAM_FILE}" ] && previous="$(cat "${UPSTREAM_FILE}")"
  if [ -n "${previous}" ] && [ "${previous}" != "${upstream}" ]; then
    ndc ipfwd remove "${BRIDGE}" "${previous}" >/dev/null 2>&1
  fi
  echo "${upstream}" >"${UPSTREAM_FILE}"
  ndc ipfwd add "${BRIDGE}" "${upstream}" >/dev/null 2>&1
fi
