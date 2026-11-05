#!/system/bin/sh
# AT-40: a headless stop touches wlan0 only.
. "${AT_DIR}/lib.sh"

require_service wifi
# Table 9500 mirrors the WAN route, which follows wlan0, so it is excluded:
# the rule set and the iptables objects must not change.
# sing-box owns 9000/9001/9010 and reinstalls them whenever the WAN route
# moves, so only the phoenixd preferences belong in the snapshot.
snapshot() {
  ip rule show | grep -E '^(8900|8950|8951|8952|9500|9501):' | cut -d: -f1
  iptables-save 2>/dev/null | grep -c PHOENIXD
}
before="$(snapshot)"
headless-service stop >/dev/null 2>&1
sleep 6
after="$(snapshot)"
assert 'rules, table 9500, and iptables are unchanged' \
  sh -c "[ \"\$(echo '${before}')\" = \"\$(echo '${after}')\" ]"
headless-service start >/dev/null 2>&1
count=0
while [ "${count}" -lt 60 ]; do
  ip -4 -o addr show wlan0 | grep -q ' inet ' && break
  sleep 3
  count=$(( count + 3 ))
done
assert 'wlan0 has an address again' \
  sh -c 'ip -4 -o addr show wlan0 | grep -q " inet "'
