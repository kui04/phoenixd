#!/system/bin/sh
# AT-31: a container runs and its limits reach the daemon. The Android cgroup
# layout hides parts of the v1 tree from the container, so the limits are
# asserted through the API, and the visible cgroup list is recorded.
. "${AT_DIR}/lib.sh"

require_l1
assert 'a plain container runs' in_l1 docker run --rm alpine true
id="$(in_l1 docker run -d --memory 64m --cpus 0.5 alpine sleep 30 2>/dev/null)"
inspect="$(in_l1 docker inspect --format \
  '{{.HostConfig.Memory}} {{.HostConfig.NanoCpus}}' "${id}" 2>/dev/null)"
in_l1 docker rm -f "${id}" >/dev/null 2>&1
mem="$(echo "${inspect}" | awk '{ print $1 }')"
nano="$(echo "${inspect}" | awk '{ print $2 }')"
assert 'the memory limit is 64 MiB' sh -c "[ '${mem}' = '67108864' ]"
assert 'the cpu limit is 0.5 cores' sh -c "[ '${nano}' = '500000000' ]"
cgroups="$(in_l1 docker run --rm alpine cat /proc/self/cgroup 2>/dev/null |
  cut -d: -f2 | tr '\n' ' ')"
show 'container cgroups' "${cgroups}"
