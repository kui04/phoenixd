#!/system/bin/sh
#
# Converges the Layer 0 network objects that Layer 1 needs: the named network
# namespace, the veth pair, table 9500, its three rules, and a mirror of the
# WAN default route. It uses ip only; the iptables objects arrive in phase 2.
#
# Commands: converge, down, sync, status. Every create, repair, and remove
# step is idempotent, and converge, down, and sync share one lock.

MODDIR="$(cd "${0%/*}/.." && pwd)"
readonly MODDIR
. "${MODDIR}/scripts/common.sh"

VETH_L0='veth0'
L0_ADDR='10.0.0.1/24'
L1_LINK='eth0'
L1_PREFIX='10.0.0.0/24'
TABLE='9500'
PREF_PREFIX='8900'
PREF_PRIVATE='8950 8951 8952'
PREF_EGRESS='9500'
PREF_OUTPUT='9501'
readonly L0_ADDR L1_LINK L1_PREFIX PREF_EGRESS PREF_OUTPUT PREF_PREFIX
readonly PREF_PRIVATE
readonly TABLE VETH_L0
NETWORK_STATE="${ROOTFS_HOME}/state/network"
NET_LOCK="${RUN_DIR}/net.lock.d"
# converge and down finish in seconds; a longer wait means a stuck caller.
NET_LOCK_WAIT=30
readonly NET_LOCK NET_LOCK_WAIT NETWORK_STATE

#######################################
# Check whether the named network namespace exists. ip netns list prints the
# file names in /mnt/run only, so a file without its nsfs mount counts.
#######################################
netns_exists() {
  "${IP}" netns list 2>/dev/null | awk '{ print $1 }' | grep -qx "${NETNS}"
}

#######################################
# Print the nsfs mounts of the namespace file. Android's iproute2 keeps the
# namespace in /mnt/run/<name>, and the shared /mnt/run mount also holds a
# propagated copy under /mnt, so one live namespace gives two lines.
#######################################
netns_mounts() {
  awk -v path="${NETNS_FILE}" '$5 == path { print }' /proc/self/mountinfo \
    2>/dev/null
}

#######################################
# Check whether the namespace is usable: the file must carry an nsfs mount.
# A file without the mount is a partial create, and ip link set ... netns
# fails with "RTNETLINK answers: Invalid argument" on it.
#######################################
netns_ready() {
  netns_exists || return 1
  [ -n "$(netns_mounts)" ]
}

#######################################
# Check whether a link exists in the Layer 1 network namespace.
# Arguments:
#   Link name.
#######################################
l1_link_exists() {
  "${IP}" netns exec "${NETNS}" "${IP}" link show "${1}" >/dev/null 2>&1
}

#######################################
# Exit unless the ip binary manages network namespaces. BusyBox ships an ip
# applet without netns, and its usage text is the only symptom of a wrong one.
#######################################
require_netns() {
  "${IP}" netns list >/dev/null 2>&1 \
    || die "${IP} has no netns support"
}

#######################################
# Create the named network namespace. A file without its nsfs mount blocks
# ip netns add with "File exists" and fails every later converge, so it is
# removed first; ip netns delete unmounts before it unlinks, which keeps no
# mount behind.
#######################################
ensure_netns() {
  if netns_ready; then
    return 0
  fi
  if l1_running; then
    err 'Layer 1 runs, but its netns is not mounted: rootfs-service restart'
    return 1
  fi
  if netns_exists; then
    "${IP}" netns delete "${NETNS}" 2>/dev/null
  fi
  mkdir -p "$(dirname "${NETNS_FILE}")"
  "${IP}" netns add "${NETNS}"
}

#######################################
# Create the veth pair and move the peer into the namespace as eth0. A pair
# that lost one end is deleted and rebuilt. A failed attempt leaves the pair
# behind, and that pair makes every further add fail with "File exists", so
# each attempt starts from a clean pair.
#######################################
ensure_veth() {
  local count=0
  if "${IP}" link show "${VETH_L0}" >/dev/null 2>&1 \
    && l1_link_exists "${L1_LINK}"; then
    return 0
  fi
  if l1_running; then
    err 'Layer 1 runs, but its eth0 is missing: rootfs-service restart'
    return 1
  fi
  while [ "${count}" -lt 5 ]; do
    "${IP}" link delete "${VETH_L0}" 2>/dev/null
    if "${IP}" link add "${VETH_L0}" type veth peer name veth1 \
      && "${IP}" link set veth1 netns "${NETNS}" \
      && "${IP}" netns exec "${NETNS}" \
      "${IP}" link set veth1 name "${L1_LINK}"; then
      return 0
    fi
    count=$(( count + 1 ))
    sleep 1
  done
  "${IP}" link delete "${VETH_L0}" 2>/dev/null
  return 1
}

#######################################
# Bring up both ends of the pair and set the Layer 0 address. The Layer 1
# address belongs to the interfaces file in the image, so this function does
# not set it.
#######################################
configure_links() {
  "${IP}" link set lo up
  "${IP}" link set "${VETH_L0}" mtu 1500 || return 1
  "${IP}" addr replace "${L0_ADDR}" dev "${VETH_L0}" || return 1
  "${IP}" link set "${VETH_L0}" up
  "${IP}" netns exec "${NETNS}" "${IP}" link set lo up || return 1
  "${IP}" netns exec "${NETNS}" \
    "${IP}" link set "${L1_LINK}" mtu 1500 || return 1
  "${IP}" netns exec "${NETNS}" "${IP}" link set "${L1_LINK}" up
}

#######################################
# Print the text of the rule at a preference, when one exists.
# Arguments:
#   Preference.
#######################################
rule_text() {
  "${IP}" rule show 2>/dev/null \
    | sed -n "s/^${1}:[\t ]*//p" \
    | sed -e 's/[[:space:]]*$//'
}

