#!/system/bin/sh
#
# singbox-service wrapper, installed into /data/adb/ksu/bin.

exec sh "/data/adb/modules/singbox/scripts/control.sh" "$@"
