#!/system/bin/sh
# AT-53: the backup refuses while Layer 1 runs.
. "${AT_DIR}/lib.sh"

require_l1
assert 'backup refuses while Layer 1 runs' \
  sh -c 'rootfs-service image backup /data/local/tmp/at-should-not-exist.gz 2>&1 | grep -q "Layer 1 is running"'
assert 'no partial backup' test ! -e /data/local/tmp/at-should-not-exist.gz