#######################################
# Install the rule when its preference is free. When a rule exists, every
# word of the selector must appear in it: iproute2 reorders the selectors, so
# a text comparison fails on the second converge.
# Arguments:
#   Preference and the rule arguments for ip rule add.
#######################################
ensure_rule() {
  local current pref="${1}" word
  shift
  current="$(rule_text "${pref}")"
  if [ -z "${current}" ]; then
    "${IP}" rule add pref "${pref}" "$@" || return 1
    return 0
  fi
  for word in "$@"; do
    case " ${current} " in
      *" ${word} "*) ;;
      *)
        err "a foreign rule occupies pref ${pref}: ${current}"
        return 1
        ;;
    esac
  done
  return 0
}

#######################################
# Print the WAN default route: "<gateway> <device>". A route in the main
# table wins. Android keeps the route in a per-network table when netd owns
# the interface.
# Returns:
#   0 and prints the route fields, 1 when the WAN has no default route.
#######################################
wan_default() {
  local line gateway device
  # /proc/net/route is stable across kernels and tools: the destination
  # 00000000 is the default route, and the gateway is little-endian hex.
  line="$(awk '
    function hexval(c) { return index("0123456789ABCDEF", toupper(c)) - 1 }
    $2 == "00000000" && $1 == "wlan0" {
      g = $3
      printf "%d.%d.%d.%d %s\n",
        hexval(substr(g, 7, 1)) * 16 + hexval(substr(g, 8, 1)),
        hexval(substr(g, 5, 1)) * 16 + hexval(substr(g, 6, 1)),
        hexval(substr(g, 3, 1)) * 16 + hexval(substr(g, 4, 1)),
        hexval(substr(g, 1, 1)) * 16 + hexval(substr(g, 2, 1)),
        $1
      found = 1
      exit
    }
    END { exit(found ? 0 : 1) }
  ' /proc/net/route 2>/dev/null)"
  if [ -n "${line}" ]; then
    echo "${line}"
    return 0
  fi
  line="$("${IP}" route show default 2>/dev/null |
    grep ' dev wlan0' |
    head -n 1)"
  if [ -z "${line}" ]; then
    line="$("${IP}" route show table all 2>/dev/null |
      grep '^default' |
      grep ' dev wlan0' |
      grep -v 'table 9500' |
      head -n 1)"
  fi
  [ -n "${line}" ] || return 1
  device="${line#* dev }"
  device="${device%% *}"
  gateway=''
  case "${line}" in
    *' via '*)
      gateway="${line#* via }"
      gateway="${gateway%% *}"
      ;;
  esac
  [ -n "${gateway}" ] || return 1
  echo "${gateway} ${device}"
}

#######################################
# Copy the WAN default route into table 9500, or remove the mirror when the
# WAN has none. Without the mirror, Layer 1 fails fast with ENETUNREACH
# instead of sending its traffic into a black hole.
#######################################
mirror_wan() {
  local wan gateway device
  if ! wan="$(wan_default)"; then
    "${IP}" route del default table "${TABLE}" 2>/dev/null
    return 0
  fi
  gateway="${wan%% *}"
  device="${wan#* }"
  "${IP}" route replace default via "${gateway}" dev "${device}" onlink \
    table "${TABLE}"
}

