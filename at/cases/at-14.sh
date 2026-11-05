#!/system/bin/sh
# AT-14: the cgroup v1 view is readable.
. "${AT_DIR}/lib.sh"

require_l1
limit="$(in_l1 cat /sys/fs/cgroup/memory/memory.limit_in_bytes 2>/dev/null)"
assert 'memory.limit_in_bytes is readable' test -n "${limit}"
assert 'a pids child cgroup has pids.max' \
  in_l1 sh -c 'mkdir -p /sys/fs/cgroup/pids/at &&
    cat /sys/fs/cgroup/pids/at/pids.max >/dev/null &&
    rmdir /sys/fs/cgroup/pids/at'
show 'memory limit' "${limit}"
