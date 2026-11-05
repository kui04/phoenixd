#!/system/bin/sh
# AT-45: a stopped Layer 1 is reported, and a start converges.
#
# An unclean kill is not covered here: containerd 2.x keeps task state that
# only a phone reboot clears, so a killed Layer 1 leaves Docker down.
. "${AT_DIR}/lib.sh"

require_l1
rootfs-service stop >/dev/null 2>&1
sleep 4
assert 'the state reports Layer 1 down' \
  sh -c 'rootfs-service status 2>/dev/null | grep -q "layer 1: stopped"'
rootfs-service start >/dev/null 2>&1
count=0
while [ "${count}" -lt 90 ]; do
  rootfs-service status 2>/dev/null | grep -q 'layer 1: running' && break
  sleep 3
  count=$(( count + 3 ))
done
# One more start when the first one raced with the dying namespace.
rootfs-service status 2>/dev/null | grep -q 'layer 1: running' ||
  rootfs-service start >/dev/null 2>&1
count=0
while [ "${count}" -lt 90 ]; do
  l1_pid >/dev/null && break
  sleep 3
  count=$(( count + 3 ))
done
assert 'Layer 1 starts again' l1_pid
# The address is covered by at-10; this case asserts that a clean stop and a
# start converge on a running Layer 1 with its net service.
count=0
while [ "${count}" -lt 90 ]; do
  l1_runs 'rc-service net status 2>/dev/null | grep -q started' && break
  sleep 3
  count=$(( count + 3 ))
done
assert 'the net service is started' \
  l1_runs 'rc-service net status 2>/dev/null | grep -q started'
