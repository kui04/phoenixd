#!/system/bin/sh
# AT-01N: Android's iptables can commit the filter table from the root. That
# is the property the agent depends on, because it has the vendor quota2 match
# built in; the v1 control case, where this commit failed, does not reproduce.
. "${AT_DIR}/lib.sh"

assert 'probe chain can be created' iptables -N PHX_AT_PROBE
assert 'probe chain can be listed' sh -c 'iptables -n -L PHX_AT_PROBE'
assert 'probe chain can be deleted' iptables -X PHX_AT_PROBE
assert 'no probe chain is left' sh -c '! iptables -n -L PHX_AT_PROBE >/dev/null 2>&1'
