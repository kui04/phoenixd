# phoenixd

`phoenixd` transforms a Redmi K30 (`phoenix`, Qualcomm SM7150) device into a
headless Linux server. The system uses Android 14 (BlissROM), KernelSU Next,
a Layer 1 Linux pivot root container, static Docker Engine, transparent network
proxying, and automated battery charge control.

## System Architecture

The server operates in three decoupled architecture layers:

### Layer 0: Android Host and Vendor Daemons

- **Linux Kernel**: Stock Android Linux kernel (4.14.336-Aluminum) with
  namespaces, cgroups v1, overlayfs, tun, and iptables.
- **Boot and Decryption**: Android PID 1 (`init`), `vold`, and Keymaster HAL
  decrypt the File-Based Encryption (FBE) userdata partition at boot.
- **Qualcomm Hardware Services**: Essential vendor daemons stay active to run
  the Wi-Fi and modem radio subsystems:
  - `cnss-daemon`: Loads Wi-Fi firmware over QRTR sockets.
  - `rmtfs`: Remote Filesystem Service for RF calibration partitions.
  - `pd-mapper` and `tftp_server`: Protection domain mapper and firmware transfer.
- **Headless Optimization**: After Android signals `sys.boot_completed=1`,
  `modules/headless` stops the Android UI stack (`zygote`, `system_server`,
  `surfaceflinger`, `audioserver`, `cameraserver`, `mediaserver`). This stops
  display output, stops background wakeups, and frees 1.5 GB to 3+ GB of RAM.
  Anonymous memory drops to approximately 66 MB.

### Layer 1: Pivot Root Container and Supervisor

- **Isolation**: `modules/rootfs` unshares the mount namespace (`unshare -m`)
  and executes `pivot_root` into a 64 MB tmpfs root filesystem.
- **Cgroups**: Mounts cgroup v1 hierarchies (`cpu`, `memory`, `blkio`,
  `devices`, `freezer`, `pids`) under `/sys/fs/cgroup`.
- **Host Bind Mounts**: Binds `/proc`, `/dev`, `/sys`, `/data`, `/sdcard`,
  `/system`, `/vendor`, and `/apex` into the container.
- **Supervisor**: Runs BusyBox `runit` (`runsvdir -P /service`) as the service
  supervisor inside the container.
- **Networking**: Shares the host network namespace. Layer 1 directly controls
  the `wlan0` Wi-Fi interface without Android `netd`.
- **System Services**:
  - `wifi`: Static `wpa_supplicant` 2.12 controls `wlan0` through `nl80211`.
  - `dhcp`: Static `udhcpc` acquires DHCP leases and configures routes.
  - `charge`: Monitors battery capacity and controls charging current.
  - `singbox`: Runs `sing-box` transparent proxy with `tun0` interface.
  - `dockerd`: Runs static Docker Engine 29.9.2 with container isolation.

### Layer 2: Docker Containers

- **Workloads**: User applications run as standard Docker containers.
- **Orchestration**: Managed by Docker Engine, Docker Compose, and Docker Buildx.
- **Network Routing**: Receives full internet connectivity through Layer 1
  policy routing (`ip rule add pref 9500 lookup main`) and iptables NAT rules
  (`MASQUERADE`, `FORWARD`).

## KernelSU Next Modules

The workspace contains four decoupled KernelSU Next modules:

| Module             | Description                                              | Control CLI                     |
| :----------------- | :------------------------------------------------------- | :------------------------------ |
| `modules/rootfs`   | Layer 1 pivot root container and `runsvdir` supervisor   | `rootfs-service`, `rootfs-exec` |
| `modules/headless` | Headless setup, Wi-Fi management, and battery protection | `headless-service`              |
| `modules/singbox`  | Transparent TUN proxy using sing-box                     | `singbox-service`               |
| `modules/dockerd`  | Static Docker Engine, Compose, and Buildx                | `dockerd-service`, `docker`     |

### Battery Charge Control

`modules/headless` includes a battery protection service (`charge.sh`) for
continuous 24/7 server operation:

- **Hysteresis Thresholds**: Reads `/sys/class/power_supply/battery/capacity`
  every 60 seconds. Suspends charging when capacity reaches 65%
  (`CHARGE_STOP_LEVEL`). Resumes charging when capacity drops to 50%
  (`CHARGE_START_LEVEL`).
- **Slow Charging**: Disables fast charging via
  `/sys/class/qcom-battery/restrict_chg` and limits charging current to 1.2 A
  (`CHARGE_RESTRICT_CUR=1200000`). This keeps battery temperature low and
  prevents battery swelling.
- **Safety Fallback**: Restores normal Android charging settings when the
  service stops or when you uninstall the module.

### Watchdog Recovery

If Wi-Fi fails to connect and obtain an IP address within 60 seconds
(`WIFI_TIMEOUT`), the `headless` watchdog restores Android services
(`surfaceflinger`, `zygote`) automatically. This prevents loss of device
access.

## Repository Layout

