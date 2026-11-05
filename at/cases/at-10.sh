#!/system/bin/sh
# AT-10: the Layer 0 transport exists.
. "${AT_DIR}/lib.sh"

assert 'netns l1 exists' ip netns list \| grep -qx l1
assert 'veth0 carries 10.0.0.1/24' \
  sh -c 'ip -4 -o addr show veth0 | grep -q "10\.0\.0\.1/24"'
require_l1
addr="$(in_l1 ip -4 -o addr show eth0 2>/dev/null | awk '{ print $4 }')"
assert 'eth0 carries 10.0.0.2/24' sh -c "echo '${addr}' | grep -q '10\.0\.0\.2/24'"
show 'veth0' "$(ip -4 -o addr show veth0 | awk '{ print $4 }')"
