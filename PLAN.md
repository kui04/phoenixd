# PLAN: Layer 1 Rewrite with Alpine and OpenRC

Status: final plan. Implementation starts at S1.
Target: Redmi K30 (`phoenix`), Android 14, KernelSU Next 3.4.2,
Linux 4.14.336, 8 cores, 5.5 GB RAM.

## 1. Goal

Turn the phone into a headless Docker server with a normal Linux host for
Docker.

- L0 is the phone: kernel, firmware daemons, `wlan0`, Android, hardware.
- L1 is a Linux host: Alpine in an ext4 loop image, private namespaces,
  OpenRC, and the Docker engine.
- L2 is the workloads: normal Docker containers.

Three modules:

| Module     | Owns                                                              |
| :--------- | :---------------------------------------------------------------- |
| `rootfs`   | image, L1 lifecycle, L0 network, host supervisor, drivers, Docker |
| `headless` | Android UI, own Wi-Fi, charge, display (optional)                 |
| `singbox`  | L0 proxy binary and config                                        |

## 2. Decisions

| #   | Decision                                                     |
| :-- | :----------------------------------------------------------- |
| D1  | Alpine 3.24.3, musl, OpenRC 0.63.2                           |
| D2  | BusyBox init is PID 1; OpenRC runs the runlevels             |
| D3  | ext4 loop image, 2 GB sparse, growable                       |
| D4  | Private mount, PID, IPC, UTS, and network namespaces         |
| D5  | `pivot_root`, not `chroot`                                   |
| D6  | Named netns `l1` plus a veth pair; L1 sees static `eth0`      |
| D7  | L0 owns DNS, NAT, rules 8900/9500/9501, and full-cone DNAT    |
| D8  | L0 mirrors the WAN route into table `9500`, not into `main`   |
| D9  | Docker from apk, OpenRC service, `iptables-legacy`, overlay2 |
| D10 | Docker data stays on `/data` through a narrow bind           |
| D11 | sing-box runs on L0                                          |
| D12 | `headless` is optional and does not control L1               |
| D13 | Three modules: `rootfs`, `headless`, `singbox`               |
| D14 | Offline apk cache; the image is built on the device          |
| D15 | No NixOS or systemd; no user or cgroup namespace             |
| D16 | Full-cone DNAT plus a default-deny firewall in L1            |
| D17 | Uninstall keeps the image and Docker data                    |
| D18 | Proxy fail-open; three Wi-Fi retries of 60 s                 |
| D19 | L1 is `10.0.0.2/24` static; no DHCP server, no `eth0` client |
| D20 | L0 iptables writes run in L1's mount namespace; see 6.2.1    |

Why L1 remains: the apk Docker engine needs a musl userland and a normal
`/etc`, `/usr`, `/var`, and `/run`. L1 also gives Docker a detached mount
namespace, a private network namespace, a clean `/proc`, `/dev`, `/sys`,
cgroup view, and a disposable image.

Why sing-box is on L0: the proxy must also serve Android apps, and its
`tun0` must live in the host network namespace. Alpine 3.24 ships its own
`sing-box`, so the image could run a proxy, but that proxy would serve L1
only and would need `/dev/net/tun` in the image.

Why not NixOS: NixOS 24.05 is the last release with cgroup v1, and it
reached end of life on 2024-12-31. systemd 258 supports kernel 5.4 or
newer and removed cgroup v1; the device runs 4.14.

## 3. Architecture

### 3.1 Layers

| Layer | Owns                                   | Runs as                  |
| :---- | :------------------------------------- | :----------------------- |
| L0    | hardware, firmware, WAN, Android UI    | Android init, `ksu` root |
| L1    | image, namespaces, kernel view, Docker | PID 1 in its namespaces  |
| L2    | application containers                 | Docker                   |

L1 lives inside the network namespace that `rootfs` creates and removes.
The namespace is an L0 object; L1 owns only what runs inside it.

### 3.2 Ownership

| Resource                               | rootfs | headless | singbox |     L1     |
| :------------------------------------- | :----: | :------: | :-----: | :--------: |
| image, namespaces, `pivot_root`        |   W    |          |         |            |
| netns, veth, L1 address, DNS forwarder |   W    |          |         |            |
| table `9500` and rules 8900/9500/9501  |   W    |          |         |            |
| NAT, DNAT, `FORWARD`, MSS clamp        |   W    |          |         |            |
| WAN route mirroring                    |   W    |          |         |            |
| Android UI, own Wi-Fi, charge, display |        |    W     |         |            |
| `tun0` and proxy rules                 |        |          |    W    |            |
| `/proc`, `/dev`, `/sys`, cgroup view   |        |          |         |     W      |
| OpenRC, `dockerd`, `docker0`           |        |          |         |     W      |
| GPU and codec nodes                    |  pass  |          |         |     R      |
| Docker data directory                  |        |          |         | W via bind |

W = writes or owns. R = reads.

One object has one writer. `rootfs` owns every L0 object on the L1 path.
`headless` owns `wlan0` and the Android services only, and never writes the
veth, the NAT rules, or the routing rules.

### 3.3 Module boundaries

- Modules own policy and state. Daemons live in the image or on the host.
- Docker is part of `rootfs`. The `dockerd` zip is removed.
- Host services run under the host `runsvdir` in `rootfs`:
  `/data/adb/rootfs/host-service/<name>/run`.
- L1 services are OpenRC init scripts in the image.
- A module removes only its own files and wrappers.

## 4. Boot, stop, and failure

### 4.1 Boot sequence

1. Android boots. `rootfs`'s `service.sh` runs at `late_start`.
2. `rootfs-service host start` starts the host runit over
   `/data/adb/rootfs/host-service`. Its `network` service builds the L0
   transport: named netns, veth, `10.0.0.1/24`, table `9500`, rules
   8900/9500/9501, and the DNS forwarder. This phase uses `ip` only.
3. `rootfs-service start` starts L1: image mount, root tree,
   `pivot_root`, `/sbin/init`, OpenRC runlevels. The agent then programs
   the iptables objects from L1's mount namespace, and starts the WAN
   route mirroring.
4. L1's `net` service configures `eth0` as `10.0.0.2/24` static and
   provides `net`. The `docker` service starts after it.
5. If `headless` is enabled, `headless-service start` stops the Android UI
   and Wi-Fi services, starts its own `wpa_supplicant` and `udhcpc`, and
   starts charge and display.
6. The network agent mirrors the WAN default route into table `9500`.
7. The host runit starts sing-box. It does not wait for L1 or `headless`.

### 4.2 Stop sequence

1. `rootfs-service docker stop`.
2. `rootfs-service stop` writes `l1=down`. The agent removes the iptables
   objects through L1's mount namespace while PID 1 lives, then removes
   the rules, `veth0`, and the netns. Then `openrc shutdown`, signal
   PID 1, and detach the loop device. The host runit keeps running.
3. `headless-service stop`: stop its host services, restore Android. The
   platform and sing-box keep running.
4. `singbox-service stop`: stop the proxy, only on a full shutdown.
5. `rootfs-service host stop`: stop the host runit. Only on a module
   uninstall or a full shutdown.

### 4.3 Failure matrix

| Event               | Platform | L1 and Docker | sing-box  | Android                |
| :------------------ | :------- | :------------ | :-------- | :--------------------- |
| headless off        | runs     | runs          | runs      | owns `wlan0`           |
| headless start      | runs     | runs          | runs      | UI off, Wi-Fi handover |
| headless stop       | runs     | runs          | runs      | UI and Wi-Fi return    |
| headless Wi-Fi fail | runs     | runs          | runs      | restored after retries |
| L1 stop or crash    | runs     | stops         | runs      | untouched              |
| sing-box crash      | runs     | runs          | restarted | untouched              |

