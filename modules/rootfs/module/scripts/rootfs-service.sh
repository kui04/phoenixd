#!/system/bin/sh
#
# rootfs-service wrapper, installed into /data/adb/ksu/bin.

exec sh "/data/adb/modules/rootfs/scripts/control.sh" "$@"

