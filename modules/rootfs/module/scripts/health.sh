#!/system/bin/sh
#
# Health checks for the Layer 1 host. Every check prints one line, and the
# command fails when a check fails. Nothing is repaired here.
#
# Checks: image filesystem, eth0 address, rule order, iptables self-test,
# tun0 when the proxy runs, the WAN mirror, and the host services.

MODDIR="$(cd "${0%/*}/.." && pwd)"
readonly MODDIR
. "${MODDIR}/scripts/common.sh"

FAILED=0

#######################################
# Report one check result.
# Arguments:
#   Check name, state (ok, fail, skip), and an optional detail.
#######################################
report() {
  local name="${1}" state="${2}" detail="${3:-}"
  printf '%-22s %-5s %s\n' "${name}" "${state}" "${detail}"
  case "${state}" in
    fail) FAILED=$(( FAILED + 1 )) ;;
  esac
}

#######################################
# Check the image filesystem when nothing uses it.
#######################################
check_image() {
  local loop
  if [ ! -f "${IMAGE_PATH}" ]; then
    report image fail 'the image is missing'
    return
  fi
  loop="$(image_loop_device)"
  if [ -n "${loop}" ] || l1_running; then
    report image skip "in use on ${loop:-Layer 1}"
    return
  fi
  if image_fsck >/dev/null 2>&1; then
    report image ok 'filesystem clean'
  else
    report image fail 'run: rootfs-service image fsck'
  fi
}

#######################################
# Check the address of eth0 inside Layer 1.
#######################################
check_address() {
  local address
  if ! l1_running; then
    report eth0 skip 'Layer 1 is stopped'
    return
  fi
  address="$("${BUSYBOX}" nsenter -t "$(l1_pid)" -m -u -i -n -p -r -w -- \
    /bin/busybox ip -4 -o addr show eth0 2>/dev/null | awk '{ print $4 }')"
  case "${address}" in
    10.0.0.2/24*) report eth0 ok "${address}" ;;
    '') report eth0 fail 'eth0 has no address' ;;
    *) report eth0 fail "unexpected address ${address}" ;;
  esac
}

#######################################
# Check that the six routing rules exist in the documented order.
#######################################
check_rules() {
  local prefs expected missing=''
  expected='8900 8950 8951 8952 9000 9001 9500 9501'
  for pref in ${expected}; do
    if ! ip rule show 2>/dev/null | grep -q "^${pref}:"; then
      missing="${missing} ${pref}"
    fi
  done
  if [ -n "${missing}" ]; then
    report rules fail "missing pref:${missing}"
  elif ip rule show 2>/dev/null \
    | awk -F: '$1 >= 8900 && $1 <= 9600' \
    | grep -q suppress_prefixlength; then
    report rules fail 'a suppress_prefixlength rule is in the range'
  else
    report rules ok 'order 8900 < 8950 < 9000 < 9500'
  fi
}

#######################################
# Run the iptables self-test.
#######################################
check_iptables() {
  if sh "${MODDIR}/scripts/net-iptables.sh" test >/dev/null 2>&1; then
    report iptables ok 'self-test passed'
  else
    report iptables fail 'the self-test failed, DNAT objects stay off'
  fi
}

#######################################
# Check tun0 when the proxy service claims to run.
#######################################
check_proxy() {
  local count status
  status="$("${BUSYBOX}" sv status \
    "${ROOTFS_HOME}/host-service/singbox" 2>/dev/null)"
  case "${status}" in
    run:*)
      # tun0 without its rules sends every packet past the proxy, so the
      # interface alone is not a healthy state. sing-box installs one rule at
      # 9000 and three at 9001, and its table carries split routes rather than
      # a default, so test for presence, not for a count or a default.
      if ! ip -o link show tun0 >/dev/null 2>&1; then
        report proxy fail 'the service runs, but tun0 is missing'
      elif ! ip rule show 2>/dev/null | grep -q '^9000:'; then
        report proxy fail 'tun0 is up, rule 9000 is missing'
      elif ! ip rule show 2>/dev/null | grep -q '^9001:'; then
        report proxy fail 'tun0 is up, rule 9001 is missing'
      elif ! ip route show table 2022 2>/dev/null | grep -q ' dev tun0'; then
        report proxy fail 'tun0 is up, table 2022 has no route to it'
      else
        report proxy ok 'tun0 and its rules are up'
      fi
      ;;
    *) report proxy skip 'the proxy is stopped, Layer 1 fails open' ;;
  esac
}

#######################################
# Check that the Docker daemon answers inside Layer 1.
#######################################
check_docker() {
  local info pid version
  if ! l1_running; then
    report docker skip 'Layer 1 is stopped'
    return
  fi
  pid="$(l1_pid)" || return
  info="$("${BUSYBOX}" nsenter -t "${pid}" -m -u -i -n -p -r -w -- \
    /bin/busybox env -i "PATH=${L1_PATH}" HOME=/root docker info 2>/dev/null)"
  version="$(echo "${info}" | sed -n 's/^ Server Version: //p')"
  if [ -n "${version}" ]; then
    report docker ok "server ${version}"
  else
    report docker fail 'the daemon does not answer on /run/docker.sock'
  fi
}

#######################################
# Check the mirrored WAN default route.
#######################################
check_wan() {
  if ip route show table 9500 2>/dev/null | grep -q '^default'; then
    report wan ok "$(ip route show table 9500 | sed -n 's/^default/default/p')"
  else
    report wan fail 'table 9500 has no default route'
  fi
}

#######################################
# Check the host supervisor and its services.
#######################################
stopped_services() {
  local name state missing=''
  for name in network dns wifi charge display singbox; do
    state="$("${BUSYBOX}" sv status \
      "${ROOTFS_HOME}/host-service/${name}" 2>/dev/null | head -n 1)"
    case "${state}" in
      run:*) ;;
      *) missing="${missing} ${name}" ;;
    esac
  done
  echo "${missing}"
}

check_host_services() {
  local missing
  if ! sh "${MODDIR}/scripts/host.sh" status >/dev/null 2>&1; then
    report host fail 'the host supervisor is stopped'
    return
  fi
  missing="$(stopped_services)"
  # runsv starts a service a moment after it was down, so a health run right
  # after a restart would report a failure that fixes itself.
  if [ -n "${missing}" ]; then
    sleep 5
    missing="$(stopped_services)"
  fi
  if [ -n "${missing}" ]; then
    report host fail "not running:${missing}"
  else
    report host ok 'every host service runs'
  fi
}

#######################################
# Run every check and report the summary.
#######################################
main() {
  require_busybox
  check_image
  check_address
  check_rules
  check_iptables
  check_proxy
  check_docker
  check_wan
  check_host_services
  if [ "${FAILED}" -gt 0 ]; then
    err "health: ${FAILED} check(s) failed"
    exit 1
  fi
  log 'health: every check passed'
}

main "$@"
