#!/usr/bin/env bash
#
# Builds the installable KernelSU Next module zip: downloads the official
# Android arm64 sing-box release and packs it.

set -euo pipefail

readonly SINGBOX_VERSION="${SINGBOX_VERSION:-1.14.3}"

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly ROOT_DIR
readonly MODULE_DIR="${ROOT_DIR}/module"
readonly FILES_DIR="${MODULE_DIR}/files"
readonly CACHE_DIR="${ROOT_DIR}/.cache"
readonly DIST_DIR="${ROOT_DIR}/dist"

readonly SINGBOX_RELEASE="sing-box-${SINGBOX_VERSION}-android-arm64"
readonly SINGBOX_TGZ="${SINGBOX_RELEASE}.tar.gz"
SINGBOX_BASE_URL='https://github.com/SagerNet/sing-box/releases/download'
readonly SINGBOX_BASE_URL
readonly SINGBOX_URL="${SINGBOX_BASE_URL}/v${SINGBOX_VERSION}/${SINGBOX_TGZ}"

readonly PROP_FILE="${MODULE_DIR}/module.prop"
readonly PROP_BACKUP="${CACHE_DIR}/module.prop.orig"

# Set by main; cleanup() removes it on exit.
stage=''

#######################################
# Download a file into the cache unless the cache already has it.
# Globals:
#   CACHE_DIR
# Arguments:
#   URL
#   Cache file name
#######################################
fetch() {
  local url="$1"
  local file="${CACHE_DIR}/$2"
  if [[ -s "${file}" ]]; then
    return
  fi
  echo "downloading ${url}"
  curl -fsSL -o "${file}.part" "${url}"
  mv "${file}.part" "${file}"
}

#######################################
# Check a file against a SHA256 when one is given.
# Arguments:
#   Expected SHA256, may be empty
#   File to check
# Returns:
#   1 on mismatch, after removing the cached file so the next run refetches.
#######################################
verify_sha256() {
  local expected="$1"
  local file="$2"
  if [[ -z "${expected}" ]]; then
    return 0
  fi
  if ! echo "${expected}  ${file}" | sha256sum -c -; then
    rm -f "${file}"
    return 1
  fi
}

#######################################
# Extract the sing-box binary into files/sing-box.
# Globals:
#   CACHE_DIR
#   FILES_DIR
#   SINGBOX_RELEASE
#   SINGBOX_TGZ
#   stage
#######################################
stage_singbox() {
  tar -xzf "${CACHE_DIR}/${SINGBOX_TGZ}" -C "${stage}" \
    "${SINGBOX_RELEASE}/sing-box"
  cp -f "${stage}/${SINGBOX_RELEASE}/sing-box" "${FILES_DIR}/sing-box"
  chmod 755 "${FILES_DIR}/sing-box"
  echo "sing-box binary: $(du -h "${FILES_DIR}/sing-box" | cut -f1)"
}

#######################################
# Restore module.prop after a version bump.
# Globals:
#   PROP_BACKUP
#   PROP_FILE
#######################################
restore_prop() {
  if [[ -f "${PROP_BACKUP}" ]]; then
    cp -f "${PROP_BACKUP}" "${PROP_FILE}"
  fi
}

#######################################
# Set version and versionCode in module.prop from SINGBOX_VERSION.
# Globals:
#   PROP_BACKUP
#   PROP_FILE
#   SINGBOX_VERSION
#######################################
write_version() {
  local version="${SINGBOX_VERSION#v}"
  local version_code
  version_code="$(
    printf '%s' "${version}" \
      | awk -F. '{ printf "%d%02d%02d", $1, $2, $3 }'
  )"
  cp -f "${PROP_FILE}" "${PROP_BACKUP}"
  sed -i \
    -e "s/^version=.*/version=${version}/" \
    -e "s/^versionCode=.*/versionCode=${version_code}/" \
    "${PROP_FILE}"
}

#######################################
# Restore module.prop and remove the temporary directory on exit.
# Globals:
#   stage
#######################################
cleanup() {
  if [[ -n "${stage:-}" ]]; then
    rm -rf "${stage}"
  fi
  restore_prop
}

#######################################
# Build the zip from the cached artifacts.
# Globals:
#   CACHE_DIR
#   DIST_DIR
#   FILES_DIR
#   MODULE_DIR
# Outputs:
#   Writes the built zip path and its SHA256 to stdout.
#######################################
main() {
  mkdir -p "${FILES_DIR}" "${CACHE_DIR}" "${DIST_DIR}"

  trap cleanup EXIT
  write_version

  fetch "${SINGBOX_URL}" "${SINGBOX_TGZ}"
  verify_sha256 "${SINGBOX_SHA256:-}" "${CACHE_DIR}/${SINGBOX_TGZ}"

  stage="$(mktemp -d)"
  stage_singbox

  chmod 755 "${MODULE_DIR}"/*.sh "${MODULE_DIR}"/scripts/*.sh

  local zip="${DIST_DIR}/singbox-${SINGBOX_VERSION}.zip"
  rm -f "${zip}"
  (cd "${MODULE_DIR}" && zip -q -r -9 "${zip}" . -x 'files/.gitignore')
  echo "built ${zip} ($(du -h "${zip}" | cut -f1))"
  sha256sum "${zip}"
}

main "$@"
