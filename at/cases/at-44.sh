#!/system/bin/sh
# AT-44: a killed agent does not leave a partial state.
. "${AT_DIR}/lib.sh"

require_service network
agent="$(cat /data/adb/rootfs/host-service/network/supervise/pid 2>/dev/null)"
if [ -n "${agent}" ]; then
  kill -9 "${agent}" 2>/dev/null
fi
sleep 6
assert 'the agent is running again' \
  sh -c '"/data/adb/rootfs/bin/sv" status "/data/adb/rootfs/host-service/network" 2>/dev/null | grep -q "^run:"'
assert 'the rules are present' sh -c 'ip rule show | grep -q "^8900:"'
assert 'Layer 1 runs' l1_pid
