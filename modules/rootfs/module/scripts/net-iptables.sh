#!/system/bin/sh
#
# The Layer 0 iptables objects. Android's iptables has the vendor quota2
# match built in, so it can replay the vendor tables. Alpine's iptables
# cannot, which is why the agent calls this script on the Android side.
# Usage: apply|remove|test.

VETH_L0='veth0'
L1_ADDR='10.0.0.2'
L1_PREFIX='10.0.0.0/24'
readonly L1_ADDR L1_PREFIX VETH_L0

#######################################
# Run iptables with the given arguments.
#######################################
ipt() {
  iptables -w "$@"
}

#######################################
# Add a jump to a chain when it is absent.
# Arguments:
#   Table, built-in chain, and the rule after the jump target.
#######################################
hook() {
  local table="${1}" chain="${2}"
  shift 2
  if ! ipt -t "${table}" -C "${chain}" "$@" 2>/dev/null; then
    ipt -t "${table}" -I "${chain}" 1 "$@"
  fi
}

#######################################
# Create the probe chain, list it, and delete it. A failure here blocks the
# DNAT objects, but not the start of Layer 1.
#######################################
selftest() {
  ipt -N PHOENIXD_PROBE || return 1
  ipt -n -L PHOENIXD_PROBE >/dev/null || return 1
  ipt -X PHOENIXD_PROBE
}

#######################################
# Remove the v1 leftovers: the docker0 bridge and its MASQUERADE rules. Layer
# 1 owns its own bridge inside its netns, so the host has no docker0.
#######################################
clean_stale_docker() {
  while ipt -t nat -D POSTROUTING -o docker0 -j MASQUERADE 2>/dev/null; do
    :
  done
  ip link delete docker0 2>/dev/null
  return 0
}

#######################################
# Create or repair every object. Each chain is flushed first, because this
# module owns the chains and never touches a foreign one.
#######################################
apply_objects() {
  selftest || return 1
  clean_stale_docker
  ipt -t nat -N PHOENIXD_DNAT 2>/dev/null
  ipt -t nat -F PHOENIXD_DNAT 2>/dev/null || return 1
  ipt -t nat -A PHOENIXD_DNAT -d "${L1_PREFIX}" -j RETURN || return 1
  ipt -t nat -A PHOENIXD_DNAT -m addrtype --dst-type LOCAL \
    -j DNAT --to-destination "${L1_ADDR}" || return 1
  hook nat PREROUTING -i wlan0 -j PHOENIXD_DNAT || return 1
  ipt -t nat -N PHOENIXD_NAT 2>/dev/null
  ipt -t nat -F PHOENIXD_NAT 2>/dev/null || return 1
  if ! ipt -t nat -A PHOENIXD_NAT -s "${L1_PREFIX}" -o wlan0 -j MASQUERADE; then
    return 1
  fi
  # The proxy path leaves through tun0, and the kernel rejects a forwarded
  # packet whose source is not routable on that device, so the source is
  # translated before the tunnel as well.
  if ! ipt -t nat -A PHOENIXD_NAT -s "${L1_PREFIX}" -o tun+ -j MASQUERADE; then
    return 1
  fi
  hook nat POSTROUTING -j PHOENIXD_NAT || return 1
  ipt -N PHOENIXD_FWD 2>/dev/null
  ipt -F PHOENIXD_FWD 2>/dev/null || return 1
  ipt -A PHOENIXD_FWD -i "${VETH_L0}" -o wlan0 -j ACCEPT || return 1
  ipt -A PHOENIXD_FWD -i wlan0 -o "${VETH_L0}" -j ACCEPT || return 1
  # The proxy path leaves through tun0, so it needs its own accept.
  ipt -A PHOENIXD_FWD -i "${VETH_L0}" -o tun+ -j ACCEPT || return 1
  ipt -A PHOENIXD_FWD -i tun+ -o "${VETH_L0}" -j ACCEPT || return 1
  hook filter FORWARD -j PHOENIXD_FWD || return 1
  hook mangle FORWARD -o wlan0 -p tcp --tcp-flags SYN,RST SYN \
    -j TCPMSS --clamp-mss-to-pmtu || return 1
}

#######################################
# Remove the hooks and the chains. Every step is best effort: a foreign
# object is never flushed.
#######################################
remove_objects() {
  ipt -t nat -D PREROUTING -i wlan0 -j PHOENIXD_DNAT 2>/dev/null
  ipt -t nat -D POSTROUTING -j PHOENIXD_NAT 2>/dev/null
  ipt -D FORWARD -j PHOENIXD_FWD 2>/dev/null
  ipt -t mangle -D FORWARD -o wlan0 -p tcp --tcp-flags SYN,RST SYN \
    -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null
  ipt -t nat -F PHOENIXD_DNAT 2>/dev/null
  ipt -t nat -X PHOENIXD_DNAT 2>/dev/null
  ipt -t nat -F PHOENIXD_NAT 2>/dev/null
  ipt -t nat -X PHOENIXD_NAT 2>/dev/null
  ipt -F PHOENIXD_FWD 2>/dev/null
  ipt -X PHOENIXD_FWD 2>/dev/null
  return 0
}

#######################################
# Dispatch the command line arguments.
#######################################
main() {
  case "${1:-}" in
    apply) apply_objects ;;
    remove) remove_objects ;;
    test) selftest ;;
    *)
      echo "usage: $0 apply|remove|test" >&2
      exit 1
      ;;
  esac
}

main "$@"
