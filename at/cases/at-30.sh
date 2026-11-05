#!/system/bin/sh
# AT-30: the Docker engine and its storage.
. "${AT_DIR}/lib.sh"

require_l1
info="$(in_l1 docker info 2>/dev/null)"
assert 'storage driver is overlay2' \
  sh -c "echo '${info}' | grep -q 'Storage Driver: overlay2'"
assert 'cgroup version is 1' sh -c "echo '${info}' | grep -q 'Cgroup Version: 1'"
assert 'docker runs a container' in_l1 docker run --rm alpine true
show 'server version' "$(echo "${info}" | sed -n 's/^ Server Version: //p')"
