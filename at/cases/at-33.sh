#!/system/bin/sh
# AT-33: a container with a restart policy returns after the daemon restarts.
. "${AT_DIR}/lib.sh"

require_l1
name="at-restart-$$"
in_l1 docker run -d --name "${name}" --restart unless-stopped alpine sleep 300
rootfs-service docker restart >/dev/null 2>&1
count=0
while [ "${count}" -lt 40 ]; do
  state="$(in_l1 docker ps --filter "name=${name}" --format '{{.Status}}' 2>/dev/null)"
  case "${state}" in Up*) break ;; esac
  sleep 2
  count=$(( count + 2 ))
done
assert 'the container is up again' sh -c "case '${state}' in Up*) true ;; *) false ;; esac"
in_l1 docker rm -f "${name}" >/dev/null 2>&1
