#!/usr/bin/env bash
#
# Builds the installable KernelSU Next module zip: downloads the official
# static Docker binaries, docker compose and docker buildx, takes the static
# BusyBox from the Nix flake in the repository root, then packs them.

set -euo pipefail

readonly DOCKER_VERSION="${DOCKER_VERSION:-29.9.2}"
readonly COMPOSE_VERSION="${COMPOSE_VERSION:-5.6.1}"
readonly BUILDX_VERSION="${BUILDX_VERSION:-0.38.1}"

ROOT_DIR="$(cd "$(dirname "$0")" && pwd)"
readonly ROOT_DIR
readonly MODULE_DIR="${ROOT_DIR}/module"
readonly FILES_DIR="${MODULE_DIR}/files"
readonly CACHE_DIR="${ROOT_DIR}/.cache"
readonly DIST_DIR="${ROOT_DIR}/dist"

readonly DOCKER_TGZ="docker-${DOCKER_VERSION}.tgz"
DOCKER_BASE_URL='https://download.docker.com/linux/static/stable/aarch64'
readonly DOCKER_BASE_URL
readonly DOCKER_URL="${DOCKER_BASE_URL}/${DOCKER_TGZ}"
readonly COMPOSE_NAME="docker-compose-${COMPOSE_VERSION}"
readonly COMPOSE_ASSET='docker-compose-linux-aarch64'
readonly COMPOSE_BASE_URL='https://github.com/docker/compose/releases/download'
readonly COMPOSE_URL="${COMPOSE_BASE_URL}/v${COMPOSE_VERSION}/${COMPOSE_ASSET}"
readonly BUILDX_NAME="buildx-v${BUILDX_VERSION}.linux-arm64"
readonly BUILDX_BASE_URL='https://github.com/docker/buildx/releases/download'
readonly BUILDX_URL="${BUILDX_BASE_URL}/v${BUILDX_VERSION}/${BUILDX_NAME}"

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
# Extract the docker binaries and pack them as files/docker.tar.xz.
# Globals:
#   CACHE_DIR
#   FILES_DIR
#   DOCKER_TGZ
#   stage
#######################################
stage_docker() {
  tar -xzf "${CACHE_DIR}/${DOCKER_TGZ}" -C "${stage}" \
    docker/dockerd docker/containerd docker/containerd-shim-runc-v2 \
    docker/runc docker/docker-proxy docker/docker-init docker/docker
  mkdir -p "${stage}/bin"
  mv "${stage}"/docker/* "${stage}/bin/"
  rmdir "${stage}/docker"
  rm -f "${FILES_DIR}/docker.tar.xz"
  tar -cJf "${FILES_DIR}/docker.tar.xz" -C "${stage}" bin
  rm -rf "${stage:?}/bin"
  echo "docker binaries: $(du -h "${FILES_DIR}/docker.tar.xz" | cut -f1)"
}

#######################################
# Copy the static BusyBox from the Nix flake into files/busybox.
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
# Copy both CLI plugins into files/cli-plugins.
# Globals:
#   CACHE_DIR
#   FILES_DIR
#   COMPOSE_NAME
#   BUILDX_NAME
#######################################
stage_plugins() {
  mkdir -p "${FILES_DIR}/cli-plugins"
  cp -f "${CACHE_DIR}/${COMPOSE_NAME}" "${FILES_DIR}/cli-plugins/docker-compose"
  cp -f "${CACHE_DIR}/${BUILDX_NAME}" "${FILES_DIR}/cli-plugins/docker-buildx"
  chmod 755 "${FILES_DIR}/cli-plugins/docker-compose" \
    "${FILES_DIR}/cli-plugins/docker-buildx"
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
# Set version and versionCode in module.prop from DOCKER_VERSION.
# Globals:
#   DOCKER_VERSION
#   PROP_FILE
#   PROP_BACKUP
#######################################
write_version() {
  local version="${DOCKER_VERSION#v}"
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
  rm -rf "${FILES_DIR}/cli-plugins"

  trap cleanup EXIT
  write_version

  fetch "${DOCKER_URL}" "${DOCKER_TGZ}"
  verify_sha256 "${DOCKER_SHA256:-}" "${CACHE_DIR}/${DOCKER_TGZ}"

  stage="$(mktemp -d)"
  stage_docker

  stage_busybox

  fetch "${COMPOSE_URL}" "${COMPOSE_NAME}"
  verify_sha256 "${COMPOSE_SHA256:-}" "${CACHE_DIR}/${COMPOSE_NAME}"
  fetch "${BUILDX_URL}" "${BUILDX_NAME}"
  verify_sha256 "${BUILDX_SHA256:-}" "${CACHE_DIR}/${BUILDX_NAME}"
  stage_plugins

  chmod 755 "${MODULE_DIR}"/*.sh "${MODULE_DIR}"/scripts/*.sh
  chmod 644 "${MODULE_DIR}/scripts/settings.sh"

  local zip="${DIST_DIR}/dockerd-${DOCKER_VERSION}.zip"
  rm -f "${zip}"
  (cd "${MODULE_DIR}" && zip -q -r -9 "${zip}" . -x 'files/.gitignore')
  echo "built ${zip} ($(du -h "${zip}" | cut -f1))"
  sha256sum "${zip}"
}

main "$@"
