#!/usr/bin/env bash
#
# Builds the installable KernelSU Next module zip. The host fetches the
# Alpine minirootfs and the package cache, so that the device can build the
# image without a network.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly ROOT_DIR
readonly MODULE_DIR="${ROOT_DIR}/module"
readonly FILES_DIR="${MODULE_DIR}/files"
readonly CACHE_DIR="${ROOT_DIR}/.cache"
readonly SCRATCH_DIR="${CACHE_DIR}/scratch"
readonly DIST_DIR="${ROOT_DIR}/dist"

readonly ALPINE_VERSION='3.24.3'
readonly ALPINE_ARCH='aarch64'
readonly ALPINE_SHA256='4d3f80afaebd447c5591a63a73bde380a149fe8b2d85488cafabb2ff97551f50'
readonly ALPINE_TARBALL="alpine-minirootfs-${ALPINE_VERSION}-${ALPINE_ARCH}.tar.gz"
readonly ALPINE_URL="https://dl-cdn.alpinelinux.org/alpine/v${ALPINE_VERSION%.*}/releases/${ALPINE_ARCH}/${ALPINE_TARBALL}"

# openrc pulls ifupdown-ng through ifupdown-any, which supplies ifup and
# ifquery. The install_if metadata also adds the OpenRC scripts of docker,
# containerd, and iptables.
readonly PACKAGES=(
  openrc
  docker
  docker-cli-compose
  iptables-legacy
  iproute2
  e2fsprogs
  util-linux
  ca-certificates
  tzdata
)

APK_BIN=''

#######################################
# Print the apk-tools 3 binary to use.
# Globals:
#   APK
# Returns:
#   0 and prints the path, 1 when apk is absent.
#######################################
find_apk() {
  local store_path
  if [[ -n "${APK:-}" ]]; then
    echo "${APK}"
    return 0
  fi
  if command -v apk >/dev/null 2>&1; then
    command -v apk
    return 0
  fi
  store_path="$(nix build --no-link --print-out-paths nixpkgs#apk-tools)"
  echo "${store_path}/bin/apk"
}

#######################################
# Exit unless a file matches an expected SHA256 checksum.
# Arguments:
#   File path.
#   Expected checksum.
#######################################
verify_sha256() {
  local file="$1" expected="$2" actual
  actual="$(sha256sum "${file}" | cut -d' ' -f1)"
  if [[ "${actual}" != "${expected}" ]]; then
    echo "checksum mismatch: ${file}" >&2
    echo "  expected ${expected}" >&2
    echo "  actual   ${actual}" >&2
    exit 1
  fi
}

#######################################
# Download the Alpine minirootfs and check its checksum.
# Globals:
#   ALPINE_SHA256
#   ALPINE_TARBALL
#   ALPINE_URL
#   CACHE_DIR
# Returns:
#   The tarball path on stdout.
#######################################
fetch_minirootfs() {
  local tarball="${CACHE_DIR}/${ALPINE_TARBALL}"
  if [[ ! -f "${tarball}" ]]; then
    mkdir -p "${CACHE_DIR}"
    echo "downloading ${ALPINE_URL}" >&2
    curl -fsSL -o "${tarball}.part" "${ALPINE_URL}"
    mv "${tarball}.part" "${tarball}"
  fi
  verify_sha256 "${tarball}" "${ALPINE_SHA256}"
  echo "${tarball}"
}

#######################################
# Extract the minirootfs into the scratch root, once. The keys and the apk
# database of the scratch root drive the resolution of the package cache.
# Globals:
#   SCRATCH_DIR
# Arguments:
#   Tarball path.
#######################################
prepare_scratch() {
  local tarball="$1"
  if [[ -x "${SCRATCH_DIR}/sbin/apk" ]]; then
    return 0
  fi
  echo "extracting ${tarball} into the scratch root"
  rm -rf "${SCRATCH_DIR}"
  mkdir -p "${SCRATCH_DIR}"
  tar -xzf "${tarball}" -C "${SCRATCH_DIR}"
}

