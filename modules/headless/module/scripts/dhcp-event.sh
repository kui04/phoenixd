#!/system/bin/sh
#
# udhcpc event script.

MODDIR="$(cd "${0%/*}/.." && pwd)"
readonly MODDIR
. "${MODDIR}/scripts/common.sh"

# udhcpc sets interface, ip, mask and router.
main() {
  case "${1:-}" in
    bound | renew)
      ip addr replace "${ip}/${mask}" dev "${interface}"
      if [ -n "${router:-}" ]; then
        ip route replace default via "${router%% *}" dev "${interface}" onlink
      fi
      sh "${MODDIR}/scripts/net.sh" add
      log "lease ${ip}/${mask} via ${router:-none}"
      ;;
    deconfig)
      ip addr flush dev "${interface}"
      ;;
  esac
}

main "$@"
