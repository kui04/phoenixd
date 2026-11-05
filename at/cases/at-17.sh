#!/system/bin/sh
# AT-17: the OpenRC boot runlevel and the net service.
. "${AT_DIR}/lib.sh"

require_l1
# The previous case may restart Layer 1, so wait for the boot runlevel.
count=0
while [ "${count}" -lt 30 ]; do
  boot="$(in_l1 rc-status boot 2>/dev/null)"
  echo "${boot}" | grep -q 'net.*started' && break
  sleep 2
  count=$(( count + 2 ))
done
assert 'loopback started' sh -c "echo '${boot}' | grep -q 'loopback.*started'"
assert 'net started' sh -c "echo '${boot}' | grep -q 'net.*started'"
net="$(in_l1 rc-service net status 2>&1)"
assert 'net service reports started' sh -c "echo '${net}' | grep -q started"
show 'rc-status' "$(echo "${boot}" | tr '\n' ' ')"