This table covers module survival. Network-internal events, such as a
missing WAN route, a stale proxy rule, or a failed iptables self-test, are
in 6.9.

## 5. L1 runtime

### 5.1 Namespaces

| Namespace | L1  | Reason                                 |
| :-------- | :-: | :------------------------------------- |
| mount     | yes | own root, own `proc`, `dev`, `sys`     |
| PID       | yes | `ps` shows only L1                     |
| IPC       | yes | no Android SysV IPC                    |
| UTS       | yes | hostname `phoenixd`                    |
| network   | yes | no netd, Android iptables, or BPF pins |
| user      | no  | simple device and cgroup access        |
| cgroup    | no  | BusyBox `unshare` has no `-C`          |

### 5.2 Mounts

- `/` is the ext4 loop image, rw.
- `/proc` is a fresh procfs, mounted after the PID namespace exists.
- `/dev` is a tmpfs with selected nodes, `devpts`, `shm`, `mqueue`.
- `/sys` is a fresh sysfs, not a bind of Android's `/sys`.
- `/sys/fs/cgroup` is a tmpfs with the cgroup v1 view: bind `/dev/cpuctl`
  to `cpu`, `/dev/memcg` to `memory`, `/dev/blkio` to `blkio`; mount fresh
  `devices`, `freezer`, `pids`.
- `/run` and `/tmp` are tmpfs.
- The launcher reads nothing from `/data` except `mounts.d`. The binds that
  file declares (`/var/lib/docker`, the drivers) are the only `/data` paths
  in L1.

### 5.3 PID 1 and OpenRC

- PID 1 is BusyBox init (`/sbin/init`). It reaps and reads `/etc/inittab`.
- `/etc/inittab`: `::sysinit:/sbin/openrc sysinit`,
  `::sysinit:/sbin/openrc boot`, `::wait:/sbin/openrc default`,
  `::shutdown:/sbin/openrc shutdown`.
- No getty lines. No `::ctrlaltdel`.
- `/etc/rc.conf`: `rc_sys="docker"`, `rc_cgroup_mode="legacy"`,
  `rc_crashed_stop=NO`, `rc_crashed_start=YES`. No `rc_provide`: `net` must
  be a real service, not a declared one.
- `/etc/init.d/docker`: `need net`, not `need sysfs cgroups net`. The
  `cgroups` service has `keyword -docker`.
- `/etc/init.d/net`: `provide net`, `after loopback`, no keyword, no
  `need`. It runs `ifup -i /etc/network/interfaces eth0` and `ifdown` in
  `stop`. Do not use Alpine's `networking`: it carries `keyword -docker`
  and `need localmount hostname`. OpenRC removes such a service, and its
  `net` provide, from the dependency tree when `rc_sys="docker"`; the
  service then never starts and `docker` no longer waits for the link.
  Verified on the device with openrc 0.63.2.
- Runlevels: `boot/{loopback,net}`, `default/{docker,local}`.
- `ifup` and `ifquery` come from `ifupdown-ng`, which `openrc` pulls in
  through `ifupdown-any`.
- Alpine has no `openrc-init`. This is the Alpine-native design.

### 5.4 Root switch

- Use `pivot_root`. The new root is the loop image. `put_old` is
  `<image>/.oldroot`. Then `umount -l /.oldroot`.
- `chroot` is used only in the image build step, to run apk scripts.
- Neither call is a security boundary. The value is a single root and no
  stale path to Android.

### 5.5 `/dev` staging

- The launcher mounts the tmpfs at `<image>/dev`, then copies nodes from
  Android's `/dev` with `cp -a`: `null`, `zero`, `full`, `random`,
  `urandom`, `tty`, `console`, `ptmx`, `tun`, `kgsl-3d0`, `ion`, `video*`,
  `dri/*`. Every entry is best-effort: `dma_heap/*` does not exist on this
  kernel (it uses ION only), and `video*` and `dri/*` depend on the
  firmware.
- Copy into the tmpfs, never into a directory on `/data`. `/data` is mounted
  `nodev`, and a bind mount inherits `nodev`, so a node staged there cannot
  be opened. A tmpfs keeps the nodes usable; `cp -a` preserves the type,
  major, minor, and group.
- Then mount `devpts` on `/dev/pts`, tmpfs on `/dev/shm`, and `mqueue` on
  `/dev/mqueue`.
- Symlinks: `/dev/fd`, `/dev/stdin`, `/dev/stdout`, `/dev/stderr`.

### 5.6 Environment

- Start PID 1 with `env -i`.
- `PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin`.
- `HOME=/root`, `TMPDIR=/tmp`, `TERM=xterm`.
- `TMPDIR` must not point to an Android path. A leaked value broke
  `docker run` in the spike.

### 5.7 Reboot guard

- The kernel already confines `reboot(2)` inside a child PID namespace. On
  4.14, `reboot_pid_ns()` kills the namespace and the phone stays up, and
  `sysrq` is 0. The guard is about a clean stop, not about the phone.
  `/proc/sysrq-trigger` is not blocked; L1 root is trusted.
- Replace `/sbin/reboot`, `/sbin/poweroff`, and `/sbin/halt` with scripts
  that run `openrc shutdown` and exit.
- Remove `::ctrlaltdel` from `/etc/inittab`.
- This stops accidents, not a malicious root.

## 6. Network

### 6.1 Allocation and contract

| Object     | Value                        | Owner         | See |
| :--------- | :--------------------------- | :------------ | :-- |
| WAN        | `wlan0`, DHCP                | headless/netd | 6.7 |
| L1 segment | `10.0.0.0/24`                | rootfs        | 6.1 |
| L0 end     | `10.0.0.1/24` on `veth0`      | rootfs        | 6.3 |
| L1 end     | `10.0.0.2/24` on `eth0`       | rootfs        | 6.1 |
| L1 NAT     | `172.17.0.0/16` on `docker0`  | L1            | 9.1 |
| proxy      | `172.19.0.1/30` on `tun0`     | singbox       | 10  |
| table 2022 | proxy routes                  | singbox       | 10  |
| prefs      | 9000, 9001, 9010              | singbox       | 10  |
| table 9500 | L1 prefix and mirrored WAN    | rootfs        | 6.2 |
| prefs      | 8900, 9500, 9501              | rootfs        | 6.2 |
| prefs      | 10000 to 32000                | netd          | 6.7 |

No value appears twice with a different meaning. The L1 end exists once,
as `L1_ADDR`; the interfaces file, the DNAT target, and rule 8900 all
derive from it.

L1 sees one NIC, `eth0`, with a static address:

- address `10.0.0.2/24`,
- gateway `10.0.0.1`,
- DNS `10.0.0.1`,
- MTU 1500.

`/etc/network/interfaces`:

```
auto eth0
iface eth0 inet static
  address 10.0.0.2/24
  gateway 10.0.0.1
  mtu 1500
```

L1's `net` service runs `ifup -i /etc/network/interfaces eth0` and provides
`net`. The `docker` service depends on `net`.

The address is static because four L0 objects must agree with it: the DNAT
target, the rule prefix, the DNS server, and the gateway. A DHCP lease
makes that agreement depend on runtime state, and a lease can be absent
after a restore or a failed renewal. One settings value, `L1_ADDR`, feeds
the interfaces file, the DNAT target, and the rule prefix. L1's `net`
service fails when `eth0` lacks this address.

