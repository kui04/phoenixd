# AGENTS.md

## Overview and layout

dockerd packages the official static Docker Engine as a KernelSU Next
module. The daemon executes in the Layer 1 pivot root container provided by
`modules/rootfs` (`unshare -m` + `pivot_root` + cgroup v1 mounts) and runs under
the container supervisor (`runsvdir -P /service`). It creates and manages Layer 2
Docker containers for user applications. It relies on Layer 1 network rules
(`modules/headless`) for host policy routing and container egress.

- `module/` is the zip root.
  - `module/module.prop`: module id, version, integer `versionCode`.
  - `module/customize.sh`: installer. Extracts `files/docker.tar.xz` into
    `/data/adb/dockerd`, installs wrappers, requests a hot install.
  - `module/service.sh` (late_start), `module/boot-completed.sh`,
    `module/action.sh`, `module/uninstall.sh`, `module/hotinstall.sh`.
  - `module/scripts/start.sh`: storage bind mount, dockerd exec in rootfs.
    `net.sh` (ndc), `cleanup.sh` (uninstall), `control.sh`
    (start/stop/status/log), `settings.sh` (defaults).
  - `module/files/`: build artifacts (`docker.tar.xz`, `busybox`), gitignored.
- `build.sh`: downloads the Docker static tarball, takes BusyBox from the
  root `flake.nix` (`.#layer1-bin`, pinned by `flake.lock`), writes
  `dist/dockerd-<version>.zip`.
- Runtime tree on the device: `/data/adb/dockerd` with `bin/`, `data/` (engine
  root `/var/lib/docker`: images, containers, volumes, networks, buildkit),
  `config/` (CLI config, `auth.json`, `cli-plugins`), `run/` (socket, pid, logs),
  `settings.sh`, `daemon.json`.
- Wrappers `docker` and `dockerd-service` are installed in
  `/data/adb/ksu/bin`, which root shells get in `PATH`.

Requirements: KernelSU Next 3.4.2 or newer (hot install), arm64, Android 14 (or Android 13+).
Kernel options: namespaces (PID, IPC, UTS, NET, USER), cgroup v1 (cpu, memory,
blkio, devices, freezer, pids), OVERLAY_FS, VETH, BRIDGE, NETFILTER,
IP_NF_IPTABLES, IP_NF_FILTER, IP_NF_NAT, IP_NF_TARGET_MASQUERADE, IP6_NF_NAT,
IP6_NF_TARGET_MASQUERADE, SYSVIPC.

## Install and usage

- Install `dist/dockerd-<version>.zip` in the KernelSU Next manager. Hot
  install starts the daemon; otherwise reboot or run `dockerd-service start`.
- Without the wrapper path: `export PATH=/data/adb/dockerd/bin:$PATH`.
- Daily commands: `docker version`, `docker run --rm hello-world`,
  `docker ps -a`, `docker logs -f NAME`, `docker exec -it NAME sh`.
- Settings: `/data/adb/dockerd/settings.sh` (`STORAGE_DRIVER`, `BRIDGE`,
  `BRIDGE_SUBNET`, `PROXY`) and `/data/adb/dockerd/daemon.json` (registry
  mirrors, log options). DNS is configured in `/data/adb/rootfs/settings.sh`.
  `dockerd-service restart` applies changes. `daemon.json` must not contain
  `hosts`. Scripts keep the same defaults, so a missing `settings.sh` does not
  break them. `BRIDGE_SUBNET` becomes `--bip` for the default bridge; the
  gateway is the first host address.
- CLI plugins go to `/data/adb/dockerd/config/cli-plugins` as `docker-compose`
  and `docker-buildx`. The build always bundles both, from `COMPOSE_VERSION`
  and `BUILDX_VERSION` tags, cached in `.cache/`.
- The `docker` wrapper exports `SSL_CERT_FILE` from
  `config/ca-certificates.crt` (concatenated at install from
  `/apex/com.android.conscrypt/cacerts` or `/system/etc/security/cacerts`) and
  `HTTP(S)_PROXY` from `PROXY`. Static Go binaries find no CA store and no
  `/etc/resolv.conf` on Android, so client-side calls fail without both:
  BuildKit metadata (`docker build`, `buildx build`), `docker login`. `push` and
  `pull` run in the daemon, which reads its own bundle inside the pivoted root.
  Caller-set `SSL_CERT_FILE`, `SSL_CERT_DIR` or proxy variables win.

