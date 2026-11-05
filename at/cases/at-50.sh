#!/system/bin/sh
# AT-50: image state, filesystem check, and the duplicate-create guard.
. "${AT_DIR}/lib.sh"

image="${ROOTFS_HOME}/alpine.img"
assert 'image exists' test -f "${image}"
size="$(wc -c <"${image}")"
allocated="$("${BB}" du -k "${image}" | awk '{ print $1 }')"
show 'size MB' "$(awk -v b="${size}" 'BEGIN { printf "%d", b / 1048576 }')"
show 'allocated MB' "$(( allocated / 1024 ))"
if l1_pid >/dev/null 2>&1; then
  show 'fsck' 'skipped, Layer 1 runs'
else
  assert 'filesystem is clean' rootfs-service image fsck
fi
assert 'create refuses an existing image' \
  sh -c 'rootfs-service image create 2>&1 | grep -q "the image exists"'