L1 has no knowledge of `wlan0`, Android, or netd. The same image boots in a
QEMU VM whose peer is `10.0.0.1/24`.

### 6.2 L0 routing and iptables objects

Table `9500` and its rules. Section 6.3 creates the devices first.

```
ip route add 10.0.0.0/24 dev veth0 scope link table 9500
ip route replace default via <wan-gw> dev wlan0 onlink table 9500
ip rule add pref 8900 to 10.0.0.0/24 lookup 9500
ip rule add pref 9500 iif veth0 lookup 9500
ip rule add pref 9501 iif lo fwmark 0x0/0xffff lookup 9500
```

The rules never point at `main` and never point at a netd table.
(`ip addr add` still puts the connected route in `main`, as always.)

- 8900 keeps the L1 prefix out of the proxy in both directions. It runs
  before sing-box. Without it, an inbound DNAT packet enters table 2022
  first, because sing-box's rule 9001 matches every non-`lo` input.
- 9500 carries L1 egress. It runs after sing-box, so the proxy claims this
  traffic when the proxy is up, and table `9500` carries it directly when
  the proxy is down. This is the fail-open path.
- 9501 carries L0's own unmarked output, for example the DNS forwarder.
  It is necessary: with a narrow 9500, that output would fall to netd's
  rule 32000 and fail.

The order invariant is 8900 < sing-box 9000/9001/9010 < 9500 < netd 10000.
The agent refuses to start when a foreign rule occupies 8900, 9500, or
9501, and when a `suppress_prefixlength` rule exists between 8900 and 9600.

`iptables` objects, in the host netns:

```
-t nat -N PHOENIXD_DNAT
-t nat -A PHOENIXD_DNAT -d 10.0.0.0/24 -j RETURN
-t nat -A PHOENIXD_DNAT -m addrtype --dst-type LOCAL \
        -j DNAT --to-destination 10.0.0.2
-t nat -I PREROUTING 1 -i wlan0 -j PHOENIXD_DNAT
-t nat -N PHOENIXD_NAT
-t nat -A PHOENIXD_NAT -s 10.0.0.0/24 -o wlan0 -j MASQUERADE
-t nat -I POSTROUTING 1 -j PHOENIXD_NAT
-N PHOENIXD_FWD
-A PHOENIXD_FWD -i veth0 -o wlan0 -j ACCEPT
-A PHOENIXD_FWD -i wlan0 -o veth0 -j ACCEPT
-I FORWARD 1 -j PHOENIXD_FWD
-t mangle -I FORWARD 1 -o wlan0 -p tcp --tcp-flags SYN,RST SYN \
        -j TCPMSS --clamp-mss-to-pmtu
```

`--dst-type LOCAL` follows the `wlan0` address across changes, so the rule
survives a new lease or a new AP. The `nat` table is the only table that
accepts writes from the Android root.

### 6.2.1 Write path for `filter` and `mangle`

On this device a `filter` or `mangle` commit from the Android root fails
with `No chain/target/match by that name` (kernel `ENOENT`), although a
read of the same table succeeds. The vendor rules use the `quota2` match
and the `CONNMARK` target, and no userspace on the device can replay both.
Legacy iptables rewrites the whole table on every change, so one
unreplayable rule blocks every write, including a chain creation.

The same commit succeeds when the caller runs with L1's mount namespace as
its root:

```
nsenter -t <l1-pid1> -m -- iptables-restore --noflush -w
```

Measured on the device: `filter`, `nat`, and `mangle` all return 0 through
this path, and they fail from the Android root. Docker writes this way as
well (`iptables-restore --noflush -w -v`, seen in its process table). This
path is mandatory, not optional:

- phase 1, before L1 exists: the `ip` objects only;
- phase 2, after L1 PID 1 exists: every `iptables` write, through
  `nsenter -t <l1-pid1> -m`;
- stop: remove the `iptables` objects while PID 1 lives, then the `ip`
  objects, then PID 1.

The agent runs the self-test once per start, and it runs phase 2 on every
convergence, not only at boot, because a restarted L1 has a new mount
namespace. The self-test creates a probe chain, lists it, and deletes it.
A failure is reported by `rootfs-service status`, and it blocks the DNAT
objects, not L1 start.
The exact mechanism behind the mount-namespace dependence is not yet
identified; treat the self-test as the contract.

### 6.3 netns, veth, and launcher

L0 creates the devices before L1 starts, from the host root:

```
ip netns add l1
ip link add veth0 type veth peer name veth1
ip link set veth1 netns l1
ip link set lo up
ip link set veth0 mtu 1500
ip addr add 10.0.0.1/24 dev veth0
ip link set veth0 up
```

Android's `/system/bin/ip` supports `netns`. The BusyBox `ip` does not.
Android's `ip` keeps the namespace files in `/mnt/run/<name>`; neither
`/run` nor `/var/run` exists on the device, so never hard-code
`/var/run/netns`.

L1 joins the netns before it unshares the other namespaces:

```
ip netns exec l1 \
  busybox unshare -m -p -f -u -i sh launch-inner.sh
```

The launcher makes the mount tree private before `pivot_root`:

```
busybox mount --make-rprivate /
```

The BusyBox 1.37 in the module has no `unshare --propagation` option, so
that form does not work. `mount` does support `[r]private`.

Inside the netns, L1 renames the peer and sets the static address:

```
ip link set veth1 name eth0
ip link set eth0 mtu 1500
ip addr add 10.0.0.2/24 dev eth0
ip link set eth0 up
```

`ip netns exec` and `ip netns add` are verified on the device, together
with toybox `nsenter -t <pid> -m -u -i -n -p` for `rootfs-exec`. Toybox
`nsenter` takes namespace flags only, and has no `--net=FILE` form.

Stop order: phase 2 removals, then stop L1, then delete `veth0`, then
delete the netns.

### 6.4 WAN route mirroring

When `headless` is off, Android's default route can live only in a
per-network table, while rule 9500 looks up table `9500`. The network agent
must:

- find the WAN default route, in `main` or in the netd table, and copy it
  into table `9500` with `ip route replace`;
- check every 15 seconds;
- stay idempotent when `headless`'s `udhcpc` already wrote `main`;
- remove the mirrored route when the WAN is down or has no address, so L1
  fails fast with `ENETUNREACH` instead of a black hole.

Without this, L1 forwarding, Docker egress, and proxy egress fail when
`headless` is not running.

DNS upstreams are fixed (`1.1.1.1`, `223.5.5.5`), so the resolver does not
depend on DHCP.

### 6.5 Inbound

Full-cone DNAT: L0 sends all new connections on `wlan0` to `10.0.0.2`. L1
has a default-deny input policy and the Docker chains. `docker run -p`
works as on a normal host. L0 needs no rule per port.

Inbound needs three objects, and all three are mandatory:

- the `nat` DNAT chain, from `PREROUTING` position 1;
- the `filter` accept for `wlan0` to `veth0`, from `FORWARD` position 1;
- rule 8900, so the DNAT packet reaches table `9500` before sing-box's
  rule 9001 takes it into table 2022.

Measured on the device with a probe netns: the DNAT rule matches, the
packet is forwarded to `veth0`, the reply is translated back, and
`tcpdump` on `wlan0` shows a correct SYN-ACK with a correct checksum and a
forwarded TTL. L1 egress through the same objects also works (ICMP and
TCP).

