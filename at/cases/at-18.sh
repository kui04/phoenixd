#!/system/bin/sh
# AT-18: stop and start converge twice, without leftovers.
. "${AT_DIR}/lib.sh"

snapshot() {
  ip rule show | grep -E '^(8900|8950|8951|8952|9500|9501):' |
  cut -d: -f1 | sort
}
first="$(snapshot)"
assert 'the restart succeeds' rootfs-service restart
sleep 14
second="$(snapshot)"
assert 'the rule and link set is stable' sh -c "[ \"\$(echo '${first}' | grep -E '^(8900|8950|8951|8952|9500|9501):')\" = \"\$(echo '${second}' | grep -E '^(8900|8950|8951|8952|9500|9501):')\" ]"
# A detached device can stay listed by losetup until its namespace dies, so
# the sysfs attachments, which are the usable ones, are counted.
attached="$(for file in /sys/block/loop*/loop/backing_file; do
  cat "${file}" 2>/dev/null
done | grep -c alpine.img)"
assert 'one usable loop device at most' sh -c "[ ${attached} -le 1 ]"
for sample in 1 2 3; do
  show "sample ${sample}: $(rootfs-service status 2>&1 | head -2 |
    tr '\n' ' ') loops [$(losetup -a | grep -c alpine.img)]"
  sleep 2
done
assert 'Layer 1 runs' l1_pid
