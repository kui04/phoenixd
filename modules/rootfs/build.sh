#!/usr/bin/env bash
#
# Builds the installable KernelSU Next module zip. The static BusyBox binary
# comes from the Nix flake in the repository root (layer1-bin).

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly ROOT_DIR
readonly MODULE_DIR="${ROOT_DIR}/module"
readonly FILES_DIR="${MODULE_DIR}/files"
readonly DIST_DIR="${ROOT_DIR}/dist"

#######################################
# Copy the static BusyBox binary from the Nix flake into files/.
# Globals:
#   FILES_DIR
#   LAYER1_BIN
#   ROOT_DIR
# Arguments:
#   None. LAYER1_BIN names a layer1-bin output to use instead of nix build.
#######################################
stage_busybox() {
  local bin_dir="${LAYER1_BIN:-}"
  if [[ -z "${bin_dir}" ]]; then
    bin_dir="$(nix build --no-link --print-out-paths \
      "${ROOT_DIR}/../..#layer1-bin")"
  fi
  mkdir -p "${FILES_DIR}"
  cp -f "${bin_dir}/bin/busybox" "${FILES_DIR}/busybox"
  chmod 755 "${FILES_DIR}/busybox"
}

#######################################
# Copy the GPU acceleration drivers from the Nix flake into files/.
# Globals:
#   FILES_DIR
#   LAYER1_DRIVERS
#   ROOT_DIR
# Arguments:
#   None. LAYER1_DRIVERS names a layer1-drivers output to use.
#######################################
stage_drivers() {
  local drivers_dir="${LAYER1_DRIVERS:-}"
  if [[ -z "${drivers_dir}" ]]; then
    drivers_dir="$(nix build --no-link --print-out-paths \
      "${ROOT_DIR}/../..#layer1-drivers")"
  fi
  mkdir -p "${FILES_DIR}/lib/dri" "${FILES_DIR}/share/vulkan/icd.d"
  cp -af "${drivers_dir}/lib/." "${FILES_DIR}/lib/"
  cp -af "${drivers_dir}/share/." "${FILES_DIR}/share/"
  chmod -R u+w "${FILES_DIR}/lib" "${FILES_DIR}/share"
}

#######################################
# Build the zip from the staged binary.
# Globals:
#   DIST_DIR
#   MODULE_DIR
# Outputs:
#   Writes the built zip path and its SHA256 to stdout.
#######################################
main() {
  local version zip
  version="$(sed -n 's/^version=//p' "${MODULE_DIR}/module.prop")"
  mkdir -p "${DIST_DIR}"
  stage_busybox
  stage_drivers
  chmod 755 "${MODULE_DIR}"/*.sh "${MODULE_DIR}"/scripts/*.sh
  chmod 644 "${MODULE_DIR}/scripts/settings.sh"
  zip="${DIST_DIR}/rootfs-${version}.zip"
  rm -f "${zip}"
  (cd "${MODULE_DIR}" && zip -q -r -9 "${zip}" . -x 'files/.gitignore')
  echo "built ${zip} ($(du -h "${zip}" | cut -f1))"
  sha256sum "${zip}"
}

main "$@"