The DNAT hook sits in front of netd's `oem_nat_pre`. netd owns its own
chains only, so the agent re-checks the whole object set on the 15 second
tick and repairs what is missing. The agent also removes the stale
`docker0` interface and the `-o docker0` MASQUERADE rules that v1 left in
the host namespace.

### 6.6 Lifecycle and the reconcile set

One writer owns the L0 objects: the `network` agent. It reads a desired
state file, `/data/adb/rootfs/state/network`, and converges on it. All
create, repair, and remove operations are idempotent.

The agent asserts this set on every tick, and repairs a missing item:

- netns `l1`, `veth0`, `10.0.0.1/24`, MTU 1500;
- table `9500`: the L1 prefix route and the mirrored WAN default;
- rules 8900, 9500, 9501, and the order invariant;
- `PHOENIXD_DNAT` with both rules and its `PREROUTING` hook;
- `PHOENIXD_NAT` with its rule and its `POSTROUTING` hook;
- `PHOENIXD_FWD` with both rules and its `FORWARD` hook;
- the `mangle` MSS clamp;
- the DNS forwarder answers on `10.0.0.1` (report only; runit restarts it);
- `ip_forward=1`, saved at start and restored at stop.

`rootfs-service start` and `stop` only write the desired state and wait for
convergence. They never touch a rule or a device directly. A command that
does not converge within 30 seconds reports the pending items.

### 6.7 Android stack

- Stop `wificond`, `wpa_supplicant`, and `vendor.wifi_hal_legacy` when
  `headless` takes over. Keep `cnss-daemon` and the firmware path.
- Keep netd running. The rules in 6.2 never touch a netd table, and they do
  not match marked Android traffic.
- No `dnsproxyd` rename. v1 renamed that socket to keep Android's resolver
  from answering. In v2 L1 uses the fixed `10.0.0.1` only, so no process
  depends on it.
- `headless` restores `wlan0` only: stop its `wpa_supplicant` and `udhcpc`,
  flush the address it added, remove the default route it wrote, and start
  the Android Wi-Fi services. It never removes the veth, the netns, the
  rules, or the NAT objects. Those belong to `rootfs`.

### 6.8 DNS

The forwarder binds `10.0.0.1:53`, not `INADDR_ANY`, and forwards to the
fixed upstreams. It drops `AAAA` and `HTTPS` queries, because L1 has IPv4
only and a dual-stack client would otherwise wait for an unusable address.
`/etc/resolv.conf` in the image names `10.0.0.1`.

The forwarder sends unmarked local output, so rule 9001 sends its queries
into the proxy while sing-box is up, and rule 9501 sends them direct when
the proxy is down. This is the chosen behavior: the proxy sees DNS. To
pin DNS away from the proxy, bind the query socket to the `wlan0` address
first; the `from 0.0.0.0` rule then stops matching.

### 6.9 Failure modes

This table covers the network path only. Module survival is in 4.3.

| Event                     | Result                                             |
| :------------------------ | :------------------------------------------------- |
| WAN down                  | table `9500` has no default; L1 gets ENETUNREACH    |
| proxy stopped             | L1 egress falls through 9500 to the WAN, direct     |
| proxy rules left behind   | table 2022 empties with `tun0`; fail-open still holds; agent reports it |
| iptables self-test fails  | inbound is off; `status` reports it; no silent pass |
| `eth0` address wrong      | L1 `net` fails, `docker` does not start             |
| L1 crash                  | objects stay; agent reports it and removes them on `l1=down` |
| netd rewrites its chains  | agent repairs `PHOENIXD_*` hooks on the next tick   |

## 7. Storage

### 7.1 Image

- `/data/adb/rootfs/alpine.img`, ext4 on a sparse file.
- Default 2048 MB. Grow with `rootfs-service image resize`.
- `/data` is `nosuid,nodev`; a plain directory root would break setuid and
  device nodes. A loop mount is not affected.
- `e2fsck -p` before mount. On failure, refuse to start and print the
  recovery command.
- Loop setup must use `/dev/block/loopN`. Use the KernelSU BusyBox or an
  explicit `losetup`, and refuse to start when no node is free. Android
  holds many loop nodes itself, and `max_loop` is 0, so the node count is
  dynamic.

Size budget:

| Item               | Size                           |
| :----------------- | :----------------------------- |
| minirootfs tarball | 4 MB                           |
| base apk cache     | 89 MB, 83 packages             |
| installed base set | 321 MiB, 95 packages            |
| daemon log budget  | 24 MB, `/var/log` on the image |
| default image      | 2048 MB, sparse                |
| `/data` free space | 101 GB                         |

There is no 64 MB limit. That was the v1 tmpfs. Shrinking needs a rebuild.

Measured on v3.24: the cache holds 83 packages and 89 MB. With
`docker-cli-compose` the image installs 95 packages and 321 MiB; without
it, 94 packages and 292 MiB.

### 7.2 Docker data

- `/data/adb/dockerd/data` to `/var/lib/docker`, one narrow rw bind.
- `rootfs` owns it. The path stays for v1 migration.
- The data is much larger than the OS image and stays on `/data`.

### 7.3 Narrow binds

```
/data/adb/dockerd/data          /var/lib/docker          rw
/data/adb/rootfs/drivers        /opt/phoenixd/drivers    ro
```

The driver payload has `lib/` and `share/vulkan/`. The compose template
uses `/opt/phoenixd/drivers/lib`.

`/sdcard` is not bound by default.

### 7.4 Image lifecycle

```
rootfs-service image create [MB]
rootfs-service image fsck
rootfs-service image resize MB
rootfs-service image backup PATH
rootfs-service image restore PATH
rootfs-service image status
rootfs-service image update
```

- `resize` stops L1, truncates the file, runs `e2fsck -f`, then
  `resize2fs`.
- `backup` stops L1 and writes a gzip stream (`gzip -1`), because neither
  toybox nor BusyBox `cp` supports `--sparse`. `restore` unpacks it with
  `gzip -dc`.
- `update` mounts the image, runs `apk upgrade` from the new cache, then
  applies the overlay, then verifies the overlay files. apk 3 protects
  `etc/` by default, so an upgrade keeps a patched `/etc/init.d/docker`
  and writes a `*.apk-new` file next to it. The overlay is applied last
  for that reason.

## 8. Build and install

### 8.1 Versions

| Input             | Version            | Source                   |
| :---------------- | :----------------- | :----------------------- |
| Alpine minirootfs | 3.24.3             | `dl-cdn.alpinelinux.org` |
| minirootfs SHA256 | `4d3f80af...51f50` | release sidecar          |
| openrc            | 0.63.2-r0          | Alpine main              |
| docker            | 29.9.2-r0          | Alpine community         |
| containerd        | 2.3.7-r0           | Alpine community         |
| runc              | 1.4.3-r2           | Alpine community         |
| iptables-legacy   | 1.8.13-r0          | Alpine main              |
| iproute2          | 7.0.0-r0           | Alpine main              |
| apk-tools (build) | 3.0.5              | nixpkgs                  |

### 8.2 Offline apk cache

1. Host: extract the minirootfs to a scratch root. Keys are at
   `/usr/share/apk/keys`; the database is at `/lib/apk/db`.
