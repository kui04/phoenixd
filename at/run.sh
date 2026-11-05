#!/usr/bin/env bash
#
# Acceptance runner. It runs the static gates on the host, pushes the cases to
# the device, and runs them one by one as root. One log per case lives on the
# device under /data/local/tmp/at. The runner prints PASS, FAIL, or SKIP.
#
# Usage: at/run.sh [case-id ...]
#   With no argument, every case runs in order. AT-01 stops at the first FAIL.

set -uo pipefail

AT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_DIR="$(cd "${AT_DIR}/.." && pwd)"
readonly AT_DIR REPO_DIR
readonly DEVICE_DIR=/data/local/tmp/at
readonly SERIAL="${ANDROID_SERIAL:-ff2c54da}"
ADB=(adb -s "${SERIAL}")

#######################################
# Run the static gates of the repository.
#######################################
run_gates() {
  local rc=0
  echo '== AT-00 static gates =='
  nix run nixpkgs#beautysh -- --check -i 2 -s paronly \
    --variable-style braces \
    "${REPO_DIR}"/modules/rootfs/build.sh \
    "${REPO_DIR}"/modules/rootfs/module/*.sh \
    "${REPO_DIR}"/modules/rootfs/module/scripts/*.sh \
    || rc=1
  nix run nixpkgs#shellcheck -- -s busybox \
    "${REPO_DIR}"/modules/rootfs/module/*.sh \
    "${REPO_DIR}"/modules/rootfs/module/scripts/*.sh || rc=1
  nix run nixpkgs#shellcheck -- -s bash \
    "${REPO_DIR}"/modules/rootfs/build.sh || rc=1
  for file in "${REPO_DIR}"/modules/*/module/*.sh \
    "${REPO_DIR}"/modules/*/module/scripts/*.sh \
    "${REPO_DIR}"/modules/*/module/host-service/*/run; do
    nix run nixpkgs#busybox -- ash -n "${file}" || rc=1
  done
  [ "${rc}" -eq 0 ] && echo 'PASS AT-00' || echo 'FAIL AT-00'
  return "${rc}"
}

#######################################
# Run one case on the device and keep its log.
# Arguments:
#   Case ID.
#######################################
run_case() {
  local id="${1}" log="/data/local/tmp/at/${1}.log" rc
  "${ADB[@]}" shell "su -c 'AT_DIR=${DEVICE_DIR} sh ${DEVICE_DIR}/cases/${id}.sh'" \
    >"/tmp/at-${id}.log" 2>&1
  rc=$?
  "${ADB[@]}" push "/tmp/at-${id}.log" "${log}" >/dev/null 2>&1
  cat "/tmp/at-${id}.log"
  case "${rc}" in
    0) echo "PASS ${id}" ;;
    77) echo "SKIP ${id}" ;;
    *)
      echo "FAIL ${id}"
      return 1
      ;;
  esac
}

#######################################
# Push the cases and run them in order.
#######################################
main() {
  local id rc=0 ids=()
  if [ "$#" -gt 0 ]; then
    ids=("$@")
  else
    for file in "${AT_DIR}"/cases/at-*.sh; do
      id="$(basename "${file}" .sh)"
      ids+=("${id}")
    done
  fi
  "${ADB[@]}" shell 'su -c "rm -rf /data/local/tmp/at; mkdir -p /data/local/tmp/at; chmod 777 /data/local/tmp/at"'
  "${ADB[@]}" push "${AT_DIR}/lib.sh" "${DEVICE_DIR}/lib.sh" >/dev/null
  "${ADB[@]}" push "${AT_DIR}/cases" "${DEVICE_DIR}/cases" >/dev/null
  "${ADB[@]}" shell "su -c 'chmod -R 755 ${DEVICE_DIR}'"
  run_gates || rc=1
  for id in "${ids[@]}"; do
    echo
    echo "== ${id} =="
    if ! run_case "${id}"; then
      rc=1
      case "${id}" in
        at-1* | at-2* | at-3* | at-4*) break ;;
      esac
    fi
  done
  exit "${rc}"
}

main "$@"
