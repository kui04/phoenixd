#!/system/bin/sh
# AT-51: resize refuses to run while Layer 1 holds the image, and the shrink
# guard is the part that must never destroy data.
. "${AT_DIR}/lib.sh"

size="$(rootfs-service image status 2>/dev/null |
  sed -n 's/^size: \([0-9]*\) MB.*/\1/p')"
assert 'the image size is known' test -n "${size}"
out="$(rootfs-service image resize $(( size - 256 )) 2>&1)"
if l1_pid >/dev/null 2>&1; then
  assert 'resize is refused while Layer 1 runs' \
    sh -c "echo '${out}' | grep -q 'Layer 1 is running'"
  show 'size MB' "${size}"
  skip 'the shrink guard needs Layer 1 stopped'
fi
assert 'a shrink is refused' \
  sh -c "echo '${out}' | grep -q 'shrinking is not supported'"
show 'size MB' "${size}"
