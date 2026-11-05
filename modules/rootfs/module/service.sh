#!/system/bin/sh
#
# Starts the host supervisor and Layer 1 after boot. KernelSU runs the module
# scripts in an undefined order and /data settles late, so a failed start is
# retried with a backoff instead of being lost.

MODDIR="${0%/*}"
readonly MODDIR
. "${MODDIR}/scripts/common.sh"

mkdir -p "${RUN_DIR}"
{
  count=0
  while [ "${count}" -lt 12 ]; do
    if sh "${MODDIR}/scripts/control.sh" start; then
      exit 0
    fi
    count=$(( count + 1 ))
    sleep 10
  done
  err 'boot start failed after 12 attempts'
  exit 1
} >>"${RUN_DIR}/boot.log" 2>&1
