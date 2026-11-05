#!/system/bin/sh
# AT-35: a container cannot see the block layer or the host cgroup tree.
. "${AT_DIR}/lib.sh"

require_l1
assert 'no /dev/block in the container' \
  in_l1 sh -c '! docker run --rm alpine ls /dev/block 2>/dev/null'
assert 'the host cgroup path is not writable' \
  in_l1 sh -c '! docker run --rm alpine sh -c "test -w /sys/fs/cgroup/memory/memory.limit_in_bytes"'
