#!/system/bin/sh
# AT-54: a truncated image fails the check with a clear message.
. "${AT_DIR}/lib.sh"

copy=/data/local/tmp/at-truncated.img
rm -f "${copy}"
"${BB}" dd if="${ROOTFS_HOME}/alpine.img" of="${copy}" bs=1M count=64 \
  2>/dev/null
assert 'the copy exists' test -s "${copy}"
out="$(e2fsck -p "${copy}" 2>&1)"
rc=$?
assert 'e2fsck reports a broken filesystem' sh -c "[ ${rc} -ne 0 ]"
show 'e2fsck' "$(echo "${out}" | tail -n 1)"
rm -f "${copy}"
