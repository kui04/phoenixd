#!/system/bin/sh
# AT-23: a published port is reachable from a second LAN host, and an
# unpublished port is refused. This case can only run from the host side, so
# it checks the objects and reports the probe as a skip.
. "${AT_DIR}/lib.sh"

require_l1
assert 'the DNAT object exists' sh -c 'iptables-save -t nat | grep -q PHOENIXD_DNAT'
assert 'the forward accept exists' sh -c 'iptables-save | grep -q "PHOENIXD_FWD"'
# The daemon of a restarted Layer 1 needs its time: wait for it before the
# container is touched.
count=0
while [ "${count}" -lt 90 ]; do
  in_l1 docker info >/dev/null 2>&1 && break
  sleep 3
  count=$(( count + 3 ))
done

# The restarts of the earlier cases can leave the container stopped or gone,
# so a published container is ensured here.
in_l1 docker start phx-nginx >/dev/null 2>&1
if ! in_l1 docker ps --format '{{.Names}}' 2>/dev/null | grep -qx phx-nginx; then
  in_l1 docker rm -f phx-nginx >/dev/null 2>&1
  in_l1 docker run -d --name phx-nginx --restart unless-stopped \
    -p 8080:80 nginx >/dev/null 2>&1
fi
count=0
while [ "${count}" -lt 60 ]; do
  ports="$(in_l1 docker ps --format '{{.Ports}}' 2>/dev/null)"
  echo "${ports}" | grep -q '0.0.0.0:8080' && break
  sleep 2
  count=$(( count + 2 ))
done
assert 'a container publishes a port' sh -c "echo '${ports}' | grep -q '0.0.0.0:8080'"
assert 'an unused port is closed inside Layer 1' \
  in_l1 sh -c '! wget -q -O /dev/null -T 3 http://127.0.0.1:9999/ 2>/dev/null'
skip 'the LAN probe runs from the second host, see at/run.sh'
