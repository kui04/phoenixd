#!/system/bin/sh
# AT-47: the control commands refuse a non-root user.
. "${AT_DIR}/lib.sh"

assert 'a non-root user is refused' \
  sh -c '! su 1000 -c "rootfs-service status" >/dev/null 2>&1'
assert 'the state did not change' sh -c 'rootfs-service status 2>/dev/null | head -n 1'
