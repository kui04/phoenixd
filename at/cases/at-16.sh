#!/system/bin/sh
# AT-16: the reboot guard stops the services, and the phone stays up.
. "${AT_DIR}/lib.sh"

require_l1
in_l1 /sbin/reboot >/dev/null 2>&1
sleep 4
# The guard stops the services and the supervisor. Without an init process
# there is nothing left to keep Layer 1 alive, and the phone stays up.
assert 'Layer 1 reports stopped' \
  sh -c 'rootfs-service status 2>/dev/null | grep -q "layer 1: stopped"'
assert 'the phone still answers adb' sh -c 'test "$(getprop sys.boot_completed)" = 1'
rootfs-service restart >/dev/null 2>&1 &
count=0
while [ "${count}" -lt 60 ]; do
  rootfs-service status 2>/dev/null | grep -q 'layer 1: running' && break
  sleep 3
  count=$(( count + 3 ))
done
# Later cases need the net service, so wait for it here instead of letting
# them skip.
count=0
while [ "${count}" -lt 90 ]; do
  l1_runs 'rc-service net status 2>/dev/null | grep -q started' && break
  sleep 3
  count=$(( count + 3 ))
done
assert 'Layer 1 starts again' l1_pid
