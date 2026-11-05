#!/system/bin/sh
# AT-12: Layer 1 sees its own root, not Android.
. "${AT_DIR}/lib.sh"

require_l1
assert 'no /data inside Layer 1' l1_lacks /data
assert 'no /system inside Layer 1' l1_lacks /system
assert 'the previous root is empty' l1_runs 'test -z "$(ls -A /.oldroot 2>/dev/null)"'
assert 'the previous root is not mounted' l1_fails 'mount | grep -q .oldroot'
assert 'the image root holds /etc/alpine-release' l1_has /etc/alpine-release
ps_out="$(in_l1 ps -o pid,args 2>/dev/null)"
# Layer 1 shares the PID namespace with Android by design: containerd 2.x
# cannot start inside a child PID namespace on kernel 4.14.
show 'pid namespace' 'shared with Android' 
show 'processes' "$(echo "${ps_out}" | wc -l)"