#######################################
# Save the forwarding setting once, then enable forwarding.
#######################################
enable_forwarding() {
  local file="${RUN_DIR}/ip_forward"
  mkdir -p "${RUN_DIR}"
  if [ ! -f "${file}" ]; then
    cat /proc/sys/net/ipv4/ip_forward >"${file}"
  fi
  echo 1 >/proc/sys/net/ipv4/ip_forward
}

#######################################
# Restore the forwarding setting that enable_forwarding saved.
#######################################
restore_forwarding() {
  local file="${RUN_DIR}/ip_forward"
  [ -f "${file}" ] || return 0
  cat "${file}" >/proc/sys/net/ipv4/ip_forward
  rm -f "${file}"
}

#######################################
# Point the private ranges at the main table, as v1 did. A reply to a host on
# the LAN needs the connected route of wlan0, and table 9500 has only the
# mirrored default route, so the reply would leave through the gateway and
# never arrive. Pref 8900 covers the Layer 1 prefix before these rules.
#######################################
ensure_private_rules() {
  local prefs="${PREF_PRIVATE}" pref index
  index=0
  for pref in ${prefs}; do
    case "${index}" in
      0) prefix='192.168.0.0/16' ;;
      1) prefix='172.16.0.0/12' ;;
      *) prefix='10.0.0.0/8' ;;
    esac
    if ! ensure_rule "${pref}" to "${prefix}" lookup main; then
      return 1
    fi
    index=$(( index + 1 ))
  done
}

#######################################
# Remove the private-range rules.
#######################################
remove_private_rules() {
  local pref
  for pref in ${PREF_PRIVATE}; do
    remove_rule "${pref}" main
  done
}

#######################################
# Run the iptables objects of phase 2. A failure blocks the NAT and DNAT
# objects, not the start of Layer 1.
# Arguments:
#   apply, remove, or test.
# Globals:
#   MODDIR
#######################################
phase2() {
  if ! sh "${MODDIR}/scripts/net-iptables.sh" "${1}"; then
    err "the iptables objects failed: ${1}"
    return 1
  fi
}

#######################################
# Take the network lock. control.sh and the network agent both converge and
# remove the same kernel objects, and without the lock one caller's create
# lands between another caller's check and its create: the loser then reads
# "Cannot create namespace file ... File exists" or "RTNETLINK answers:
# Invalid argument" and deletes the objects that the winner just built.
# A directory is the lock because BusyBox flock needs an open descriptor.
# Globals:
#   NET_LOCK
#   NET_LOCK_WAIT
# Returns:
#   0 when the lock is held, 1 after NET_LOCK_WAIT seconds.
#######################################
lock_network() {
  local count=0 holder=''
  mkdir -p "${RUN_DIR}"
  while [ "${count}" -lt "${NET_LOCK_WAIT}" ]; do
    if mkdir "${NET_LOCK}" 2>/dev/null; then
      printf '%s\n' "$$" >"${NET_LOCK}/pid"
      return 0
    fi
    holder="$(cat "${NET_LOCK}/pid" 2>/dev/null)"
    if [ -n "${holder}" ] && ! kill -0 "${holder}" 2>/dev/null; then
      # The holder died before its exit trap could release the lock.
      rm -rf "${NET_LOCK}"
      holder=''
    fi
    sleep 1
    count=$(( count + 1 ))
  done
  err "the network lock is held by pid ${holder:-unknown}"
  return 1
}

#######################################
# Release the network lock.
# Globals:
#   NET_LOCK
#######################################
unlock_network() {
  rm -rf "${NET_LOCK}"
}

#######################################
# Assert every object of phase 1 and repair what is missing.
#######################################
converge() {
  require_busybox
  require_netns
  ensure_netns || die "cannot create the netns ${NETNS}"
  ensure_veth || die 'cannot create the veth pair'
  configure_links || die 'cannot configure the veth pair'
  "${IP}" route replace "${L1_PREFIX}" dev "${VETH_L0}" scope link \
    table "${TABLE}" || die 'cannot add the Layer 1 prefix route'
  if ! ensure_rule "${PREF_PREFIX}" \
    to "${L1_PREFIX}" lookup "${TABLE}"; then
    die "cannot install the rule at pref ${PREF_PREFIX}"
  fi
  ensure_private_rules || die 'cannot install the private-range rules'
  if ! ensure_rule "${PREF_EGRESS}" \
    iif "${VETH_L0}" lookup "${TABLE}"; then
    die "cannot install the rule at pref ${PREF_EGRESS}"
  fi
  if ! ensure_rule "${PREF_OUTPUT}" \
    iif lo fwmark 0x0/0xffff lookup "${TABLE}"; then
    die "cannot install the rule at pref ${PREF_OUTPUT}"
  fi
  mirror_wan || die 'cannot mirror the WAN default route'
  enable_forwarding || die 'cannot enable IPv4 forwarding'
  phase2 apply || true
}

