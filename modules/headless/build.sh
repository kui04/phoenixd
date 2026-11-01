#!/usr/bin/env bash
#
# Builds the installable KernelSU Next module zip. The static binaries come
# from the Nix flake in the repository root (layer1-bin).

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly ROOT_DIR
readonly MODULE_DIR="${ROOT_DIR}/module"
readonly FILES_DIR="${MODULE_DIR}/files"
readonly DIST_DIR="${ROOT_DIR}/dist"
readonly BINARIES=(busybox wpa_supplicant wpa_cli iw phx-statusd dns-forwarder)

#######################################
# Copy the static binaries from the Nix flake into files/.
# Globals:
#   BINARIES
#   FILES_DIR
#   LAYER1_BIN
#   ROOT_DIR
# Arguments:
#   None. LAYER1_BIN names a layer1-bin output to use instead of nix build.
#######################################
stage_binaries() {
  local bin_dir="${LAYER1_BIN:-}"
  local name
  make -C "${ROOT_DIR}/src" clean >/dev/null 2>&1 || true
  if [[ -z "${bin_dir}" ]]; then
    bin_dir="$(nix build --no-link --print-out-paths \
      "path:${ROOT_DIR}/../..#layer1-bin")"
  fi
  mkdir -p "${FILES_DIR}"
  for name in "${BINARIES[@]}"; do
    cp -f "${bin_dir}/bin/${name}" "${FILES_DIR}/${name}"
    chmod 755 "${FILES_DIR}/${name}"
  done
}

#######################################
# Build the zip from the staged binaries.
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
  stage_binaries
  chmod 755 "${MODULE_DIR}"/*.sh "${MODULE_DIR}"/scripts/*.sh \
    "${MODULE_DIR}"/scripts/service/*.sh
  chmod 644 "${MODULE_DIR}/scripts/settings.sh"
  zip="${DIST_DIR}/headless-${version}.zip"
  rm -f "${zip}"
  (cd "${MODULE_DIR}" && zip -q -r -9 "${zip}" . -x 'files/.gitignore')
  echo "built ${zip} ($(du -h "${zip}" | cut -f1))"
  sha256sum "${zip}"
}

main "$@"
