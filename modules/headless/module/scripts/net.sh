#!/system/bin/sh
#
# Adds or removes the routing and firewall rules that let containers reach the
# network without Android netd. Usage: net.sh add|del

MODDIR="$(cd "${0%/*}/.." && pwd)"
readonly MODDIR
. "${MODDIR}/scripts/common.sh"

#######################################
# Run an iptables rule action, checking first so that add is idempotent.
# Arguments:
#   Table, chain, position (A or I), then the rule arguments.
#######################################
ensure_rule() {
  local table="$1" chain="$2" mode="$3"
  shift 3
  iptables -t "${table}" -C "${chain}" "$@" 2>/dev/null && return 0
  case "${mode}" in
    I) iptables -t "${table}" -I "${chain}" 1 "$@" ;;
    *) iptables -t "${table}" -A "${chain}" "$@" ;;
  esac
}

#######################################
# Add the policy rule, NAT and forward rules.
# Globals:
#   DOCKER_BRIDGE
#   DOCKER_SUBNET
#   RULE_PREF
#######################################
add_rules() {
  ip rule show | grep -q "^${RULE_PREF}:" \
    || ip rule add pref "${RULE_PREF}" lookup main
  ensure_rule nat POSTROUTING A \
    -s "${DOCKER_SUBNET}" ! -o "${DOCKER_BRIDGE}" -j MASQUERADE
  ensure_rule filter FORWARD I -i "${DOCKER_BRIDGE}" -j ACCEPT
  ensure_rule filter FORWARD I -o "${DOCKER_BRIDGE}" -j ACCEPT
}

#######################################
# Remove every rule that add_rules created.
#######################################
del_rules() {
  while ip rule show | grep -q "^${RULE_PREF}:"; do
    ip rule del pref "${RULE_PREF}" || break
  done
  iptables -t nat -D POSTROUTING \
    -s "${DOCKER_SUBNET}" ! -o "${DOCKER_BRIDGE}" -j MASQUERADE 2>/dev/null
  iptables -D FORWARD -i "${DOCKER_BRIDGE}" -j ACCEPT 2>/dev/null
  iptables -D FORWARD -o "${DOCKER_BRIDGE}" -j ACCEPT 2>/dev/null
  return 0
}

main() {
  case "${1:-}" in
    add) add_rules ;;
    del) del_rules ;;
    *)
      echo "usage: $0 {add|del}" >&2
      exit 1
      ;;
  esac
}

main "$@"
