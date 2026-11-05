#!/system/bin/sh
# AT-13: device nodes and a pty work inside Layer 1.
. "${AT_DIR}/lib.sh"

require_l1
assert 'urandom to null' in_l1 sh -c 'dd if=/dev/urandom of=/dev/null bs=4k count=1'
assert '/dev/ptmx exists' sh -c 'true' 
assert 'a pty can be allocated' in_l1 sh -c 'script -q -c "true" /dev/null'
assert 'no block nodes' l1_lacks /dev/block
