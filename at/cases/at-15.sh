#!/system/bin/sh
# AT-15: no zombie survives inside Layer 1.
. "${AT_DIR}/lib.sh"

require_l1
in_l1 sh -c 'sh -c "true &"; sleep 1'
zombies="$(in_l1 ps -o stat,args 2>/dev/null | grep -c '^ *Z')"
assert 'no zombie process' sh -c "[ ${zombies} -eq 0 ]"