```
.
├── AGENTS.md            # Agent instructions and workspace rules
├── README.md            # Project overview and architecture documentation
├── flake.nix            # Nix flake for static aarch64 payloads and tools
├── flake.lock           # Pinned Nixpkgs inputs
├── .envrc               # direnv configuration for Nix environment
├── .shellcheckrc        # Centralized ShellCheck configuration
├── SHELL_GUIDE.md       # Google Shell Style Guide reference
└── modules/
    ├── rootfs/          # Layer 1 pivot root container and runsvdir supervisor
    ├── headless/        # Headless server, Wi-Fi supervisor, and charge control
    ├── singbox/         # sing-box transparent TUN proxy
    └── dockerd/         # Static Docker Engine, Compose, and Buildx
```

## Prerequisites

- **Hardware**: Redmi K30 4G / 5G (`phoenix`, Qualcomm SM7150).
- **Kernel**: Linux 4.14.336-Aluminum (or compatible kernel with namespaces,
  cgroups v1, overlayfs, tun, iptables).
- **OS**: Android 14 (BlissROM) with KernelSU Next 3.4.2+.
- **Host Workstation**: Nix with flakes enabled (or `bash`, `curl`, `tar`,
  `xz`, `zip`, `sha256sum`, `adb`).

## Building Modules

Each module has a standalone `build.sh` script. You can build individual modules
or build all modules:

```bash
# Build Layer 1 rootfs container module
(cd modules/rootfs && ./build.sh)

# Build headless host and Wi-Fi management module
(cd modules/headless && ./build.sh)

# Build sing-box transparent proxy module
(cd modules/singbox && ./build.sh)

# Build Docker Engine module
(cd modules/dockerd && ./build.sh)
```

Each build script packages the installable zip file into `modules/<name>/dist/`.

## Installation and Setup

### 1. Installation Sequence

Install the modules in this order:

1. **`rootfs`**: Provides the Layer 1 container environment and supervisor.
2. **`headless`**: Stops the Android UI and manages Wi-Fi and charging.
3. **`singbox`** (Optional): Provides transparent proxying.
4. **`dockerd`**: Provides Docker container runtime.

### 2. Device Installation via ADB

Connect the device over USB ADB:

```bash
# 1. Install rootfs module
adb push modules/rootfs/dist/rootfs-0.1.0.zip /data/local/tmp/
adb shell su -c "/data/adb/ksu/bin/ksud module install /data/local/tmp/rootfs-0.1.0.zip"

# 2. Configure Wi-Fi credentials before starting headless
adb shell su -c "cat << 'EOF' > /data/adb/headless/wifi.conf
ctrl_interface=/data/adb/headless/run/wpa
update_config=1

network={
    ssid=\"YOUR_WIFI_SSID\"
    psk=\"YOUR_WIFI_PASSWORD\"
}
EOF"
adb shell su -c "chmod 600 /data/adb/headless/wifi.conf"

# 3. Install headless module
adb push modules/headless/dist/headless-0.1.0.zip /data/local/tmp/
adb shell su -c "/data/adb/ksu/bin/ksud module install /data/local/tmp/headless-0.1.0.zip"

# 4. Install sing-box module (optional)
adb push modules/singbox/dist/singbox-1.14.3.zip /data/local/tmp/
adb shell su -c "/data/adb/ksu/bin/ksud module install /data/local/tmp/singbox-1.14.3.zip"

# 5. Install dockerd module
adb push modules/dockerd/dist/dockerd-29.9.2.zip /data/local/tmp/
adb shell su -c "/data/adb/ksu/bin/ksud module install /data/local/tmp/dockerd-29.9.2.zip"
```

## Device CLI Management

The modules install CLI wrappers into `/data/adb/ksu/bin`, which is available in
the root `PATH`:

### Rootfs Container

- Check status: `rootfs-service status`
- View logs: `rootfs-service log 50`
- Execute commands inside the container: `rootfs-exec <command> [args...]`

### Headless Server and Wi-Fi

- Control: `headless-service {start|stop|restart|status|log [lines]}`
- Check service status: `headless-service status`
- View service logs: `headless-service log`

### sing-box Transparent Proxy

- Control: `singbox-service {start|stop|restart|status|log [lines]|check}`
- Validate configuration: `singbox-service check`

### Docker Engine

- Control daemon: `dockerd-service {start|stop|restart|status|log [lines]}`
- Run Docker commands: `docker ps`, `docker run -d --restart=always nginx`

## Code Standards and Verification

All shell scripts follow the Google Shell Style Guide:

- **Formatting**: Scripts use 2-space indentation, no `function` keyword, and
  braced variable expansions (`${var}`). Format scripts with `beautysh`.
- **Static Analysis**: Lint scripts with ShellCheck (`.shellcheckrc`).
- **Syntax Check**: Verify scripts parse cleanly under BusyBox ash.

See [AGENTS.md](AGENTS.md)
for exact lint and format commands.

## Licenses

Each module adheres to the licenses of its upstream software components. See
individual module directories for license files.
