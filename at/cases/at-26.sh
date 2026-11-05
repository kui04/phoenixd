#!/system/bin/sh
# AT-26: the agent restores a deleted FORWARD hook within two ticks.
. "${AT_DIR}/lib.sh"

require_service network
for i in 1 2 3; do
  iptables -D FORWARD -j PHOENIXD_FWD 2>/dev/null
  sleep 32
  assert "hook ${i} is back" sh -c 'iptables-save 2>/dev/null | grep -q "PHOENIXD_FWD"'
done
