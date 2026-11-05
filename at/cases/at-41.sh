#!/system/bin/sh
# AT-41: three headless start and stop cycles leave nothing behind.
# The start itself must succeed: on a timeout the headless module hands wlan0
# back to Android and returns non-zero, so a bare address check would report a
# rollback as a broken interface.
. "${AT_DIR}/lib.sh"

require_service wifi
for i in 1 2 3; do
  headless-service stop >/dev/null 2>&1
  sleep 4
  assert "cycle ${i} starts the headless module" headless-service start
  count=0
  while [ "${count}" -lt 60 ]; do
    [ "$(ip -4 -o addr show wlan0 | grep -c ' inet ')" -eq 1 ] && break
    sleep 2
    count=$(( count + 2 ))
  done
  for sample in 1 2 3; do
    show "sample ${sample}: addresses [$(ip -4 -o addr show wlan0 |
      tr '\n' ' ')] supplicants [$(pgrep -c -f wpa_supplicant 2>/dev/null |
      tr -d '\n')]"
    sleep 2
  done
  assert "cycle ${i} leaves one wlan0 address" \
    sh -c '[ "$(ip -4 -o addr show wlan0 | grep -c " inet ")" -eq 1 ]'
done
