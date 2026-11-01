# AGENTS.md

## Overview and layout

singbox runs sing-box 1.14.3 as a KernelSU Next module in Layer 1 with
transparent TUN proxying inside the `modules/rootfs` container under
`runsvdir` (`/service/singbox`). The daemon creates and manages `tun0`, captures
traffic with `auto_route` and `auto_redirect`, and routes packets based on the
single configuration file at `/data/adb/singbox/config.json`.

- `module/` is the zip root.
  - `module/module.prop`: module id, version, integer `versionCode`.
  - `module/customize.sh`: installer. Copies `files/sing-box` to
    `/data/adb/singbox/bin`, keeps an existing live config, installs the
    `singbox-service` wrapper, requests a hot install.
  - `module/service.sh` (late_start), `module/action.sh` (status and log),
    `module/uninstall.sh`, `module/hotinstall.sh`.
  - `module/scripts/control.sh`: start, stop, restart, status, log, check.
  - `module/scripts/singbox-service.sh`: wrapper installed in
    `/data/adb/ksu/bin`, execs the module copy of `control.sh`.
  - `module/etc/config.json`: generic template config without private credentials.
  - `module/files/sing-box`: build artifact, gitignored.
- `build.sh`: downloads the official `android-arm64` release into `.cache/`,
  stages the binary, writes `dist/singbox-<version>.zip`.
- Runtime tree: `/data/adb/singbox` with `bin/sing-box`, `config.json`
  (0600) and `run/` (`singbox.pid`, `singbox.log`, `cache.db`).

Requirements: KernelSU Next 3.4.2 or newer (hot install), arm64, Android 14 (or
Android 13+), `/dev/net/tun`, `/system/bin/iptables` with the legacy backend. The Android
binary is dynamically linked to `/system/bin/linker64` and needs Android 6 or
newer. The test kernel has no `nf_tables`; the module does not need it.

## Install and usage

- Build: `./build.sh`. Pin with `SINGBOX_VERSION`, verify with
  `SINGBOX_SHA256`.
- Install: push the zip, then
  `/data/adb/ksu/bin/ksud module install <zip>`. The hot install hook starts
  sing-box without a reboot.
- Control: `singbox-service start|stop|restart|status|log [lines]|check`.
- Check: `singbox-service check` to validate `/data/adb/singbox/config.json`.

## Commands

- Build: `./build.sh` (needs `bash`, `curl`, `tar`, `zip`, `sha256sum`).
- Lint: `nix run nixpkgs#shellcheck -- -s busybox module/*.sh module/scripts/*.sh`
  and `nix run nixpkgs#shellcheck -- -s bash build.sh`. ShellCheck reads
  centralized directives from root `.shellcheckrc`.
- Syntax check: `nix run nixpkgs#busybox -- ash -n <file>`.
- Format: Strictly follow the Google Shell Style Guide. Format scripts with
  `beautysh -i 2 -s paronly --variable-style braces` (see root `AGENTS.md`).
- There is no test suite. The build and the device smoke test are the checks.

## Architecture invariants

- Keep `module/` free of a `system/` directory. The binary runs from `/data`;
  no overlay or metamodule is needed.
- `control.sh` registers the daemon under `/data/adb/rootfs/service/singbox` and
  starts it with `sv up`. The daemon executes in the foreground under `runsv`
  inside the `modules/rootfs` container.
- `is_running` checks `/proc/<pid>/exe` against the module binary, not just
  `kill -0`, because a stale pid may be reused.
- `start` runs `sing-box check` with the same `-D` and `-c` first and refuses a
  broken config. Keep the check before launch.
- `stop` sends SIGTERM and waits up to 15 seconds. sing-box removes `tun0`, its
  `ip rule` entries and its iptables chains during shutdown. SIGKILL leaves the
  chains; the next start cleans them at `AutoRedirect.Start`.
- `runsv` supervises the process and restarts it if it crashes.
- Each start moves `singbox.log` to `singbox.log.1`. `wait_started` looks for
  `sing-box started` in the fresh log; a log level above info falls back to
  "process alive after 10 s".
- Configuration file lives exclusively at `/data/adb/singbox/config.json`.
- Keep `auto_redirect` on. On Android sing-box uses `/system/bin/iptables`
  (`-t nat -I OUTPUT` with `-o tun0` and a local redirect server) and does not
  touch nftables. On this device the chain setup produced three nat and three
  filter rules.
- Keep the `api` service on `127.0.0.1:9090`. A dashboard in the phone browser
  uses it; no firewall rule is needed.
- The installer wipes `$MODPATH` on upgrade but only copies
  `etc/config.json` to the live path when `/data/adb/singbox/config.json` is missing.
  Never copy it unconditionally; it holds the user's config.
- The KernelSU installer may leave module scripts at 0644. Call them with
  `sh <path>`; never rely on the exec bit.

## Networking

- `tun0`, `172.19.0.1/30`, `fdfe:dcba:9876::1/126`, stack `system`.
- Sniff plus hijack-dns handle DNS that enters the tun.
- Do not run a `VpnService` VPN app at the same time. This config does not set
  `override_android_vpn`.

## Troubleshooting

- Status: `singbox-service status`; log: `singbox-service log 100`; the Action
  button prints both.
- Start refused: `singbox-service check` prints the parse error.
- Started but no traffic: check `ip -o link show tun0`, `ip rule`,
  `iptables -t nat -S | grep -c sing`, and the log for `missing default
interface`.
- Config edit: validate with `singbox-service check`, then restart.

## Uninstall

- Removing the module runs `uninstall.sh`: `stop` (SIGTERM, cleanup), removes
  `/data/adb/ksu/bin/singbox-service` and `/data/adb/singbox`.
- `stop` before removal matters: a SIGKILLed daemon would leave iptables chains
  until the next start of any copy of the module.

## Device workflow and boundaries

- Test target: Redmi K30 (phoenix), kernel 4.14.336-Aluminum-v1.0-ksun, Android 14
  (BlissROM), KernelSU Next 3.4.2 (ksud 3.4.2-94-gb462d4c1, uapi 6), arm64.
- Drive the device with `adb`.
- Never commit `module/files/sing-box`, `.cache/`, `dist/` or a built zip.

## Licenses

The bundled sing-box binary is GPL-3.0; see
https://github.com/SagerNet/sing-box. The module scripts follow the repository
owner's choice.
