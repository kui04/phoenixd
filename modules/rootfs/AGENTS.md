# AGENTS.md

## Overview and layout

rootfs provides the persistent Layer 1 Linux container environment and service
supervision for the headless server. It creates a private mount namespace
(`unshare -m` + `pivot_root`) with a tmpfs root, cgroup v1 mounts, and runs
BusyBox `runit` (`runsvdir -P /service`) as the container supervisor. All Layer 1
services (`headless` Wi-Fi, `singbox`, `dockerd`) register their run scripts
under `/data/adb/rootfs/service/<name>` and run inside this container.

- `module/` is the zip root.
  - `module/module.prop`: module id, version, integer `versionCode`.
  - `module/customize.sh`: installer. Copies `files/busybox` to
    `/data/adb/rootfs/bin`, sets up applet symlinks, installs `rootfs-service`
    and `rootfs-exec` wrappers, requests a hot install.
  - `module/service.sh` (late_start), `module/action.sh`,
    `module/uninstall.sh`, `module/hotinstall.sh`.
  - `module/scripts/start.sh`: namespace validation, tmpfs root setup,
    cgroup v1 mounts, `pivot_root`, and `runsvdir` exec.
  - `module/scripts/control.sh`: container and supervisor lifecycle
    (start, stop, restart, status, log).
  - `module/scripts/rootfs-service.sh`: wrapper installed in
    `/data/adb/ksu/bin/rootfs-service`.
  - `module/scripts/rootfs-exec.sh`: wrapper installed in
    `/data/adb/ksu/bin/rootfs-exec` to enter the container namespace.
  - `module/scripts/cleanup.sh`: uninstall cleanup.
  - `module/scripts/settings.sh`: default DNS configuration.
  - `module/files/busybox`: build artifact, gitignored.
  - `module/files/lib/`, `module/files/share/`: hardware acceleration drivers
    from `flake.nix` (`.#layer1-drivers`, see root [AGENTS.md](../../AGENTS.md)),
    gitignored.
- `build.sh`: takes static `busybox` (`.#layer1-bin`) and `layer1-drivers`
  from the root `flake.nix`, writes `dist/rootfs-<version>.zip`.
- Runtime tree: `/data/adb/rootfs` with `bin/`, `lib/` (drivers), `share/`
  (Vulkan ICD), `service/`, `root/` (tmpfs root), `run/` (`rootfs.pid`,
  `rootfs.log`), and `settings.sh`.

Requirements: KernelSU Next 3.4.2 or newer, arm64, Android 14 (or Android 13+).
Kernel options: mount namespaces (`CONFIG_NAMESPACES`), cgroup v1 (`cpu`,
`memory`, `blkio`, `devices`, `freezer`, `pids`), tmpfs.

## Install and usage

- Build: `./build.sh` (needs `bash`, `nix`, `zip`, `sha256sum`).
- Install: push the zip, then
  `/data/adb/ksu/bin/ksud module install dist/rootfs-<version>.zip`.
- Control: `rootfs-service start|stop|restart|status|log [lines]`.
- Execute a command inside the container: `rootfs-exec <command> [args...]`.

## Commands

- Build: `./build.sh`.
- Lint: `nix run nixpkgs#shellcheck -- -s busybox module/*.sh module/scripts/*.sh`
  and `nix run nixpkgs#shellcheck -- -s bash build.sh`.
- Syntax check: `nix run nixpkgs#busybox -- ash -n <file>`.
- Format: `beautysh -i 2 -s paronly --variable-style braces`.

## Architecture invariants

- Run `start.sh` only under `busybox unshare -m --propagation private`. Never
  run it in the host namespace.
- Use `pivot_root`, not `chroot`.
- The root filesystem is a 64 MB tmpfs. Host paths (`/data`, `/sdcard`,
  `/storage`, `/system`, `/apex`, `/vendor`) are bind mounted into it.
- `start.sh` mounts `/data/adb/rootfs/lib` to `/lib` and
  `/data/adb/rootfs/share/vulkan` to `/usr/share/vulkan` in the container.
- `setup_device_permissions` in `start.sh` grants `0666` permissions to GPU
  and codec nodes for container access (see root [AGENTS.md](../../AGENTS.md)).
- Keep the `/sys` bind mount in the container for BPF filters and netd.
- Never mount `cpuset` inside the container because Android mounts it with
  `noprefix`.
- Do not isolate the PID namespace: Layer 1 runs in the host PID namespace so
  Android tools, cgroups, and Docker `--pid=host` work directly.
- The primary supervisor process is `runsvdir -P /service`. Services are
  controlled with `sv up|down|status /data/adb/rootfs/service/<name>`.

## Uninstall

- Removing the module runs `uninstall.sh` -> `cleanup.sh`: stops the
  supervisor, exits monitored services, cleans up cgroup directories, removes
  `/data/adb/rootfs` and `/data/adb/ksu/bin` wrappers.

## Licenses

This module is MIT-licensed. Bundled BusyBox is GPL-2.0.
