# Teres-I — Alpine Linux + DWM Build System

Build ARM Trusted Firmware, U-Boot, Linux kernel, and an Alpine Linux arm64
root filesystem with DWM (suckless window manager) for the
[Olimex Teres-I](https://github.com/OLIMEX/DIY-LAPTOP) DIY laptop
(Allwinner A64 / sun50i-a64, ARM Cortex-A53 AArch64).

No Yocto required — everything is built via direct cross-compilation and
Alpine minirootfs bootstrap.

## Quick Start

### 1. Install build dependencies (once, as root)
```bash
sudo scripts/install-deps.sh
```

### 2. Build ARM Trusted Firmware + U-Boot
```bash
scripts/build-uboot.sh
```
Downloads and compiles TF-A BL31 for `sun50i_a64`, then builds U-Boot with
`teres_i_defconfig`.  Produces:
- `build/uboot/u-boot-sunxi-with-spl.bin`
- `build/uboot/boot.scr`

### 3. Build the kernel
```bash
scripts/build-kernel.sh
```
Produces:
- `build/kernel/Image`
- `build/kernel/sun50i-a64-teres-i.dtb`
- `build/kernel/modules/`

### 4. Build the Alpine rootfs (as root)
```bash
sudo scripts/build-rootfs.sh
```
Produces `alpine-rootfs/`.

To pre-configure the hostname or WiFi:
```bash
# Set hostname at image build time (defaults to 'teres-i')
sudo BOARD_HOSTNAME="mylaptop" scripts/build-rootfs.sh

# Pre-configure WiFi (requires WIFI_PASSWORD)
sudo WIFI_SSID="MyNetwork" WIFI_PASSWORD="secret" scripts/build-rootfs.sh
```

### 5. Assemble the SD card image (as root)
```bash
# Default output image under repo root
sudo scripts/assemble-sd-image.sh

# Or specify an explicit output image path:
sudo scripts/assemble-sd-image.sh /path/to/output.img
```
Produces `teres-i-alpine.img.gz` (and `.bmap`).

### 6. Flash to SD card
```bash
# Preferred (fast, sparse-aware):
bmaptool copy teres-i-alpine.img.gz /dev/sdX

# Alternative:
zcat teres-i-alpine.img.gz | sudo dd of=/dev/sdX bs=4M status=progress conv=fsync
```

### 7. First boot — install to internal eMMC

Insert the SD card into the Teres-I and power on. After it boots, log in as root
and run:
```bash
install-to-nand.sh
```
This partitions the internal eMMC (`/dev/mmcblk2`), writes U-Boot at the 8 KiB
offset, copies boot files to a FAT32 partition, and copies the rootfs to an ext4
partition. Remove the SD card and reboot; the board will boot from eMMC.

## WiFi

WiFi is managed by **iwd**. Use `iwctl` to connect:

```bash
# List available networks
iwctl station wlan0 scan
iwctl station wlan0 get-networks

# Connect (enter passphrase when prompted)
iwctl station wlan0 connect "MyNetwork"

# Or connect with passphrase inline
iwctl --passphrase "mypassword" station wlan0 connect "MyNetwork"
```

iwd handles DHCP automatically (`EnableNetworkConfiguration=true`).
Known networks are saved in `/var/lib/iwd/` and reconnect automatically on next boot.

To pre-configure WiFi before the first boot, set these when building:
```bash
WIFI_SSID="MyNetwork" WIFI_PASSWORD="mypassword" sudo scripts/build-rootfs.sh
```

## Default credentials

| | |
|---|---|
| Root user | `root` / `root` |
| Default user | `user` / `user` (created on first boot, has sudo) |
| Serial console | `ttyS0 @ 115200` |

**Change passwords on first boot.**

## What's included

### Desktop environment
- **DWM** (dynamic window manager) — auto-starts on tty1 login
- **dmenu** — application launcher (Alt+P)
- **st** / terminal — suckless terminal
- **Xorg** with modesetting driver + Lima (Mali-400 GPU)

### Hardware support
- **Display**: ANX6345 eDP bridge, innolux 11.6" panel, eDP cold-boot workaround service
- **Audio**: ALSA with Allwinner A64 codec (headphone + line out), auto-configured on boot
- **Battery**: AXP803 PMIC monitoring via `teres-battery` command
- **Brightness**: `brightnessctl` command for backlight control
- **WiFi**: AP6212 (BCM43438) or RTL8723BS via iwd (`iwctl`)
- **Bluetooth**: BCM or RTL (SDIO/UART)

### System services (OpenRC)
- `check-edp` — reboots if eDP display not detected (cold boot workaround)
- `resize-rootfs` — expands root partition on first boot
- `setup-user` — creates `user` account with sudo on first boot
- `iwd` — WiFi management (use `iwctl` to connect)
- `sshd` — SSH server
- `chronyd` — NTP time sync

## SD card partition layout

| Region | Content |
|---|---|
| Raw offset 8 KiB | U-Boot SPL + TF-A BL31 + U-Boot proper |
| Partition 1 (FAT32, 80 MiB) | `/boot` — Image, DTB, boot.scr, u-boot-sunxi-with-spl.bin |
| Partition 2 (ext4, rest) | `/` — Alpine rootfs |

## eMMC layout (after `install-to-nand.sh`)

| Region | Content |
|---|---|
| Raw offset 8 KiB | U-Boot SPL + TF-A BL31 + U-Boot proper |
| Partition 1 (FAT32, 80 MiB) | `/boot` — Image, DTB, boot.scr |
| Partition 2 (ext4, rest) | `/` — Alpine rootfs |

Linux exposes the internal storage as `/dev/mmcblk2`, but U-Boot enumerates the
same controller as `mmc 1` on this board. The eMMC `boot.scr` therefore loads
the kernel from `mmc 1:1` and boots with
`root=/dev/mmcblk2p2 rootfstype=ext4`.

## Build configuration

| Item | Value |
|---|---|
| ARM Trusted Firmware | v2.10.0, `sun50i_a64` platform |
| U-Boot | 2024.01, `teres_i_defconfig` |
| U-Boot flash offset | 8 KiB (same as all sunxi boards) |
| Kernel | 6.12.18, arm64 `defconfig` + `configs/kernel/teres-i.config` |
| Kernel image | `Image` (uncompressed AArch64) |
| Kernel boot command | `booti` |
| DTB | `sun50i-a64-teres-i.dtb` |
| Cross-compiler | `aarch64-linux-gnu-` (override via `CROSS_COMPILE=`) |
| Parallel jobs | `$(nproc)` (override via `JOBS=N`) |
| Alpine version | 3.21, arm64 (minirootfs bootstrap) |
| Init system | OpenRC |
| Window manager | DWM (suckless) |
| WiFi | AP6212 (BCM43438, `brcmfmac`) or RTL8723BS (`rtl8723bs`) |
| Hostname pre-config | Optional — `BOARD_HOSTNAME=mylaptop` |
| WiFi pre-config | Optional — `WIFI_SSID=... WIFI_PASSWORD=...` |

## Patches

Place `.patch` files in:
- `patches/uboot/` — applied to U-Boot before building
- `patches/kernel/` — applied to the kernel before building

Patches are applied in filename order with `patch -p1`.

## Cross-compiler override

```bash
# Use a custom toolchain
CROSS_COMPILE=aarch64-unknown-linux-gnu- scripts/build-uboot.sh
```

## Notes on the Allwinner A64 boot process

Unlike 32-bit sunxi SoCs (A20, A80, etc.), the A64 requires ARM Trusted Firmware
(TF-A) BL31 as the secure-world monitor.  `build-uboot.sh` compiles TF-A
automatically and passes `BL31=` to the U-Boot build.  The resulting
`u-boot-sunxi-with-spl.bin` embeds SPL, BL31, and U-Boot proper in a single
binary that is written to offset 8 KiB — identical to all other sunxi boards.