#######################################
# Remove a rule at a preference when this module installed it.
# Arguments:
#   Preference.
#######################################
remove_rule() {
  local pref="${1}" table="${2:-${TABLE}}" current
  current="$(rule_text "${pref}")"
  case "${current}" in
    *"lookup ${table}") "${IP}" rule del pref "${pref}" 2>/dev/null ;;
    '') ;;
    *) err "leaving a foreign rule at pref ${pref}: ${current}" ;;
  esac
}

#######################################
# Remove every object that converge installs.
#######################################
remove_all() {
  phase2 remove || true
  remove_private_rules
  remove_rule "${PREF_OUTPUT}"
  remove_rule "${PREF_EGRESS}"
  remove_rule "${PREF_PREFIX}"
  "${IP}" route flush table "${TABLE}" 2>/dev/null
  "${IP}" link delete "${VETH_L0}" 2>/dev/null
  if netns_exists; then
    "${IP}" netns delete "${NETNS}" 2>/dev/null
  fi
  restore_forwarding
}

#######################################
# Converge or remove the objects according to the desired state. The state
# is read under the lock, so a stop cannot remove the objects that a
# concurrent start converges, and the agent never acts on a stale state.
#######################################
sync_state() {
  case "$(cat "${NETWORK_STATE}" 2>/dev/null)" in
    up) converge ;;
    down) remove_all ;;
    *) err "no network state in ${NETWORK_STATE}" ;;
  esac
}

#######################################
# Print the state of the Layer 0 objects.
#######################################
show_status() {
  local address pref routes wan
  if netns_exists; then
    log "netns: ${NETNS}"
  else
    log 'netns: missing'
  fi
  address="$("${IP}" -4 -o addr show "${VETH_L0}" 2>/dev/null \
    | awk '{ print $4 }')"
  log "veth: ${VETH_L0} ${address}"
  for pref in "${PREF_PREFIX}" ${PREF_PRIVATE} "${PREF_EGRESS}" \
    "${PREF_OUTPUT}"; do
    log "rule ${pref}: $(rule_text "${pref}")"
  done
  if wan="$(wan_default)"; then
    log "wan: ${wan}"
  else
    log 'wan: no default route'
  fi
  routes="$("${IP}" route show table "${TABLE}" 2>/dev/null | tr '\n' ' ')"
  log "table ${TABLE}: ${routes}"
  # Proxy checks: a violation is reported, never repaired here.
  if ip -o link show tun0 >/dev/null 2>&1; then
    log 'proxy: tun0 is up'
  else
    log 'proxy: tun0 is absent'
  fi
  if "${IP}" rule show 2>/dev/null \
    | awk -F: '$1 >= 8900 && $1 <= 9600' \
    | grep -q suppress_prefixlength; then
    log 'proxy: a suppress_prefixlength rule shadows the routing rules'
  fi
  if "${IP}" route show table 2022 2>/dev/null | grep -q '^10\.0\.0\.0/24'; then
    log 'proxy: table 2022 routes the Layer 1 prefix through the proxy'
  fi
  log "iptables: $(iptables-save 2>/dev/null | grep -c PHOENIXD) rules"
}

#######################################
# Print the command usage.
#######################################
usage() {
  err "usage: $0 converge|down|sync|status"
  exit 1
}

#######################################
# Dispatch the command line arguments.
#######################################
main() {
  case "${1:-}" in
    converge)
      require_busybox
      lock_network || exit 1
      trap 'unlock_network' 0
      converge
      ;;
    down)
      require_busybox
      lock_network || exit 1
      trap 'unlock_network' 0
      remove_all
      ;;
    sync)
      require_busybox
      lock_network || exit 1
      trap 'unlock_network' 0
      sync_state
      ;;
    status) show_status ;;
    *) usage ;;
  esac
}

main "$@"
