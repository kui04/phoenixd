#!/system/bin/sh
# AT-22: the route to the Layer 1 address.
. "${AT_DIR}/lib.sh"

require_l1
out="$(ip route get 10.0.0.2 2>&1 | head -n 1)"
assert 'route uses veth0 and table 9500' \
  sh -c "echo '${out}' | grep -q 'veth0' && echo '${out}' | grep -q 'table 9500'"
show 'route' "${out}"
