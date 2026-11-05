# AGENTS.md

## Purpose and state

rootfs provides the Layer 1 host: Alpine 3.24 on an ext4 loop image, BusyBox
init, OpenRC, and the Docker engine. Layer 0 (Android) keeps the kernel, the
firmware daemons, and `wlan0`.

Implemented: image lifecycle, launcher, OpenRC, the Layer 0 network agent,
the iptables objects, the DNS forwarder, and the host supervisor. Docker is
`PLAN.md` phase S4, the `headless` Wi-Fi handover is S5, and sing-box is S6.

## Build, install, control

- Build: `./build.sh`. The flake sees only git-tracked files, so a new file
  under `module/` or `src/` needs `git add` before the build can use it.
- Install: `/data/adb/ksu/bin/ksud module install dist/rootfs-<version>.zip`.
  The installer stops a running Layer 1, so run `rootfs-service start` after
  an install.
- Control: `rootfs-service start|stop|restart|status|log [lines]`,
  `rootfs-service host start|stop|status`, and `rootfs-service image
  create|fsck|resize|backup|restore|status|update`.
- Lint: `nix run nixpkgs#shellcheck -- -s busybox module/*.sh
  module/scripts/*.sh` and `-s bash build.sh`. Format:
  `nix run nixpkgs#beautysh -- -i 2 -s paronly --variable-style braces`.
  Syntax: `nix run nixpkgs#busybox -- ash -n <file>`.

## Image invariants

- Attach the image with `losetup -f`, which asks `/dev/loop-control` for a new
  device. After a boot Android holds every existing node, and `losetup -a`
  cannot open them, so neither a node scan nor `losetup -f` output parsing is
  reliable on its own.
- Identify an attached image by the device and inode in
  `/sys/block/loop*/loop/backing_file`. The path printed by `losetup` is the
  path of the attach call and can be relative.
- Refuse every image operation while the image is attached, mounted, or
  Layer 1 runs. A `losetup -d` on a busy device only marks it for autoclear,
  so a start that fails can leave a node unusable until the phone reboots.
- Mount `/proc` inside the chroot before `apk`. musl emulates
  `fchmodat(AT_SYMLINK_NOFOLLOW)` through `/proc/self/fd`, so without it apk
  cannot set the setuid bits and exits 4.
- Divide before multiplying, or use `awk`: Android shell arithmetic is 32-bit
  and an image exceeds 2 GB.
- Keep one image of free space on `/data`. `create` and `resize` refuse when
  they would leave less.
- The image build is offline: `apk add --no-network` installs the local cache.
  The overlay comes last, because apk protects `/etc`.
- Build the zip with `-y`, and add runlevels with `rc-update` in the chroot.
  The KernelSU installer drops the executable bit and can turn a symlink into
  a regular file, so `customize.sh` sets the modes of the overlay scripts.

## Runtime invariants

- Join the netns `l1` before the other namespaces. `unshare -p -f` makes
  `launch.sh` PID 1, and it must not return: it execs init.
- The `net` service owns the address (`ifup -i /etc/network/interfaces eth0`).
  When the address is missing, `net` fails and Docker does not start.
- A PID inside the namespace is 1. `l1_pid` finds init by the netns and the
  command line `/sbin/init`; do not use a PID file.
- Android's `nsenter` has no `-r`, so `exec` and `shell` use the module
  BusyBox `nsenter -t <pid> -m -u -i -n -p -r -w`.
- Mount `/dev` as a tmpfs with `dev,suid`. `/data` is `nodev`, so a device
  node stored on the image cannot be opened.
- After `pivot_root` and `umount -l /.oldroot`, Layer 1's mount namespace has
  no `/system`. Anything that must run with Layer 1's mounts needs its binary
  inside the image.
- Write the Layer 0 iptables objects with **Android's** `/system/bin/iptables`
  from the Android root. It has the vendor `quota2` match built in; Alpine's
  iptables cannot replay the vendor filter table and fails with `No
  chain/target/match by that name`. The mount namespace is not the cause.
- Point `192.168.0.0/16`, `172.16.0.0/12`, and `10.0.0.0/8` at the main table
  (prefs 8950 to 8952), as v1 did. A reply to a LAN host needs the connected
  route of `wlan0`; table 9500 has only the mirrored default, so the reply
  leaves through the gateway and never arrives.
- The proxy path is `veth0 -> tun0`, so `PHOENIXD_FWD` needs its own accept
  pair for `veth0 <-> tun+`. Without it the forwarded packet dies in FORWARD
  and the nat counters stay at zero.
- sing-box needs `stack: gvisor` and `auto_redirect: false` here. With the
  system stack it expects a nat REDIRECT that needs nf_tables, and this
  kernel has none, so only its OUTPUT chain appears and forwarded TCP never
  reaches the proxy.
- The DNS forwarder binds `10.0.0.1:53` only and returns an empty answer for
  AAAA and HTTPS. Never bind `INADDR_ANY`: full-cone DNAT would expose it.
- Host services live under `${ROOTFS_HOME}/host-service/<name>/run` and run in
  the foreground under `runsvdir`. `runsvdir` starts `runsv` by name, so
  `${ROOTFS_HOME}/bin` is on `PATH` and holds the applet links.
- Name the netns binary as `${IP}` (`/system/bin/ip`), do not rely on `PATH`.
  BusyBox ships an `ip` applet without `netns`, so a wrong `PATH` order turns
  `ip netns add l1` into a usage message and Layer 1 never starts.
- Keep `/system/bin` before `${ROOTFS_HOME}/bin` on `PATH`. BusyBox has a small
  `ip` applet without `netns`, and the first match wins, so `ip netns add l1`
  fails at boot when the module bin comes first.
- `state/network` decides what the agent does: `up` converges, `down`
  removes. Write it before you expect either behavior.
- The `headless` module owns the `wifi`, `charge`, and `display` host
  services, and the `singbox` module owns `singbox`. This module owns `network`
  and `dns` only.
- SELinux is `Enforcing` on this device. Do not disable it: loop attach,
  mounts, and namespaces work as they are.
- `rootfs-service stop` reads the mount namespace of the supervisor before it
  stops it, then ends every process of that namespace. Without this step a
  containerd of the old instance keeps the exclusive `flock` on
  `containerd/daemon/io.containerd.metadata.v1.bolt/meta.db`, and the next
  dockerd waits for a response that never comes.
- `start` and `init.d/docker` check that lock with `flock -n` and stop with an
  explicit message. Do not delete the containerd directory to clear it: an old
  instance can still hold the unlinked inode and write to the same overlay
  directories.
- `image restore` writes every block, so the sparse file becomes fully
  allocated. Recreate the image or accept the allocation when space matters.
- An uninstall keeps `alpine.img` and `mounts.d/`, and prints both paths.
- `ROOTFS_HOME` overrides the runtime directory. A spike uses it, so that a
  running installation stays untouched.

## Licenses

This module is MIT-licensed. Bundled BusyBox is GPL-2.0. The Alpine packages
keep their own licenses.
