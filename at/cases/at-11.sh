#!/system/bin/sh
# AT-11: a second start changes nothing.
. "${AT_DIR}/lib.sh"

require_l1
before="$(ip rule show)"
out="$(rootfs-service start 2>&1)"
assert 'second start reports that Layer 1 runs' \
  sh -c "echo '${out}' | grep -q 'already runs'"
assert 'rules are unchanged' sh -c "[ \"\$(ip rule show)\" = \"\$(echo '${before}')\" ]"