## Commands

Build needs `bash`, `curl`, `tar`, `xz`, `zip`, `sha256sum`.

- Build the zip: `./build.sh` (writes `dist/dockerd-<version>.zip` and
  syncs `version`/`versionCode` in the zip only).
- Pin versions: set `DOCKER_VERSION`, `COMPOSE_VERSION` and `BUILDX_VERSION`
  before `./build.sh`.
- Verify downloads: set `DOCKER_SHA256`, `COMPOSE_SHA256`
  and `BUILDX_SHA256` before `./build.sh`. BusyBox is checked by `flake.lock`.
- Build needs the flake files in git (`git add flake.nix flake.lock`). Set
  `LAYER1_BIN` to a `layer1-bin` output path to skip `nix build`.
- Install on a connected device:
  `adb push dist/dockerd-<version>.zip /data/local/tmp/` then
  `adb shell su -c "/data/adb/ksu/bin/ksud module install /data/local/tmp/dockerd-<version>.zip"`.
- Control the daemon: `dockerd-service start|stop|restart|status|log [lines]`.
- Smoke test: `docker run --rm hello-world`.
- Format: Strictly follow the Google Shell Style Guide. Format scripts with
  `beautysh -i 2 -s paronly --variable-style braces` (see root `AGENTS.md`).
- Lint: `nix run nixpkgs#shellcheck -- -s busybox module/*.sh module/scripts/*.sh`
  and `nix run nixpkgs#shellcheck -- -s bash build.sh`. ShellCheck reads
  centralized directives from root `.shellcheckrc`.
- Syntax check a script: `nix run nixpkgs#busybox -- ash -n <file>`.
- Residue audit after cleanup: `ls /data/adb/dockerd`,
  `iptables -S | grep -c DOCKER`, `iptables -t nat -S | grep -ci docker`,
  `ip -o link show | grep -cE 'docker0|br-'`, `ls -d /dev/*/docker`,
  `cat /proc/sys/net/ipv4/ip_forward`, `ps -A | grep -cE 'dockerd|containerd'`.
  All must be 0 or empty.
- There is no test suite or linter. The build and the device smoke test are the
  checks.

## Architecture invariants

- Keep `module/` free of a `system/` directory. Mounting `/system` requires a
  metamodule. The CLI is exposed through `/data/adb/ksu/bin` wrappers instead.
- `start.sh` must run inside the Layer 1 container (`modules/rootfs`). Running
  it in the host namespace is refused by `check_namespace`.
- The container supervisor (`runsvdir -P /service`) manages `dockerd` via
  `/service/dockerd`.
- Inside the container, `/var/lib/docker` is bind mounted to
  `/data/adb/dockerd/data` to maintain persistence across container reboots.
- Keep the `/sys` bind in the pivoted root. netd filter rules use
  `-m bpf --object-pinned /sys/fs/bpf/...`, and iptables reopens those objects on
  every table write. Without `/sys`, writes fail with
  `No chain/target/match by that name`.
- Never mount `cpuset`. Android mounts it with `noprefix`, which makes runc
  write to the wrong path. `--cpus` works; `--cpuset-cpus` does not.
- `-v` paths are resolved inside the pivoted root. Host paths must be bind
  mounted there (`/data`, `/sdcard`, `/storage` are). The root is a tmpfs, which
  keeps the `/data` bind from recursing.
- All engine state stays under `/data/adb/dockerd`. Do not add write paths
  outside that directory, except `/data/adb/dockerd_ip_forward`, which keeps the
  pre-Docker `ip_forward` value for cleanup.
- Never chmod or chown the data directory. `customize.sh` sets permissions on
  `bin`, `config/cli-plugins` and the `config/ca-certificates.crt` file only.
- `control.sh start` removes a stale `docker.sock` and pid file before it
  launches `start.sh`, and refuses to start when any daemon of this module is
  alive (check the exe path, including a `(deleted)` suffix).
