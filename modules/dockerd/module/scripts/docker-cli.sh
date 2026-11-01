#!/system/bin/sh
#
# docker wrapper: points the CLI at the module config and socket, and adds the
# CA bundle and proxy settings a static Go binary cannot find on Android.

DOCKERD_DIR=/data/adb/dockerd
CA_BUNDLE="${DOCKERD_DIR}/config/ca-certificates.crt"
readonly CA_BUNDLE DOCKERD_DIR

export DOCKER_CONFIG="${DOCKER_CONFIG:-${DOCKERD_DIR}/config}"
export DOCKER_HOST="${DOCKER_HOST:-unix://${DOCKERD_DIR}/run/docker.sock}"

# BuildKit metadata and docker login run in the CLI, which needs both.
if [ -z "${SSL_CERT_FILE:-}${SSL_CERT_DIR:-}" ] && [ -s "${CA_BUNDLE}" ]; then
  export SSL_CERT_FILE="${CA_BUNDLE}"
fi

if [ -z "${HTTPS_PROXY:-}${https_proxy:-}${HTTP_PROXY:-}${http_proxy:-}" ] \
  && [ -f "${DOCKERD_DIR}/settings.sh" ]; then
  proxy="$(. "${DOCKERD_DIR}/settings.sh" && printf '%s' "${PROXY:-}")"
  if [ -n "${proxy}" ]; then
    export HTTP_PROXY="${proxy}" HTTPS_PROXY="${proxy}"
    export http_proxy="${proxy}" https_proxy="${proxy}"
  fi
fi

exec "${DOCKERD_DIR}/bin/docker-cli" "$@"
