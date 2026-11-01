#!/system/bin/sh
#
# dockerd-service wrapper, installed into /data/adb/ksu/bin.

exec sh "/data/adb/modules/dockerd/scripts/control.sh" "$@"
