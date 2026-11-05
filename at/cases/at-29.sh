#!/system/bin/sh
# AT-29: the forwarder answers A, drops AAAA, and refuses the LAN.
. "${AT_DIR}/lib.sh"

require_l1
require_service dns
a="$(in_l1 nslookup alpinelinux.org 2>&1)"
assert 'A record resolves inside Layer 1' \
  sh -c "echo '${a}' | grep -q 'Address:'"
aaaa="$(in_l1 nslookup -type=AAAA alpinelinux.org 10.0.0.1 2>&1)"
assert 'AAAA has no address' \
  sh -c "! echo '${aaaa}' | grep -q 'Address: [0-9a-f]*:'"
assert 'the forwarder is bound to 10.0.0.1 only' \
  sh -c '! (ss -uln 2>/dev/null || netstat -uln 2>/dev/null) | grep -q "0.0.0.0:53"'
