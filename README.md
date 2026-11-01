# Xiaomi Phoenix Server

A project to transform a Redmi K30 (`phoenix`, Qualcomm SM7150) device into a headless Linux server using KernelSU Next, Alpine Linux, Nix, and Docker Engine.

## System Architecture

The architecture uses three decoupled layers to run server workloads:

1. **Layer 0 (Host)**:
   - Stock Android Linux kernel and minimal vendor hardware daemons
     (`cnss-daemon`, `rmtfs`, `pd-mapper`, `tftp_server`).
   - Android PID 1 (`init`), `vold`, and Keymaster HAL for File-Based
     Encryption (FBE) data decryption.
   - Android UI stack (`zygote`, `system_server`, `surfaceflinger`, media) stops
     after boot to free RAM and eliminate wakeups.

2. **Layer 1 (Pivot Root Container)**:
   - Linux environment inside a private mount namespace (`unshare -m` +
     `pivot_root`).
   - Shared host network namespace for direct `wlan0` access via static
     `wpa_supplicant` and `udhcpc` under `runsvdir` (`modules/headless`).
   - Manages policy routing (`ip rule`) and firewall rules (`MASQUERADE`,
     `FORWARD`).
   - Hosts system daemons including `sing-box` proxy and `dockerd` Engine.

3. **Layer 2 (Docker Containers)**:
   - User application workloads running as standard Docker containers.
   - Isolated and orchestrated by the Docker Engine in Layer 1.

4. **KernelSU Next Modules**:
   - `modules/headless`: Headless host setup. Stops UI services, manages Wi-Fi with static `wpa_supplicant` and `udhcpc` under `runsvdir`, and configures policy routing for containers.
   - `modules/dockerd`: Static Docker Engine (arm64) running inside the Layer 1 private pivoted namespace with cgroup v1 mounts.
   - `modules/singbox`: sing-box transparent proxy using TUN interface (`tun0`) and `/system/bin/iptables` redirection.

## Repository Layout

```
.
├── AGENTS.md            # Coding agent instructions and workspace rules
├── README.md            # Project overview and architecture documentation
├── .envrc               # direnv configuration for Nix development environment
├── flake.nix            # Nix flake for reproducible static payloads and tools
├── .gitignore           # Git ignore patterns for build artifacts
└── modules/
    ├── dockerd/         # KernelSU Next module for Docker Engine
    ├── headless/        # KernelSU Next module for headless Wi-Fi and services
    └── singbox/         # KernelSU Next module for sing-box proxy
```

## Prerequisites

- **Hardware**: Redmi K30 (`phoenix`, SM7150).
- **Kernel**: Linux 4.14.336-Aluminum (or compatible kernel with namespaces, cgroups v1, overlayfs, tun, iptables).
- **OS**: Android 14 (BlissROM) with KernelSU Next 3.4.2+.
- **Host Tools**: `nix` (with flakes enabled), `bash`, `curl`, `tar`, `xz`, `zip`, `sha256sum`, `adb`.

## Building Modules

Each module contains an independent `build.sh` script:

```bash
# Build headless module
cd modules/headless && ./build.sh && cd ../..

# Build dockerd module
cd modules/dockerd && ./build.sh && cd ../..

# Build singbox module
cd modules/singbox && ./build.sh && cd ../..
```

The output zip packages are written to `modules/<module>/dist/`.

## Installing on Connected Device

Ensure ADB is connected and authorized:

```bash
# Install dockerd
adb push modules/dockerd/dist/dockerd-29.9.2.zip /data/local/tmp/
adb shell su -c "/data/adb/ksu/bin/ksud module install /data/local/tmp/dockerd-29.9.2.zip"

# Install singbox
adb push modules/singbox/dist/singbox-1.14.3.zip /data/local/tmp/
adb shell su -c "/data/adb/ksu/bin/ksud module install /data/local/tmp/singbox-1.14.3.zip"
```

## Licenses

- Individual modules contain their respective license files and adhere to upstream software licenses.
