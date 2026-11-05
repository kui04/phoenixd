#!/system/bin/sh
# AT-43: an uninstall and a reinstall keep the image and the Docker data.
. "${AT_DIR}/lib.sh"

zip=/data/local/tmp/rootfs-0.2.0.zip
[ -f "${zip}" ] || skip 'the module zip is not on the device'
size_before="$(wc -c <"${ROOTFS_HOME}/alpine.img")"
data_before="$(find /data/adb/dockerd/data -maxdepth 1 | wc -l)"
# Wait for the daemon before the snapshot: the previous case restarted it.
count=0
while [ "${count}" -lt 60 ]; do
  in_l1 docker info >/dev/null 2>&1 && break
  sleep 3
  count=$(( count + 3 ))
done
containers_before="$(in_l1 docker ps -a --format '{{.Names}}' 2>/dev/null |
  sort)"
rm -f /data/adb/ksu/bin/rootfs-service.probe
sh /data/adb/modules/rootfs/uninstall.sh >/dev/null 2>&1
assert 'the image survives' test -f "${ROOTFS_HOME}/alpine.img"
assert 'the image keeps its size' \
  sh -c "[ \"\$(wc -c <'${ROOTFS_HOME}/alpine.img')\" = '${size_before}' ]"
assert 'the Docker data survives' \
  sh -c "[ \"\$(find /data/adb/dockerd/data -maxdepth 1 | wc -l)\" = '${data_before}' ]"
assert 'the wrapper is gone' test ! -e /data/adb/ksu/bin/rootfs-service
assert 'the host services are gone' test ! -d "${ROOTFS_HOME}/host-service/network"
ksud module install "${zip}" >/dev/null 2>&1
assert 'the module installs again' test -f /data/adb/ksu/bin/rootfs-service
headless-service start >/dev/null 2>&1
rootfs-service start >/dev/null 2>&1
count=0
while [ "${count}" -lt 90 ]; do
  rootfs-service status 2>/dev/null | grep -q 'layer 1: running' && break
  sleep 3
  count=$(( count + 3 ))
done
assert 'Layer 1 runs again' l1_pid
count=0
while [ "${count}" -lt 60 ]; do
  in_l1 docker info >/dev/null 2>&1 && break
  sleep 3
  count=$(( count + 3 ))
done
containers_after="$(in_l1 docker ps -a --format '{{.Names}}' 2>/dev/null |
  sort)"
assert 'the containers are all there' \
  sh -c "[ \"\$(echo '${containers_after}')\" = \"\$(echo '${containers_before}')\" ]"
show 'image bytes' "${size_before}"
