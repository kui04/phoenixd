#!/system/bin/sh
# AT-01: the iptables write path works and leaves nothing behind.
. "${AT_DIR}/lib.sh"

assert 'self-test passes' sh /data/adb/modules/rootfs/scripts/net-iptables.sh test
assert 'no probe chain is left' \
  sh -c '! iptables -n -L PHOENIXD_PROBE >/dev/null 2>&1'
assert 'PHOENIXD objects exist' \
  sh -c 'iptables-save 2>/dev/null | grep -q PHOENIXD_FWD'