2. Host: `apk --root <scratch> --arch aarch64 update`.
3. Host: `apk --root <scratch> --arch aarch64 add --simulate <packages>`.
4. Host: `apk fetch --root <scratch> --arch aarch64 --recursive -o cache
   <packages>`. For openrc, docker, docker-cli-compose, iptables-legacy,
   iproute2, e2fsprogs, util-linux, ca-certificates, and tzdata the cache
   is 89 MB. Measured on v3.24: 83 packages without compose, 95 installed
   with it, 321 MiB installed. `openrc` pulls `ifupdown-ng` through
   `ifupdown-any`, which supplies `ifup` and `ifquery`. `install_if` also
   adds `docker-openrc`, `containerd-openrc`, `iptables-openrc`,
   `log_proxy`, and `tini-static`. The overlay replaces
   `/etc/init.d/docker` and `/etc/conf.d/docker` as whole files, and no
   runlevel link is added for `containerd`; a second containerd would take
   `/var/lib/containerd` on the image.
5. Zip: minirootfs, apk cache, overlay, scripts.
6. Device: create the image, untar the minirootfs, run
   `apk add <cache>/*.apk` inside a chroot. Scripts run natively. No
   network is needed.

The host step needs no root. `apk fetch` only downloads.

### 8.3 Overlay

- `/etc/resolv.conf`, `/etc/hostname`, `/etc/hosts`.
- `/etc/conf.d/docker` with `PATH="/opt/phoenixd/bin:${PATH}"`,
  `LOGPROXY_ROTATION_SIZE=8388608`, `LOGPROXY_ROTATED_FILES=3`, and
  `DOCKER_OPTS` with `--feature containerd-snapshotter=false`,
  `--storage-driver=overlay2`, and `--ip6tables=false`.
- `/opt/phoenixd/bin/` with `iptables`, `iptables-save`, `iptables-restore`,
  and the same three `ip6tables` names as symlinks to
  `/usr/sbin/xtables-legacy-multi`. All six names are verified on the
  device. Do not place them in `/usr/sbin`: the nft `iptables` package owns
  those paths, and an `apk upgrade` would restore nft under dockerd.
  `openrc-run` sources `/etc/conf.d/<service>`, so the `PATH` reaches
  `dockerd`.
- `/etc/rc.conf`, `/etc/inittab`, `/etc/network/interfaces` (static
  `10.0.0.2/24`, see 6.1), `/etc/init.d/docker` (`need net`),
  `/etc/init.d/net`, and the runlevel links.
- `/sbin/reboot`, `/sbin/poweroff`, `/sbin/halt` as stop scripts.
- `/etc/profile.d/phoenixd.sh` with PATH and aliases.
- `/opt/phoenixd/` for drivers and helper scripts.

### 8.4 Install, upgrade, uninstall

- Install: keep an existing image; otherwise create it, unpack, and apply
  the overlay. Install the host wrappers and host service directories.
- Upgrade: replace host scripts and the apk cache. Do not touch the image.
  Use `image update` for package changes.
- Uninstall: stop L1, remove host scripts and wrappers, keep the image and
  Docker data, and print the paths.

## 9. Docker

### 9.1 Startup

```
BusyBox init (PID 1)
  -> /etc/inittab
     -> openrc boot
        -> loopback
        -> net (ifup eth0, static address, provides net)
     -> openrc default
        -> /etc/init.d/docker
           -> supervise-daemon
              -> /usr/bin/dockerd
                 -> containerd
                    -> containerd-shim-runc-v2 per container
```

The OpenRC script provides `supervise-daemon` restart, `log_proxy` to
`/var/log/docker.log` with rotation, `rc_ulimit`, and `depend() need net`.

The `docker` group must exist. The `docker-engine` pre-install script
creates it; the offline apk install runs that script natively.

### 9.2 Adaptations

1. Install `iptables-legacy` and put the names in `/opt/phoenixd/bin`, ahead
   of `/usr/sbin` on the service `PATH`. Alpine's `iptables` is nft, and the
   kernel has no nf_tables.
2. Keep the classic overlay2 store. Docker 29 makes the containerd image
   store the default for new installs, and the v1 data at
   `/data/adb/dockerd/data` is an overlay2 store. Pass
   `--feature containerd-snapshotter=false` and `--storage-driver=overlay2`,
   then confirm `docker info` reports `driver=overlay2`.
3. Disable IPv6 iptables.
4. Keep `--data-root=/var/lib/docker` and bind `/data/adb/dockerd/data`.
5. Patch `/etc/init.d/docker` to `need net`.

### 9.3 Footprint

| Item     | Alpine apk                  | v1 static tar    |
| :------- | :-------------------------- | :--------------- |
| Version  | 29.9.2-r0, containerd 2.3.7 | 29.9.2           |
| Disk     | about 178 MiB               | 189 MiB unpacked |
| Start    | OpenRC service              | runsv run script |
| Logs     | rotation                    | shell redirect   |
| Updates  | `apk upgrade`               | module release   |
| Idle RSS | about 106 MB                | about 25 MB      |

Use apk. The static tar is a fallback only for memory or a version pin.

### 9.4 Control

```
docker <args>                                  # rootfs-exec docker
rootfs-service docker start|stop|restart|status|log
dockerd-service ...                            # compatibility wrapper
```

The compose template is in `rootfs` and uses `/opt/phoenixd/drivers`.

## 10. sing-box

- Binary: `/data/adb/singbox/bin/sing-box` (android-arm64).
- Config: `/data/adb/singbox/config.json`.
- Host runit service:
  `/data/adb/rootfs/host-service/singbox/run`.
- Started at boot, independent of L1 and `headless`.
- `default_interface: wlan0`; `tun0` and the rules live in the host netns.

Three paths cross L0. Each one has one entry point and one owner:

```
inbound:   wlan0 -> PREROUTING PHOENIXD_DNAT (10.0.0.2)
           -> rule 8900, table 9500 -> veth0 -> L1 -> docker0

L1 egress: container -> docker0 -> L1 NAT -> eth0 -> veth0 -> L0
           -> rule 9001, table 2022 -> tun0 -> sing-box -> wlan0
           proxy down: rule 9500, table 9500 -> wlan0

L0 output: forwarder -> rule 9001 or 9501 -> table 2022 or 9500 -> wlan0
```

The inbound path never enters the proxy: rule 8900 runs first. The egress
path enters the proxy while sing-box is up, and falls through to table
`9500` when the proxy is down; this is fail-open. Rule 9500 must stay after
sing-box's 9000/9001, and sing-box must install no `suppress_prefixlength`
rule; the agent checks both conditions.

DNS: L1 uses `10.0.0.1`, served by the L0 forwarder with fixed upstreams.

## 11. headless

- Owns: Android UI stop and restore, own Wi-Fi, charge, display.
- Host runit services under `/data/adb/rootfs/host-service/`.
- Does not start or stop L1, the netns, the veth, NAT, 9500, or sing-box.
- No `dnsproxyd` rename; see 6.7.
- Start: stop Android UI and Wi-Fi services, start `wpa_supplicant` and
  `udhcpc`. The platform rules stay; route mirroring keeps table `9500`
  correct.
- Stop: stop its Wi-Fi services, restore Android. netd takes `wlan0` back;
  the platform re-mirrors the route.
- Failure: three retries of 60 seconds, then restore Android. L1, Docker,
  and sing-box keep running.

## 12. Interfaces

### 12.1 CLI

```
rootfs-service start|stop|restart|status|log [lines]|exec|shell
rootfs-service host start|stop|status
rootfs-service image create|fsck|resize|backup|restore|status|update
rootfs-service docker start|stop|restart|status|log
headless-service start|stop|restart|restore|status|log [lines]
docker <args>
singbox-service start|stop|status|log|check
dockerd-service ...               # compatibility wrapper
```

`host` owns the host `runsvdir` over
`/data/adb/rootfs/host-service`. `start` and `stop` of L1 do not touch it.

