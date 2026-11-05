#!/system/bin/sh
# Minimal udhcpc event handler for wlan0. udhcpc sets interface, ip, mask,
# subnet, router, and dns.
case "${1:-}" in
  deconfig)
    ip addr flush dev "${interface}"
    ;;
  bound | renew)
    ip addr replace "${ip}/${mask}" dev "${interface}"
    if [ -n "${router:-}" ]; then
      ip route replace default via "${router%% *}" dev "${interface}" onlink
    fi
    for server in ${dns:-}; do
      echo "nameserver ${server}"
    done >/data/adb/headless/resolv.conf
    ;;
esac
