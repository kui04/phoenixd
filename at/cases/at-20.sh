#!/system/bin/sh
# AT-20: the routing rules and their order.
. "${AT_DIR}/lib.sh"

for pref in 8900 8950 8951 8952 9000 9001 9500 9501; do
  assert "rule ${pref} exists" sh -c "ip rule show | grep -q '^${pref}:'"
done
assert 'no suppress_prefixlength in 8900..9600' \
  sh -c '! ip rule show | awk -F: "\$1 >= 8900 && \$1 <= 9600" | grep -q suppress_prefixlength'
assert 'no foreign rule at 8900' sh -c 'ip rule show | grep "^8900:" | grep -q "lookup 9500"'