`rootfs-service exec` runs
`nsenter -t <PID1> -m -u -i -n -p -- <cmd>`.
`rootfs-service shell` runs `sh -c 'cd $HOME; exec sh'` in the same
namespaces.

### 12.2 `mounts.d`

`/data/adb/rootfs/mounts.d/<name>.conf`:

```
# src  dst  mode
/data/adb/dockerd/data  /var/lib/docker  rw
```

Default is a non-recursive `bind`. `recursive` selects `rbind`. `ro` and
`rw` are accepted. L0 validates absolute paths, rejects `..`, and warns
when a recursive source contains the image path.

### 12.3 Settings

- L0: `/data/adb/headless/settings.sh` and `wifi.conf`.
- L1: `/data/adb/rootfs/settings.d/*.sh`, published by owners.
- API version: `/data/adb/rootfs/api_version`. Modules check it before they
  use a platform command.

### 12.4 Host services

`/data/adb/rootfs/host-service/<name>/run`:

- `network`, `dns`: the L0 network agent and the DNS forwarder
  (`rootfs`). The agent has two phases; see 6.2.1. It needs L1's PID 1 for
  the `iptables` phase, and it retries until that PID exists.
- `singbox`: the proxy (`singbox`).
- `wifi`, `charge`, `display`: `headless`.

The DNS forwarder and the agent move from `headless` to `rootfs`;
`rootfs` already owns NAT, DNS, and `10.0.0.1`. There is no DHCP server.

A service script must run in the foreground. The host `runsvdir` in
`rootfs` supervises them.

### 12.5 Wrappers

One wrapper per module in `/data/adb/ksu/bin`. `rootfs` also installs
`docker` and `dockerd-service` compatibility wrappers. A module removes
only its own wrappers.

## 13. Migration from v1

1. Stop v1: `singbox-service stop`, `dockerd-service stop`,
   `headless-service stop`, `rootfs-service stop`.
2. Install the v2 `rootfs`. Keep `/data/adb/dockerd/data` and
   `/data/adb/singbox/config.json`. Remove the stale v1 host service tree
   `/data/adb/rootfs/service`.
3. Install the v2 `headless` and `singbox` modules at the same time, or
   leave `headless` off and let Android own `wlan0` until it is installed.
4. `rootfs-service image create`, then `rootfs-service host start`, then
   `rootfs-service start`. Then check the self-test result and
   `ip route get 10.0.0.2`.
5. Docker 29.9.2 opens the same data at the same path with overlay2. Check
   `docker images` and `docker ps -a`.
6. If Docker refuses the data, use `docker save` in v1 and `docker load` in
   v2.
7. Remove the v1 `dockerd` module after S4 passes. Do not use the KernelSU
   uninstaller for it: `modules/dockerd/module/scripts/cleanup.sh` runs
   `rm -rf /data/adb/dockerd`, which deletes the Docker data. Remove the
   module directory and its wrappers by hand, or move the data first.
8. Rollback: stop v2, reinstall v1, reuse the untouched data.

## 14. Phases

### S0. Feasibility (done)

Alpine in a loop image, `pivot_root`, Docker from apk with
`iptables-legacy`, OpenRC with BusyBox init. All passed in private
namespaces, but the spike booted with `rc_provide="loopback net"` and ran
its only container with `--network none`, so the network path was not
covered. The offline apk path is verified separately: host `apk fetch`,
then `apk add --no-network` inside the chroot on the device.

The network path was then measured on the running device: netns and veth
creation, static address, table `9500`, rules 8900/9500, `DNAT`,
`MASQUERADE`, `FORWARD` accept, L1 egress (ICMP and TCP), and a correct
inbound SYN-ACK on `wlan0`. The same run showed that `filter` and `mangle`
writes fail from the Android root and succeed from L1's mount namespace
(6.2.1).

### S1. Image and build

- `scripts/build-image.sh`: untar, chroot apk add, overlay.
- `build.sh`: minirootfs fetch, `apk update`, `apk fetch --recursive`.
- `rootfs-service image ...`.
- Test create, fsck, resize, backup, restore, status.

Gate: `image create` from the zip alone, offline, gives a bootable rootfs
(AT-50, AT-52).
Rollback: remove the image and the scripts.

### S2. Launcher and OpenRC

- Launcher: `ip netns exec`, `unshare -m -p -f -u -i`, `mount
  --make-rprivate /`, loop mount, `/proc`, `/dev` tmpfs with copied nodes,
  `/sys`, cgroup v1, `mounts.d`, `pivot_root`, `env -i`, `hostname`,
  `/sbin/init`.
- Agent phase 1, `ip` only: netns, veth, `10.0.0.1/24`, table `9500`,
  rules 8900/9500/9501. No iptables in this phase.
- `rootfs-exec` with `nsenter`.
- OpenRC config, the `net` service with the static address, and the reboot
  guard.
- Test boot, `rc-status`, zombies, reboot guard, stop, phone reboot.

Gate: L1 boots and stops cleanly; `eth0` is `10.0.0.2/24`; only L1
processes in `/proc`; no Android path; no loop device left (AT-01,
AT-10 to AT-18).
Rollback: stop the spike, remove the image. v1 keeps running.

### S3. Network

Prerequisite: stop v1 in the order in section 13.

- L0 network agent: netns, veth, static `10.0.0.2/24`, DNS forwarder,
  table `9500`, rules 8900/9500/9501, `PHOENIXD_DNAT`, `PHOENIXD_NAT`,
  `PHOENIXD_FWD`, the MSS clamp, and the 15 second reconcile tick.
- Boot self-test for the `iptables` write path (6.2.1), then the
  `iptables` phase through `nsenter -t <l1-pid1> -m`.
- Move the DNS forwarder host service and the `dns-forwarder` source from
  `headless` to `rootfs`. Delete the DHCP server and its client calls.
- L1 `net` service with the static address, and default-deny input.
- WAN route mirroring into table `9500`.
- Tests: ping, DNS, curl, `docker run -p` from a second LAN host, `ip
  route get` with a marked source (Android routing must not change),
  headless off and on, QEMU portability, Wi-Fi stop. Do not run the
  inbound test from a host that has its own proxy policy routing; that
  host can drop the SYN-ACK.

Gate: the iptables self-test passes; L1 has internet, DNS, and a published
port; the image boots on a plain Linux host (AT-20 to AT-29, AT-63).
Rollback: stop L1, remove the rules, restore Android.

### S4. Docker

- Image with the Docker package, `docker-cli-compose`, the legacy symlinks
  under `/opt/phoenixd/bin`, and `DOCKER_OPTS`.
- Bind `/data/adb/dockerd/data` to `/var/lib/docker`.
- OpenRC `docker` service (`need net`); no runlevel link for `containerd`.
  dockerd runs in L1's mount namespace, so its own `filter` and `nat`
  writes succeed without the phase-2 wrapper; only the `PHOENIXD_*`
  objects need that wrapper.
- Tests: `docker info`, `run`, limits, restart policy, container DNS, v1
  images and containers.
- Published-port test, which exercises all three phase-2 objects from
  6.2.1: `docker run -p` from a second LAN host.
- Move the compose template from `modules/dockerd/module/etc` to `rootfs`
  and point it at `/opt/phoenixd/drivers`.
- Fold `dockerd` into `rootfs`; delete `modules/dockerd`.

Gate: existing images and containers run; a published port is reachable;
`docker info` reports `Storage Driver: overlay2` and `Cgroup Version: 1`
(AT-30 to AT-35).
Rollback: stop v2 and restart v1; data is untouched.

