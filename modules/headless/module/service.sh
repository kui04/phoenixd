#!/system/bin/sh
#
# Nothing to do at late_start. The takeover stops the Android UI stack, and
# doing that before boot completed leaves the system without a display server
# and can keep adbd from settling. boot-completed.sh starts the services.

exit 0
