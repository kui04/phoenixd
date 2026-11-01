#!/system/bin/sh
#
# headless-service wrapper, installed into /data/adb/ksu/bin.

exec sh "/data/adb/modules/headless/scripts/control.sh" "$@"