### S5. headless optional

- Move Wi-Fi, charge, and display to the host runit.
- Add `android.sh`; drop the `dnsproxyd` rename.
- Remove L1 start and stop calls; `headless` touches `wlan0` only (6.7).
- Test headless on/off with L1 on/off; stop headless while Docker and
  sing-box run; Wi-Fi failures.
- Check that a headless stop leaves `ip rule`, table `9500`, and
  `PHOENIXD_*` unchanged.

Gate: with or without headless, L1 has a WAN route, Docker works, and
sing-box works. A headless stop changes no L0 object except `wlan0`
(AT-40 to AT-42).
Rollback: keep v1 headless until this passes.

### S6. sing-box and docs

- Host runit service; start at boot, independent of L1 and headless.
- Remove `ndc` and netd code.
- Agent checks for the proxy: `tun0` exists when the service claims to run,
  no `suppress_prefixlength` rule between 8900 and 9600, and no route to
  `10.0.0.0/24` in table 2022. A violation is reported by `status`.
- Test proxy, Docker pull (fix the v1 `EOF` first), hardware acceleration
  compose, reboot with headless off, and the fail-open path
  (`singbox-service stop`, then `ip route get 8.8.8.8 iif veth0`).
- Update root docs and module list.

Gate: the full stack runs with the three modules; the fail-open path and
the inbound path both pass (AT-25, AT-29, AT-60).
Rollback: reinstall v1 modules and reuse the data.

### S7. Release

- Read-only `/sys` where possible.
- Log rotation for host services.
- Health checks: image fsck, `eth0` address, rule order, self-test result,
  `tun0` presence, and the WAN route.
- Backup and restore drill.
- A LAN inbound drill from a second host, and a reboot drill with headless
  off.
- Remove v1 code paths and docs.
- Release the three modules and the migration note.

Gate: the full acceptance run passes twice in a row, on a rebooted device
(AT-41 to AT-47, AT-50 to AT-55, AT-61, AT-62).

## 15. Acceptance tests

The acceptance run executes on the device, over `adb`, as root. There is no
test framework and no CI. One POSIX `sh` runner, `at/run.sh`, runs the
cases in order and writes one log per case.

### 15.1 Rules

- Run on the device only. The QEMU boot stays a portability check in S3,
  and it is not part of this run.
- Preflight first: the four static gates in AGENTS.md, then AT-01.
- Take a snapshot before AT-1x, AT-2x, and AT-4x, and compare after. The
  snapshot is `ip rule`, `ip -o link show`, `ip route show table 9500`,
  the `iptables-save` rule counts for `nat`, `filter`, and `mangle`,
  `docker ps -a`, and the free space on `/data`.
- Every case is reversible. It removes what it creates in a trap, and it
  runs the trap on failure too.
- Run cases serially. No two cases change `wlan0` at the same time.
- One log per case: `/data/local/tmp/at/<id>.log`. The runner prints
  `PASS <id>`, `FAIL <id>`, or `SKIP <id>: <reason>`.
- Stop at the first FAIL in AT-1x to AT-4x. Leave the log and the
  snapshot in place.
- A case that needs a second LAN host says so. That host must have no proxy
  policy routing; a proxy on the test host can drop the SYN-ACK.

### 15.2 Preflight

| ID     | Action                                       | Oracle                 |
| :----- | :------------------------------------------- | :--------------------- |
| AT-00  | the four static gates from AGENTS.md         | all exit 0             |
| AT-01  | `nsenter -t <l1-pid1> -m -- iptables -N AT_PROBE`, list, delete | exit 0, then 0 leftovers |
| AT-01N | the same command from the Android root       | exit non-zero (control) |

### 15.3 L1 runtime and transport

| ID    | Action                                            | Oracle |
| :---- | :------------------------------------------------ | :----- |
| AT-10 | `ip netns list`; `ip -o addr show veth0`; `rootfs-exec ip -4 -o addr show eth0` | `l1`; `10.0.0.1/24`; `10.0.0.2/24` |
| AT-11 | `rootfs-service start` twice, compare both snapshots | no change on the second run |
| AT-12 | `rootfs-exec ls /data`; `rootfs-exec readlink /proc/1/root`; `rootfs-exec ps` | only `mounts.d` paths; the image; no `.oldroot`; no Android process |
| AT-13 | `rootfs-exec sh -c 'dd if=/dev/urandom of=/dev/null bs=4k count=1'`; a pty test; `ls /dev/block` | read works; pty works; no block nodes |
| AT-14 | `rootfs-exec cat /sys/fs/cgroup/memory/memory.limit_in_bytes`; `.../pids/pids.max` | both readable |
| AT-15 | spawn an orphan in L1, wait 5 s, `rootfs-exec ps` | no zombie |
| AT-16 | `rootfs-exec /sbin/reboot`, then `adb get-state`  | L1 stops cleanly; phone stays up |
| AT-17 | `rootfs-exec rc-status boot`; `rc-service net status`; `rootfs-service status` | `loopback` and `net` started; PID 1 alive |
| AT-18 | `stop`, snapshot, `start`, snapshot, twice        | both converge; no orphan process, rule, or device |

### 15.4 L0 network

| ID    | Action                                            | Oracle |
| :---- | :------------------------------------------------ | :----- |
| AT-20 | `ip rule show`; `ip route show table 9500`         | 8900, 9500, 9501 in order; no foreign rule there; no `suppress_prefixlength` in 8900 to 9600 |
| AT-21 | `ip route get 8.8.8.8` with `mark 0xd0001`, `mark 0x10063`, and no mark | none uses table 9500 |
| AT-22 | `ip route get 10.0.0.2`                            | `dev veth0 table 9500` |
| AT-23 | from a second LAN host: published port, then an unpublished port (use the container from AT-32) | reachable; `refused`, not a timeout |
| AT-24 | `rootfs-exec ping -c1 1.1.1.1`; TCP fetch to `1.1.1.1:80`; `docker run --rm curlimages/curl ifconfig.me` | replies; HTTP status line; the proxy egress address |
| AT-25 | `singbox-service stop`; `ip route get 8.8.8.8 iif veth0`; start; same command | table 9500 via `wlan0`; then `dev tun0 table 2022` |
| AT-26 | delete the `PHOENIXD_FWD` hook three times, wait two ticks each | the hook returns every time |
| AT-27 | turn Wi-Fi off (headless on), wait two ticks; turn it on | no default in table 9500; restored after |
| AT-28 | shadow `nsenter` with a stub that exits 1; `rootfs-service restart` | DNAT not installed; `status` reports; L1 still boots |
| AT-29 | `rootfs-exec nslookup alpinelinux.org`; `nslookup -type=AAAA ... 10.0.0.1`; from LAN `nslookup 10.0.0.1` | A resolves; AAAA empty; no answer from LAN |

### 15.5 Docker and workloads

| ID    | Action                                            | Oracle |
| :---- | :------------------------------------------------ | :----- |
| AT-30 | `docker info`                                     | `overlay2`, `Cgroup Version: 1`, `Firewall Backend: iptables` |
| AT-31 | `docker run --rm alpine true`; `docker run --memory 64m --cpus 0.5 ...` | exits 0; the container cgroup shows the limit |
| AT-32 | `docker run -d -p 8080:80 nginx`; reach it from a second LAN host | HTTP answer from that host |
| AT-33 | `--restart unless-stopped`; `rc-service docker restart` | the container is back |
| AT-34 | `docker images --digests`, `docker ps -a` before and after an upgrade | same list |
| AT-35 | inside a container: `ls /dev/block`, write to a host cgroup path | both fail |

