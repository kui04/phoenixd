#!/system/bin/sh
# AT-52: a backup and a restore keep the filesystem and the workloads.
# A full file-hash comparison needs two mounts; the oracle here is a clean
# fsck, a booting Layer 1, and the same image and container lists.
. "${AT_DIR}/lib.sh"

backup=/data/local/tmp/at-backup.img.gz
images_before="$(in_l1 docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null |
  sort)"
containers_before="$(in_l1 docker ps -a --format '{{.Names}}' 2>/dev/null | sort)"
rm -f "${backup}"
rootfs-service stop >/dev/null 2>&1
assert 'the backup is written' rootfs-service image backup "${backup}"
assert 'the backup is not empty' test -s "${backup}"
assert 'the restore succeeds' rootfs-service image restore "${backup}"
assert 'the filesystem is clean' rootfs-service image fsck
rootfs-service start >/dev/null 2>&1
count=0
while [ "${count}" -lt 90 ]; do
  rootfs-service status 2>/dev/null | grep -q 'layer 1: running' && break
  sleep 3
  count=$(( count + 3 ))
done
assert 'Layer 1 runs again' l1_pid
sleep 6
images_after="$(in_l1 docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null |
  sort)"
containers_after="$(in_l1 docker ps -a --format '{{.Names}}' 2>/dev/null | sort)"
assert 'the image list is the same' \
  sh -c "[ \"\$(echo '${images_before}')\" = \"\$(echo '${images_after}')\" ]"
assert 'the container list is the same' \
  sh -c "[ \"\$(echo '${containers_before}')\" = \"\$(echo '${containers_after}')\" ]"
rm -f "${backup}"
