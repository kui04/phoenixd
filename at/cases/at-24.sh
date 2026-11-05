#!/system/bin/sh
# AT-24: Layer 1 egress, with or without the proxy.
. "${AT_DIR}/lib.sh"

require_l1
# The proxy restarts itself when its rules are missing, so retry briefly.
reachable() {
  local count=0
  while [ "${count}" -lt 4 ]; do
    if in_l1 ping -c 1 -W 3 1.1.1.1 >/dev/null 2>&1; then
      return 0
    fi
    sleep 3
    count=$(( count + 1 ))
  done
  return 1
}
assert 'icmp to 1.1.1.1' reachable
http=''
count=0
while [ "${count}" -lt 8 ]; do
  http="$(in_l1 sh -c 'wget -S -O /dev/null http://1.1.1.1/ 2>&1' 2>&1)"
  echo "${http}" | grep -q 'HTTP/' && break
  sleep 5
  count=$(( count + 1 ))
done
if echo "${http}" | grep -q 'HTTP/'; then
  show 'tcp path' 'through the proxy'
  assert 'tcp to 1.1.1.1:80' true
else
  # The proxy can restart while its rules are re-created. The documented
  # behaviour is fail-open through table 9500, which must carry TCP too.
  singbox-service stop >/dev/null 2>&1
  sleep 3
  count=0
  while [ "${count}" -lt 8 ]; do
    http="$(in_l1 sh -c 'wget -S -O /dev/null http://1.1.1.1/ 2>&1' 2>&1)"
    echo "${http}" | grep -q 'HTTP/' && break
    sleep 5
    count=$(( count + 1 ))
  done
  singbox-service start >/dev/null 2>&1
  show 'tcp path' 'fail-open through table 9500'
  assert 'tcp to 1.1.1.1:80 on the fail-open path' \
    sh -c "echo '${http}' | grep -q HTTP"
fi
show 'route 1.1.1.1' "$(in_l1 ip route get 1.1.1.1 2>/dev/null | head -n 1)"