- `uninstall.sh` must call `scripts/cleanup.sh`. Cleanup stops the daemon,
  kills processes left in Docker cgroups, removes DOCKER iptables rules with
  `-w`, ndc registrations, bridge links and cgroup directories, restores the
  saved `ip_forward`, and deletes the data directory. Keep it idempotent and safe
  to run when the daemon is already stopped.
- `versionCode` in `module.prop` is an integer: `major*10000 + minor*100 +
patch` of `DOCKER_VERSION` (29.9.2 -> 290902).
- The KernelSU installer may leave module scripts at 0644. Call them with
  `sh <path>`; never rely on the exec bit.

## Networking

- Default bridge `docker0` on `BRIDGE_SUBNET`. `-p` uses iptables DNAT because
  `--userland-proxy=false`.
- `net.sh` waits for the socket, the bridge and an upstream route, sets
  `ip_forward`, refreshes the ndc interface registration, adds the subnet route
  and the ipfwd pair. `control.sh start` runs it after every start and
  `boot-completed.sh` runs it again. Do not call `net.sh` from `service.sh`.
- `--network=host` shares the Android netns and needs no ndc route.
- Custom networks from `docker network create` are not registered with netd.
  Add `ndc network route add local br-<id> <subnet>` by hand.

## Hardware Acceleration (GPU and Video Decode)

Docker containers can access Adreno 618 GPU acceleration and MSM hardware video
decoding by mounting Layer 1 drivers from `/data/adb/rootfs`.

- **Configuration Template**: See
  [module/etc/docker-compose.hardware-accel.yml](module/etc/docker-compose.hardware-accel.yml)
  for device mappings, volume mounts, and environment variables.
- **Operational Boundaries**: See root
  [AGENTS.md](../../AGENTS.md#operational-boundaries) for driver provisioning,
  encoding constraints (`/dev/video33`), and headless Wayland compositor
  requirements (`WLR_RENDERER=pixman`).

## Troubleshooting

- Daemon log: `dockerd-service log 100` or
  `/data/adb/dockerd/run/dockerd.log`. The KernelSU Action button prints the
  status and the last log lines.
- TLS "certificate has expired or is not yet valid": set the clock with
  `date MMDDhhmmCCYY.ss`.
- Pulls time out: check `PROXY` in `settings.sh` and the device uplink.
- `overlay2` errors: set `STORAGE_DRIVER=vfs` and restart.
- `--cpuset-cpus` is unsupported. `-m`, `--pids-limit` and `--cpus` work.

## Uninstall

- Removing the module in the manager runs `uninstall.sh` -> `cleanup.sh`:
  stops processes, deletes DOCKER iptables chains and NAT rules, removes ndc
  registrations and bridge links, removes cgroup directories, restores
  `ip_forward`, deletes `/data/adb/dockerd` (including all images) and the
  `/data/adb/ksu/bin` wrappers.
- Empty cgroup v1 hierarchies for devices, freezer and pids stay in
  `/proc/cgroups` until reboot. They hold no processes or mounts. Reboot after
  uninstall for a clean kernel state. Do not reboot from a script.

## Device workflow and boundaries

- Test target: Redmi K30 (phoenix), kernel 4.14.336-Aluminum-v1.0-ksun, Android 14
  (BlissROM), KernelSU Next 3.4.2.
- Hot install replaces the module without a reboot; `customize.sh` stops the
  running daemon first. Keep `MODULE_HOT_INSTALL_REQUEST` and the no-`system/`
  rule together.
- Ask before bumping `DOCKER_VERSION`, changing default `STORAGE_DRIVER` or
  `BRIDGE`, or running `ksud module uninstall dockerd` (it deletes
  `/data/adb/dockerd`, including all images).
- Never commit `module/files/*`, `.cache/`, `dist/`, or a built zip; they are
  gitignored.

## Licenses

This repository is MIT-licensed; see `LICENSE`. Bundled binaries keep their
upstream licenses: Docker Engine, containerd and runc are Apache-2.0; BusyBox is
GPL-2.0 (built from nixpkgs, source at busybox.net).