### 15.6 Module boundaries

| ID    | Action                                            | Oracle |
| :---- | :------------------------------------------------ | :----- |
| AT-40 | `headless-service stop`, snapshot diff             | no change outside `wlan0` |
| AT-41 | `headless-service start`, `stop`, three times      | no leftover process, address, or netns |
| AT-42 | block the Wi-Fi service three times                | Android restored; L1 and the proxy unaffected |
| AT-43 | uninstall, then install `rootfs`                   | image and Docker data kept; only own wrappers removed |
| AT-44 | `rootfs-service stop`; `kill -9` the agent mid-stop; then `start` | order holds; the next `start` converges |
| AT-45 | `kill -9` L1 PID 1                                 | `status` reports L1 down; objects stay; `start` converges |
| AT-46 | `start` and `stop` at the same time                | no partial state; one command reports busy |
| AT-47 | run a command as a non-root user                   | refused; no state change |
| AT-48 | reboot with headless disabled, then check L1 and the proxy | both up; `status` clean |

### 15.7 Image lifecycle

| ID    | Action                                            | Oracle |
| :---- | :------------------------------------------------ | :----- |
| AT-50 | `image create` default and 1024 MB                 | `e2fsck -p` clean; `du` far below the file size |
| AT-51 | `image resize` up; then down                       | up works with a clean fsck; down is refused |
| AT-52 | `image backup`, `image restore`, compare           | clean fsck; the same file list and hashes |
| AT-53 | `image backup` while L1 runs                       | refused with a clear message |
| AT-54 | truncate the image, then `start`                   | refused; the recovery command is printed |
| AT-55 | reserve space so `/data` is below two images       | `create` and `resize` are refused |

### 15.8 Exploratory and security

| ID    | Session or check                                  | Oracle |
| :---- | :------------------------------------------------ | :----- |
| AT-60 | 30 min: inject network failure at random (Wi-Fi, proxy, delete a rule) | every step recovers within two ticks; no stuck state |
| AT-61 | 30 min: migrate v1 to v2 and back, twice           | no data loss; the same images and containers |
| AT-62 | port sweep from a second LAN host                  | only published ports answer |
| AT-63 | flush the DNAT hook, probe `10.0.0.1:53` at once   | no answer; the window is not an open resolver |

### 15.9 Not covered

- The mount-namespace mechanism behind AT-01. There is no oracle for it;
  the self-test is the contract.
- Performance. The values in section 16 are one-shot; there are no
  regression thresholds.
- Android UI or app behavior. The target is headless.
- Long fuzzing of the DNS parser. Use an ASan build and a seed corpus at
  build time.
- The QEMU boot. It is the S3 portability gate, not part of this run.

### 15.10 Traceability

| Phase | Cases                     |
| :---- | :------------------------ |
| S2    | AT-01, AT-10 to AT-18     |
| S3    | AT-20 to AT-29, AT-63     |
| S4    | AT-30 to AT-35            |
| S5    | AT-40 to AT-42, AT-48     |
| S6    | AT-25, AT-29, AT-60       |
| S7    | AT-41 to AT-47, AT-50 to AT-55, AT-61, AT-62 |

## 16. Performance

Storage, 256 MB, fsync on writes, cold cache on reads:

| Target          | Write    | Read     |
| :-------------- | :------- | :------- |
| `/data` f2fs    | 154 MB/s | 459 MB/s |
| ext4 on loop    | 132 MB/s | 404 MB/s |
| tmpfs (v1 root) | 1.6 GB/s | 4.6 GB/s |

- Loop overhead is about 12 to 14 percent. Docker data stays on `/data`,
  so image pulls, layers, and volumes keep the f2fs path.
- Boot to `docker info`: about 2 s. A trivial container: about 0.9 s.
- Alpine Docker uses about 80 MB more RSS than the v1 static bundle
  (106 MB against 25 MB).
- veth ping RTT is 0.5 ms. veth is far above the Wi-Fi WAN.
- Namespaces add no runtime CPU cost. Extra work is one veth hop.

## 17. Risks

- `filter` and `mangle` commits fail from the Android root on this device,
  because of the vendor `quota2` and `CONNMARK` rules. All L0 iptables
  writes go through L1's mount namespace (6.2.1), and the boot self-test
  is the gate. The exact cause of the mount-namespace dependence is not
  yet identified. Never drop the self-test.
- A vendor daemon can re-add its rules at any time. The agent repairs the
  `PHOENIXD_*` hooks on the next tick, and it never flushes a foreign
  chain.
- The v1 egress through the proxy currently fails (`docker pull` returns
  `EOF`). Fix that before S4, or the pull test proves nothing.
- Docker cgroup v1 is deprecated (removal planned by May 2029). Keep v1
  for now. `docker info` also warns `No cpuset support`; `--cpus` and
  `--memory` work, `--cpuset-cpus` does not.
- Full-cone DNAT exposes all L1 ports. The default-deny L1 firewall is
  required.
- Without route mirroring, headless-off mode has no WAN.
- OpenRC's `cgroups` service is skipped in docker mode. Keep the
  `docker` init script patched to `need net`.
- Under `rc_sys="docker"`, OpenRC drops any service with `keyword -docker`
  from the dependency tree, together with its provides. Alpine's
  `networking` is such a service. Keep the `net` service, and do not add
  `net` to `rc_provide`.
- Alpine `iptables` is nft by default. Keep the legacy names ahead on the
  service `PATH`.
- Docker 29 defaults new installs to the containerd image store. Keep
  `--feature containerd-snapshotter=false` and `--storage-driver=overlay2`
  so the v1 overlay2 data stays visible.
- `/var/log` lives on the loop image. Keep the `log_proxy` rotation at 8 MB
  by 3 files, or the image fills with daemon logs.
- `reboot` inside L1 kills the L1 namespace, not the phone. The guards keep
  that stop clean and stop an accidental `reboot`.
- Loop image corruption after power loss. Run fsck at boot and keep
  backups.
- SELinux is disabled on this device, so the image files are not labelled
  and no policy blocks exec or overlay2. Re-check this if that changes.
- The v1 Docker data must stay at the same path and version for reuse.

## 18. Sources

- Alpine 3.24 aarch64 releases:
  `https://dl-cdn.alpinelinux.org/alpine/v3.24/releases/aarch64/`
- Alpine package index:
  `https://pkgs.alpinelinux.org/packages`
- Alpine 3.19 release notes (iptables-nft):
  `https://wiki.alpinelinux.org/wiki/Release_Notes_for_Alpine_3.19.0`
- systemd 256 NEWS (cgroup v1 off by default):
  `https://github.com/systemd/systemd/blob/v256/NEWS`
- systemd 258 release (cgroup v1 removed):
  `https://github.com/systemd/systemd/releases/tag/v258`
- NixOS 24.05 end of life:
  `https://end-of-life.org/nixos/24.05/`
- Docker cgroup v1 deprecation:
  `https://github.com/moby/moby/issues/51111`
- Docker Engine 29 release (containerd image store default):
  `https://www.docker.com/blog/docker-engine-version-29`
- OpenRC 0.63.2 source (`keyword` filtering in `librc-depend.c`; service
  environment from `conf.d` in `openrc-run.sh`):
  `https://github.com/OpenRC/openrc`
- Linux 4.14.336 `reboot_pid_ns()`:
  `kernel/pid_namespace.c` from
  `https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git`
