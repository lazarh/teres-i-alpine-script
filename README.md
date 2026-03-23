# teres-i-alpine-script

Build scripts for [Olimex Teres-I](https://github.com/OLIMEX/DIY-LAPTOP) — a DIY AArch64 laptop based on the Allwinner A64 SoC — producing a minimal Alpine Linux image with dwl (Wayland compositor) as the window manager.

![Teres-I running Alpine Linux with dwl](screenshot.png)

Builds everything from source: ARM Trusted Firmware, U-Boot, Linux kernel, and an Alpine Linux arm64 rootfs. No Yocto, no binary blobs beyond firmware files.

---

## Hardware

| Component | Details |
|---|---|
| SoC | Allwinner A64 (ARM Cortex-A53, 4-core, AArch64) |
| RAM | 2 GiB LPDDR3 |
| Display | 11.6" 1366×768 IPS eDP panel via ANX6345 bridge |
| Storage | Internal eMMC (8/16 GiB) + microSD slot |
| WiFi | AP6212 (BCM43438, `brcmfmac`) or RTL8723BS (`rtl8723bs`) depending on board revision |
| Bluetooth | BCM or RTL (SDIO/UART, same chip as WiFi) |
| Audio | Allwinner A64 internal codec — headphone jack + analog output |
| Battery | AXP803 PMIC with AXP20X battery/charger kernel drivers |
| Camera | CSI camera connector (optional) |
| USB | 2× USB-A (EHCI/OHCI) |
| Serial | 3.5mm audio jack debug UART at `ttyS0 115200` |

---

## What gets built

| Component | Version / Details |
|---|---|
| ARM Trusted Firmware | v2.10.0, `sun50i_a64` platform |
| U-Boot | 2024.01, `teres_i_defconfig` |
| Kernel | 6.12.18 LTS, `arm64 defconfig` + `configs/kernel/teres-i.config` |
| Alpine Linux | 3.21, arm64 minirootfs bootstrap |
| Init system | OpenRC |
| Window manager | dwl (wlroots-based Wayland compositor) |
| Terminal | foot |
| Launcher | wmenu |
| Browser | Firefox ESR (Wayland-native) |
| Editor | neovim |

---

## Prerequisites

An x86-64 build host running Debian or Ubuntu with:
- `aarch64-linux-gnu-gcc` cross toolchain
- `qemu-user-static` (for chroot package install)
- `binfmt_misc` support

Install everything needed:
```bash
sudo scripts/install-deps.sh
```

---

## Building

Run these steps in order:

### 1. Build U-Boot
```bash
scripts/build-uboot.sh
```
Downloads ARM Trusted Firmware and U-Boot, compiles both, produces:
- `build/uboot/u-boot-sunxi-with-spl.bin` — combined SPL + TF-A BL31 + U-Boot
- `build/uboot/boot.scr` — U-Boot boot script

### 2. Build the kernel
```bash
scripts/build-kernel.sh
```
Produces:
- `build/kernel/Image` — uncompressed AArch64 kernel
- `build/kernel/sun50i-a64-teres-i.dtb` — device tree
- `build/kernel/modules/` — kernel modules

### 3. Build the Alpine rootfs
```bash
sudo scripts/build-rootfs.sh
```
Bootstraps Alpine 3.21 arm64 minirootfs, installs packages via `apk`, configures services, and installs kernel modules. Produces `alpine-rootfs/`.

Optional environment variables (must be set **after** `sudo`):
```bash
# Customize hostname (default: teres-i)
sudo BOARD_HOSTNAME="mylaptop" scripts/build-rootfs.sh

# Pre-configure WiFi so it connects on first boot
sudo WIFI_SSID="MyNetwork" WIFI_PASSWORD="mypassword" scripts/build-rootfs.sh
```

> **Note:** Variables placed *before* `sudo` are stripped by sudo's environment sanitization.

### 4. Assemble the SD card image
```bash
sudo scripts/assemble-sd-image.sh
```
Produces:
- `teres-i-alpine.img.gz` — compressed flashable image
- `teres-i-alpine.img.gz.bmap` — bmaptool sparse map (when bmaptool is available)

### 5. Flash to SD card
```bash
# Fast (sparse-aware, recommended):
bmaptool copy teres-i-alpine.img.gz /dev/sdX

# Alternative:
zcat teres-i-alpine.img.gz | sudo dd of=/dev/sdX bs=4M status=progress conv=fsync
```

### 6. First boot and install to eMMC

Insert the SD card, power on the Teres-I and wait for login. Then as root:
```bash
install-to-nand.sh
```
This partitions the internal eMMC (`/dev/mmcblk2`), writes U-Boot raw at offset 8 KiB, copies boot files to a FAT32 partition, and copies the rootfs to ext4. Remove the SD card and reboot to run from eMMC.

---

## Default credentials

| Account | Username | Password |
|---|---|---|
| Root | `root` | `root` |
| Default user | `user` | `user` |

The `user` account is created on first boot with sudo access via the `wheel` group.

**Change both passwords immediately after first boot.**

Serial console is available on `ttyS0` at 115200 baud via the 3.5mm audio jack.

---

## WiFi

WiFi is managed by `wpa_supplicant` + `dhcpcd`. No D-Bus required.

### Connect to a network
```bash
# Add a network and apply immediately
wpa_passphrase "MyNetwork" "mypassword" >> /etc/wpa_supplicant/wpa_supplicant.conf
wpa_cli -i wlan0 reconfigure
```

Or interactively:
```bash
wpa_cli -i wlan0
> scan
> scan_results
> add_network
> set_network 0 ssid "MyNetwork"
> set_network 0 psk "mypassword"
> enable_network 0
> save_config
```

`dhcpcd` picks up the IP automatically once `wpa_supplicant` associates. DNS is configured via `openresolv` from the DHCP lease, with `1.1.1.1` / `8.8.8.8` as fallback.

---

## Desktop

dwl (a wlroots-based Wayland compositor) starts automatically on `tty1` login. Audio is initialized by the startup script when dwl launches (deferred from boot to avoid disrupting the debug serial UART). GTK applications use the Adwaita dark theme. Firefox is configured to run natively under Wayland.

| Keybind | Action |
|---|---|
| `Alt+Shift+Return` | Open terminal (foot) |
| `Alt+P` | wmenu application launcher |
| `Alt+Shift+Q` | Quit dwl |
| `Alt+1..9` | Switch tag/workspace |

### Seat management

Seat management is handled by `seatd`. The `seatd` service is enabled at boot and provides unprivileged access to input devices and DRM for the Wayland compositor. Users in the `seat` group can start a compositor without root.

### Audio
```bash
# Initialize audio (also called automatically when dwl starts)
teres-audio-setup

# Check ALSA card and controls
aplay -l
amixer -c 0 controls
```

### Brightness
```bash
# Increase / decrease backlight
brightnessctl set +10%
brightnessctl set 10%-
```

### Battery
```bash
teres-battery
# Battery: 87% (Discharging)
# Voltage: 3.92V  Current: 450mA
# AC: disconnected
```

---

## System services (OpenRC)

| Service | Runlevel | Purpose |
|---|---|---|
| `check-edp` | default | Reboots if eDP display not detected on cold boot (A64 eDP cold-start workaround) |
| `resize-rootfs` | default | Expands root partition to fill the storage device on first boot |
| `setup-user` | default | Creates `user` account with sudo on first boot, then removes itself |
| `rfkill-unblock` | default | Unblocks WiFi/Bluetooth rfkill before `wpa_supplicant` starts |
| `seatd` | default | Seat management daemon — provides unprivileged access to DRM/input for Wayland |
| `wpa_supplicant` | boot | WiFi authentication daemon |
| `dhcpcd` | default | DHCP client — assigns IP and configures DNS via openresolv |
| `sshd` | default | SSH server (root login enabled; change password before exposing to network) |
| `chronyd` | default | NTP time synchronization |

---

## Storage layout

### SD card / eMMC partitions

| Region | Content |
|---|---|
| Raw offset 8 KiB | U-Boot SPL + TF-A BL31 + U-Boot proper (raw, no partition) |
| Partition 1 — FAT32, 40–120 MiB | `/boot` — `Image`, DTB, `boot.scr`, `u-boot-sunxi-with-spl.bin` |
| Partition 2 — ext4, rest | `/` — Alpine rootfs (auto-expands to fill device on first boot) |

### U-Boot vs Linux MMC numbering

On this board the MMC controllers are numbered differently by U-Boot and Linux:

| Controller | U-Boot | Linux |
|---|---|---|
| microSD slot | `mmc 0` | `/dev/mmcblk0` |
| SDIO WiFi | `mmc 2` | (no block device) |
| Internal eMMC | `mmc 1` | `/dev/mmcblk2` |

The SD boot script loads from `mmc 0:1`, the eMMC boot script from `mmc 1:1`.

---

## Kernel configuration

The kernel is built from `arm64 defconfig` merged with `configs/kernel/teres-i.config`. Key additions:

| Area | Options |
|---|---|
| Firmware loading | `FW_LOADER_COMPRESS_ZSTD` — loads Alpine's `.zst` firmware natively |
| Display | `DRM_SUN4I`, `DRM_SUN6I_DSI`, `DRM_SUN8I_MIXER`, `DRM_ANALOGIX_ANX6345`, `DRM_PANEL_EDP` all built-in |
| GPU | `DRM_LIMA` (Mali-400 MP2) as module |
| WiFi | `BRCMFMAC` + `RTL8723BS` as modules |
| Audio | `SND_SUN8I_CODEC`, `SND_SUN8I_CODEC_ANALOG`, `SND_SUN4I_I2S` as modules |
| Battery | `POWER_SUPPLY`, `BATTERY_AXP20X`, `CHARGER_AXP20X` |
| Power | `MFD_AXP20X` built-in, `AXP20X_POWER` built-in |

---

## Known issues and workarounds

### eDP display cold boot
The ANX6345 eDP bridge sometimes fails to initialize on a cold power-on. The `check-edp` OpenRC service detects this at boot by reading `/sys/class/drm/card0-Unknown-1/status` and reboots automatically if the display is not connected. A warm reboot always succeeds.

### Serial UART via audio jack
The debug serial port is accessible via the 3.5mm headphone jack using a USB-to-serial adapter wired to the UART rings. The Allwinner A64 audio codec analog driver (`snd_sun8i_codec_analog`) reconfigures the analog output path when it loads, disrupting the UART signal. Audio modules are therefore **not loaded at boot** — they are loaded on demand by `teres-audio-setup` which is called automatically when dwl starts.

### WiFi firmware compression
Alpine packages firmware as `.zst` compressed files. The kernel needs `CONFIG_FW_LOADER_COMPRESS_ZSTD=y` to load them natively (enabled in `teres-i.config`). The rootfs build script also decompresses all firmware to plain files as a fallback for kernels built without that option.

---

## Patches

Place `.patch` files in:
- `patches/uboot/` — applied to U-Boot source before building
- `patches/kernel/` — applied to kernel source before building

Patches are applied in filename order with `patch -p1`. No patches are currently required for U-Boot 2024.01 or kernel 6.12.18.

---

## Cross-compiler override

```bash
CROSS_COMPILE=aarch64-unknown-linux-gnu- scripts/build-uboot.sh
CROSS_COMPILE=aarch64-unknown-linux-gnu- scripts/build-kernel.sh
```

Parallel jobs default to `$(nproc)`. Override with `JOBS=N`.

---

## Repository structure

```
scripts/
  install-deps.sh       — install build dependencies on the host
  build-uboot.sh        — build TF-A + U-Boot
  build-kernel.sh       — cross-compile the kernel
  build-rootfs.sh       — bootstrap Alpine rootfs, install packages + services
  assemble-sd-image.sh  — assemble bootable .img from build artifacts
  install-to-nand.sh    — install SD image to internal eMMC (runs on device)

configs/
  kernel/teres-i.config — kernel config fragment for Teres-I hardware

services/
  check-edp.openrc      — OpenRC eDP cold-boot workaround service
  check-edp.sh          — eDP detection helper
  resize-rootfs.openrc  — first-boot root partition resize service
  setup-user.openrc     — first-boot user creation service
  teres-audio-setup.sh  — ALSA mixer init (called when dwl starts)
  teres-battery.sh      — battery status via AXP803 sysfs

boot/
  boot.cmd              — U-Boot boot script source (SD card)

patches/
  uboot/                — U-Boot patches (currently empty)
  kernel/               — kernel patches (currently empty)
```
