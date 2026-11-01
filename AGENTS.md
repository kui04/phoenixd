# AGENTS.md

## Repository Overview

`xiaomi_phoenix_server` is a monorepo for transforming a Redmi K30 (`phoenix`, Qualcomm SM7150) device running Android 14 (BlissROM) and KernelSU Next 3.4.2 into a headless Linux server.

The workspace is organized into modules:

- `modules/rootfs/`: Layer 1 Linux pivot root container and runsvdir supervisor with cgroup v1. (See [modules/rootfs/AGENTS.md](file:///home/kui04/Workspace/xiaomi_phoenix_server/modules/rootfs/AGENTS.md)).
- `modules/dockerd/`: Static Docker Engine running under Layer 1 rootfs. (See [modules/dockerd/AGENTS.md](file:///home/kui04/Workspace/xiaomi_phoenix_server/modules/dockerd/AGENTS.md)).
- `modules/headless/`: Headless Linux server setup. Stops the Android UI stack and manages Wi-Fi under rootfs. (See [modules/headless/AGENTS.md](file:///home/kui04/Workspace/xiaomi_phoenix_server/modules/headless/AGENTS.md)).
- `modules/singbox/`: sing-box transparent proxy using TUN interface and iptables redirect under rootfs. (See [modules/singbox/AGENTS.md](file:///home/kui04/Workspace/xiaomi_phoenix_server/modules/singbox/AGENTS.md)).

## System Architecture Layers

The server operates in three decoupled architecture layers:

- **Layer 0 (Host)**:
  - Stock Android Linux kernel (4.14.336-Aluminum) and Android PID 1 (`init`).
  - Essential vendor hardware daemons (`cnss-daemon`, `rmtfs`, `pd-mapper`,
    `tftp_server`).
  - File-Based Encryption (FBE) data decryption and hardware radio drivers
    (`qcacld-3.0`).
  - Native vendor daemons stay active; Android UI stack (`zygote`,
    `surfaceflinger`, media) stops after boot (`modules/headless`).
- **Layer 1 (Pivot Root Container)**:
  - Persistent Linux container environment created with `unshare -m` and
    `pivot_root` (`modules/rootfs`).
  - Runs container supervisor (`runsvdir -P /service`) on a tmpfs root with
    cgroup v1 mounts.
  - Shares host network namespace to manage `wlan0` directly without Android
    `netd`.
  - Runs Wi-Fi under supervisor with static `wpa_supplicant` and `udhcpc`
    (`modules/headless`).
  - Configures policy routing (`ip rule add pref 9500 lookup main`) and
    iptables rules (`MASQUERADE`, `FORWARD`).
  - Hosts system daemons: transparent proxy (`sing-box`) and the Docker
    daemon (`dockerd`).
- **Layer 2 (Docker Containers)**:
  - User applications and workloads running as standard Docker containers.
  - Executed and managed by the Layer 1 Docker Engine.

## Shell Code Standards

All shell scripts must strictly follow the [Google Shell Style Guide](https://google.github.io/styleguide/shellguide.html):

- **Indentation**: Exactly 2 spaces per indentation level. No tabs.
- **Line Length**: Maximum 80 columns.
- **Function Definitions**: Use `name() { ... }` format. Do not use the `function` keyword.
- **Program Flow**: Standalone scripts must provide an explicit `main "$@"` entrypoint.
- **Variables**: Always expand variables with braces `${var}` and explicit quoting `"${var}"`.
- **Target Interpreters**:
  - Device scripts (`module/*.sh`, `module/scripts/*.sh`): POSIX `sh` for Android `/system/bin/sh` (mksh) and BusyBox ash.
  - Host build scripts (`build.sh`): `#!/usr/bin/env bash` with `set -euo pipefail`.
- **Prose Style**: Write all prose in ASD-STE100 (Simplified Technical English).
- **No Emojis**: Do not use emojis in code, commits, comments, or documentation.

## Formatting and Linting

### 1. Code Formatting (`beautysh`)

All shell scripts are formatted with `beautysh` (configured for 2-space indentation, no `function` keyword, and braced variables):

```bash
# Check formatting across all shell scripts
nix run nixpkgs#beautysh -- --check -i 2 -s paronly --variable-style braces \
  modules/rootfs/build.sh modules/rootfs/module/*.sh modules/rootfs/module/scripts/*.sh \
  modules/dockerd/build.sh modules/dockerd/module/*.sh modules/dockerd/module/scripts/*.sh \
  modules/headless/build.sh modules/headless/module/*.sh modules/headless/module/scripts/*.sh modules/headless/module/scripts/service/*.sh \
  modules/singbox/build.sh modules/singbox/module/*.sh modules/singbox/module/scripts/*.sh

# Format files in-place
nix run nixpkgs#beautysh -- -i 2 -s paronly --variable-style braces \
  modules/rootfs/build.sh modules/rootfs/module/*.sh modules/rootfs/module/scripts/*.sh \
  modules/dockerd/build.sh modules/dockerd/module/*.sh modules/dockerd/module/scripts/*.sh \
  modules/headless/build.sh modules/headless/module/*.sh modules/headless/module/scripts/*.sh modules/headless/module/scripts/service/*.sh \
  modules/singbox/build.sh modules/singbox/module/*.sh modules/singbox/module/scripts/*.sh
```

`beautysh` covers indentation, function style, and braces on named variables
only. Review these rules by hand: 80 columns, pipeline layout, control flow,
and quoting. `beautysh` also changes `$_` to `${_}`, although the guide prefers
`_=$_` unbraced.

### 2. Static Analysis (`shellcheck`)

Global ShellCheck configurations are centralized in `.shellcheckrc` at the
repository root.

- All warning exclusions (`SC1091`, `SC2034`, `SC2154`, `SC2086`, `SC2016`)
  are defined in `.shellcheckrc`.
- Do not write `# shellcheck` directives inside individual shell scripts.

Run ShellCheck:

```bash
# Lint device scripts as busybox ash (automatically uses root .shellcheckrc)
nix run nixpkgs#shellcheck -- -s busybox \
  modules/rootfs/module/*.sh \
  modules/rootfs/module/scripts/*.sh \
  modules/dockerd/module/*.sh \
  modules/dockerd/module/scripts/*.sh \
  modules/headless/module/*.sh \
  modules/headless/module/scripts/*.sh \
  modules/headless/module/scripts/service/*.sh \
  modules/singbox/module/*.sh \
  modules/singbox/module/scripts/*.sh

# Lint Bash build scripts
nix run nixpkgs#shellcheck -- -s bash \
  modules/rootfs/build.sh \
  modules/dockerd/build.sh \
  modules/headless/build.sh \
  modules/singbox/build.sh
```

### 3. Syntax Verification (`busybox ash`)

Verify that POSIX scripts parse cleanly under BusyBox ash:

```bash
for f in modules/rootfs/module/*.sh modules/rootfs/module/scripts/*.sh \
         modules/dockerd/module/*.sh modules/dockerd/module/scripts/*.sh \
         modules/headless/module/*.sh modules/headless/module/scripts/*.sh modules/headless/module/scripts/service/*.sh \
         modules/singbox/module/*.sh modules/singbox/module/scripts/*.sh; do
  nix run nixpkgs#busybox -- ash -n "$f"
done
```

## Operational Boundaries

- **Git Commit Boundary**: Never stage or commit changes without explicit user approval.
- **Hardware Boundary**: Do not stop Qualcomm vendor daemons (`cnss-daemon`, `rmtfs`, `pd-mapper`) or Android init PID 1.
- **Filesystem Boundary**: Never commit files in `.cache/`, `dist/`, or downloaded binary payloads in `module/files/`.
