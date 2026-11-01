# AGENTS.md

## Overview and layout

headless sets up the headless host (Layer 0) and network control runtime for
the Layer 1 pivot root container. The module stops the Android UI stack and
media services after boot, preserves Layer 0 hardware daemons (`cnss-daemon`,
`rmtfs`, `pd-mapper`, `tftp_server`), and runs Wi-Fi under the shared Layer 1
supervisor (`modules/rootfs`) with static `wpa_supplicant` and `udhcpc`. It
configures policy routing and firewall rules so Layer 2 Docker containers can
access the network.

- `module/` is the zip root.
  - `module/module.prop`: module id, version, integer `versionCode`.
  - `module/customize.sh`: installer. Copies static binaries to
    `/data/adb/headless/bin`, installs wrappers and configuration templates,
    requests a hot install.
  - `module/boot-completed.sh` (boot entry), `module/action.sh` (status and
    log), `module/uninstall.sh`, `module/hotinstall.sh`.
  - `module/scripts/control.sh`: start, stop, restart, status, log.
  - `module/scripts/headless-service.sh`: wrapper installed in
    `/data/adb/ksu/bin`, execs the module copy of `control.sh`.
  - `module/scripts/net.sh`: policy routing (`ip rule`) and iptables rules for
    Docker egress without Android `netd`.
  - `module/scripts/dhcp-event.sh`: `udhcpc` event handler for address and
    default route assignment.
  - `module/scripts/service/`: runit service definitions for `wifi` and `dhcp`.
  - `module/etc/wifi.conf`: template configuration for `wpa_supplicant`.
  - `module/files/`: build artifacts (`busybox`, `wpa_supplicant`, `wpa_cli`,
    `iw`), gitignored.
- `build.sh`: takes static binaries from the root `flake.nix` (`.#layer1-bin`,
  pinned by `flake.lock`), writes `dist/headless-<version>.zip`.
- Runtime tree: `/data/adb/headless` with `bin/` (`busybox`, `wpa_supplicant`,
  `wpa_cli`, `iw`, `runsv`, `runsvdir`, `sv`), `wifi.conf` (0600),
  `settings.sh` (0644), and `run/` (`headless.log`, `wpa/`). Services are
  registered under `/data/adb/rootfs/service/wifi` and
  `/data/adb/rootfs/service/dhcp`.

Requirements: KernelSU Next 3.4.2 or newer, arm64, Android 14 (or Android 13+).
Qualcomm WLAN driver (`qcacld-3.0` / `icnss`) initialized by `cnss-daemon`.

## Install and usage

- Build: `./build.sh`. Takes binaries from `flake.nix`. Set `LAYER1_BIN` to
  point to a prebuilt `layer1-bin` output to skip `nix build`.
- Configure: edit `/data/adb/headless/wifi.conf` with your SSID and PSK.
- Install: push the zip, then
  `/data/adb/ksu/bin/ksud module install <zip>`.
- Control: `headless-service start|stop|restart|status|log [lines]`.
- Watchdog: if Wi-Fi fails to get an IP address within `WIFI_TIMEOUT` (default
  60 seconds), the module restores Android services automatically to prevent
  loss of access.

## Commands

- Build: `./build.sh` (needs `bash`, `nix`, `zip`, `sha256sum`).
- Lint: `nix run nixpkgs#shellcheck -- -s busybox module/*.sh module/scripts/*.sh module/scripts/service/*.sh`
  and `nix run nixpkgs#shellcheck -- -s bash build.sh`. ShellCheck reads
  centralized directives from root `.shellcheckrc`.
- Syntax check: `nix run nixpkgs#busybox -- ash -n <file>`.
- Format: Strictly follow the Google Shell Style Guide. Format scripts with
  `beautysh -i 2 -s paronly --variable-style braces` (see root `AGENTS.md`).