#######################################
# Run apk against the scratch root.
# Globals:
#   ALPINE_ARCH
#   APK_BIN
#   SCRATCH_DIR
# Arguments:
#   apk arguments.
#######################################
run_apk() {
  "${APK_BIN}" --root "${SCRATCH_DIR}" --arch "${ALPINE_ARCH}" \
    --keys-dir "${SCRATCH_DIR}/etc/apk/keys" "$@"
}

#######################################
# Refresh the package index of the scratch root.
# Globals:
#   APK_BIN
#######################################
update_index() {
  run_apk update
}

#######################################
# Resolve the package set and print what the image would install, without
# downloading it.
# Globals:
#   PACKAGES
#######################################
check_resolution() {
  run_apk add --simulate "${PACKAGES[@]}"
}

#######################################
# Download the package set and its dependencies into the module payload.
# Globals:
#   FILES_DIR
#   PACKAGES
#######################################
fetch_packages() {
  local cache_dir="${FILES_DIR}/apk-cache" count size
  rm -rf "${cache_dir}"
  mkdir -p "${cache_dir}"
  run_apk fetch --recursive -o "${cache_dir}" "${PACKAGES[@]}"
  count="$(find "${cache_dir}" -name '*.apk' | wc -l)"
  size="$(du -sh "${cache_dir}" | cut -f1)"
  echo "staged ${count} packages, ${size}"
}

#######################################
# Copy the minirootfs into the module payload.
# Globals:
#   ALPINE_TARBALL
#   FILES_DIR
# Arguments:
#   Tarball path.
#######################################
stage_minirootfs() {
  local tarball="$1"
  mkdir -p "${FILES_DIR}"
  cp -f "${tarball}" "${FILES_DIR}/${ALPINE_TARBALL}"
}

#######################################
# Copy the static BusyBox binary from the Nix flake into the payload.
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
  cp -f "${bin_dir}/bin/busybox" "${FILES_DIR}/busybox"
  chmod 755 "${FILES_DIR}/busybox"
}

#######################################
# Copy the DNS forwarder from the Nix flake into the payload.
# Globals:
#   FILES_DIR
#   ROOT_DIR
# Arguments:
#   None. LAYER1_DNS names a dns-forwarder output to use.
#######################################
stage_forwarder() {
  local bin_dir="${LAYER1_DNS:-}"
  if [[ -z "${bin_dir}" ]]; then
    bin_dir="$(nix build --no-link --print-out-paths \
      "${ROOT_DIR}/../..#dns-forwarder")"
  fi
  cp -f "${bin_dir}/bin/dns-forwarder" "${FILES_DIR}/dns-forwarder"
  chmod 755 "${FILES_DIR}/dns-forwarder"
}

#######################################
# Copy the GPU and codec drivers from the Nix flake into the payload.
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
  rm -rf "${FILES_DIR}/drivers"
  mkdir -p "${FILES_DIR}/drivers"
  cp -af "${drivers_dir}/." "${FILES_DIR}/drivers/"
  chmod -R u+w "${FILES_DIR}/drivers"
}

#######################################
# Write the module zip and print its path and checksum.
# Globals:
#   DIST_DIR
#   MODULE_DIR
#######################################
write_zip() {
  local version zip
  version="$(sed -n 's/^version=//p' "${MODULE_DIR}/module.prop")"
  mkdir -p "${DIST_DIR}"
  chmod 755 "${MODULE_DIR}"/*.sh "${MODULE_DIR}"/scripts/*.sh
  zip="${DIST_DIR}/rootfs-${version}.zip"
  rm -f "${zip}"
  # -y keeps the symlinks of the overlay, such as the runlevel links.
  (cd "${MODULE_DIR}" && zip -q -r -6 -y "${zip}" . -x 'files/.gitignore')
  echo "built ${zip} ($(du -h "${zip}" | cut -f1))"
  sha256sum "${zip}"
}

#######################################
# Fetch the payload and write the module zip.
#######################################
main() {
  local tarball
  APK_BIN="$(find_apk)"
  tarball="$(fetch_minirootfs)"
  prepare_scratch "${tarball}"
  update_index
  check_resolution
  fetch_packages
  stage_minirootfs "${tarball}"
  stage_busybox
  stage_forwarder
  stage_drivers
  write_zip
}

main "$@"
