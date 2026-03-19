#!/bin/bash
# build-rootfs.sh — Bootstrap an Alpine Linux arm64 rootfs for Teres-I.
#
# Must be run as root on an x86-64 Debian/Ubuntu build host.
#
# Prerequisites:
#   1. scripts/install-deps.sh    (installs qemu-user-static, etc.)
#   2. scripts/build-kernel.sh    (produces build/kernel/modules/ and Image)
#
# Environment variables (must be passed AFTER sudo, not before):
#   sudo BOARD_HOSTNAME=myteres scripts/build-rootfs.sh
#   sudo WIFI_SSID=MyNetwork WIFI_PASSWORD=secret scripts/build-rootfs.sh
#
# Produces: alpine-rootfs/
# Consumed by: scripts/assemble-sd-image.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SYSROOT="${REPO_ROOT}/alpine-rootfs"
KERNEL_BUILD="${REPO_ROOT}/build/kernel"
MODULES_DIR="${KERNEL_BUILD}/modules"
BOARD_HOSTNAME="${BOARD_HOSTNAME:-teres-i}"
WIFI_SSID="${WIFI_SSID:-}"
WIFI_PASSWORD="${WIFI_PASSWORD:-}"

ALPINE_VERSION="3.21"
ALPINE_MIRROR="https://dl-cdn.alpinelinux.org/alpine"
ALPINE_ARCH="aarch64"
ALPINE_MINIROOTFS_URL="${ALPINE_MIRROR}/v${ALPINE_VERSION}/releases/${ALPINE_ARCH}/alpine-minirootfs-${ALPINE_VERSION}.0-${ALPINE_ARCH}.tar.gz"

# ── Helpers ────────────────────────────────────────────────────────────────

die() { echo "ERROR: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Must be run as root (chroot requires root)"

[[ -d "${KERNEL_BUILD}" ]] || die "build/kernel/ not found — run scripts/build-kernel.sh first"
[[ -f "${KERNEL_BUILD}/Image" ]] || die "build/kernel/Image not found — run scripts/build-kernel.sh first"

# Warn if the built kernel version stamp doesn't match the expected version
if [[ -f "${KERNEL_BUILD}/.kernel-version" ]]; then
    BUILT_KVER=$(cat "${KERNEL_BUILD}/.kernel-version")
    EXPECTED_KVER="6.12.18"
    if [[ "${BUILT_KVER}" != "${EXPECTED_KVER}" ]]; then
        echo "WARNING: build/kernel/ contains kernel ${BUILT_KVER}, expected ${EXPECTED_KVER}."
        echo "         Run scripts/build-kernel.sh to build the correct version."
        echo "         Continuing with ${BUILT_KVER} — press Ctrl-C within 5s to abort."
        sleep 5
    fi
fi

mount_chroot() {
    mount -t proc  proc     "${SYSROOT}/proc"
    mount -t sysfs sysfs    "${SYSROOT}/sys"
    mount --bind   /dev     "${SYSROOT}/dev"
    mount --bind   /dev/pts "${SYSROOT}/dev/pts"
    mount -t tmpfs tmpfs    "${SYSROOT}/run"
}

umount_chroot() {
    umount "${SYSROOT}/run"     2>/dev/null || true
    umount "${SYSROOT}/dev/pts" 2>/dev/null || true
    umount "${SYSROOT}/dev"     2>/dev/null || true
    umount "${SYSROOT}/sys"     2>/dev/null || true
    umount "${SYSROOT}/proc"    2>/dev/null || true
}

trap umount_chroot EXIT

command -v qemu-aarch64-static >/dev/null || die "qemu-user-static not found — run scripts/install-deps.sh"

# ── Download Alpine minirootfs ──────────────────────────────────────────────

SOURCES_DIR="${REPO_ROOT}/build/sources"
mkdir -p "${SOURCES_DIR}"
ALPINE_TARBALL="${SOURCES_DIR}/alpine-minirootfs-${ALPINE_VERSION}.0-${ALPINE_ARCH}.tar.gz"

if [[ ! -f "${ALPINE_TARBALL}" ]]; then
    echo "==> Downloading Alpine minirootfs ${ALPINE_VERSION} (${ALPINE_ARCH})..."
    curl -fL --progress-bar "${ALPINE_MINIROOTFS_URL}" -o "${ALPINE_TARBALL}"
fi

# ── Extract minirootfs ──────────────────────────────────────────────────────

if [[ -d "${SYSROOT}" && -f "${SYSROOT}/etc/alpine-release" ]]; then
    echo "==> Alpine rootfs already extracted, skipping."
else
    echo "==> Extracting Alpine minirootfs into ${SYSROOT}..."
    rm -rf "${SYSROOT}"
    mkdir -p "${SYSROOT}"
    tar -xzf "${ALPINE_TARBALL}" -C "${SYSROOT}"
fi

# Copy QEMU binary so the chroot can execute AArch64 binaries on x86
cp /usr/bin/qemu-aarch64-static "${SYSROOT}/usr/bin/"

# Copy host DNS config so apk can resolve hostnames inside the chroot.
# If the host uses systemd-resolved (127.0.0.53), use the upstream resolvers
# instead — the stub address is not reachable from inside a chroot.
if grep -q "^nameserver 127\." /etc/resolv.conf 2>/dev/null; then
    cp /run/systemd/resolve/resolv.conf "${SYSROOT}/etc/resolv.conf"
else
    cp /etc/resolv.conf "${SYSROOT}/etc/resolv.conf"
fi

mount_chroot

# ── Configure APK repositories ──────────────────────────────────────────────

echo "==> Configuring Alpine repositories..."
cat > "${SYSROOT}/etc/apk/repositories" <<EOF
${ALPINE_MIRROR}/v${ALPINE_VERSION}/main
${ALPINE_MIRROR}/v${ALPINE_VERSION}/community
EOF

# ── Configure the system ────────────────────────────────────────────────────

echo "==> Configuring Alpine system..."

echo "${BOARD_HOSTNAME}" > "${SYSROOT}/etc/hostname"
cat > "${SYSROOT}/etc/hosts" <<EOF
127.0.0.1  localhost
127.0.1.1  ${BOARD_HOSTNAME}
::1        localhost ip6-localhost ip6-loopback
EOF

# /etc/fstab for SD card boot; overwritten by install-to-nand.sh for eMMC boot
cat > "${SYSROOT}/etc/fstab" <<EOF
/dev/mmcblk0p2  /      ext4  defaults,noatime  0  1
/dev/mmcblk0p1  /boot  vfat  defaults          0  2
tmpfs           /tmp   tmpfs defaults,nosuid,nodev  0  0
EOF

# ── Install packages ────────────────────────────────────────────────────────
# Consolidate into one apk add call to avoid fetching APKINDEX repeatedly.

echo "==> Installing Alpine packages..."
chroot "${SYSROOT}" apk update

chroot "${SYSROOT}" apk add --no-cache \
    alpine-base openrc busybox-extras shadow sudo \
    eudev eudev-openrc \
    util-linux e2fsprogs dosfstools parted \
    rsync curl wget ca-certificates \
    kmod iproute2 iputils iptables nftables \
    wpa_supplicant dhcpcd \
    linux-firmware-brcm linux-firmware-rtlwifi \
    openssh chrony \
    xorg-server xf86-video-modesetting xinit xrandr xset setxkbmap \
    mesa-dri-gallium mesa-gl xf86-input-libinput \
    dwm dmenu \
    build-base libx11-dev libxft-dev libxinerama-dev \
    font-dejavu \
    alsa-utils alsa-lib \
    vim less htop \
    tzdata \
    cloud-utils-growpart

# Optional packages — install separately so failures don't abort the build
chroot "${SYSROOT}" apk add --no-cache st    || true
# `light` is not in Alpine 3.21 — use brightnessctl instead (same sysfs interface)
chroot "${SYSROOT}" apk add --no-cache brightnessctl || true
chroot "${SYSROOT}" apk add --no-cache font-noto || true

# ── Kernel modules ──────────────────────────────────────────────────────────

echo "==> Installing kernel modules from ${MODULES_DIR}..."
if [[ -d "${MODULES_DIR}/lib/modules" ]]; then
    mkdir -p "${SYSROOT}/lib/modules"
    cp -a "${MODULES_DIR}/lib/modules/"* "${SYSROOT}/lib/modules/"
    KVER=$(ls "${SYSROOT}/lib/modules/" | head -1)
    if ! chroot "${SYSROOT}" depmod -a "${KVER}" 2>/dev/null; then
        echo "    WARNING: depmod failed for kernel ${KVER} — modules may not load at boot"
    fi
    echo "    Installed modules for kernel ${KVER}"
else
    echo "    WARNING: No modules found in ${MODULES_DIR}/lib/modules"
fi

# ── WiFi firmware ───────────────────────────────────────────────────────────
# Teres-I uses AP6212 (BCM43438) or RTL8723BS depending on board revision.
# Load brcmfmac and rtl8723bs at boot so whichever chip is present is found.
# Audio modules are intentionally excluded — see audio setup section below.

mkdir -p "${SYSROOT}/etc/modules-load.d"
cat > "${SYSROOT}/etc/modules-load.d/teres-wifi.conf" <<EOF
brcmfmac
rtl8723bs
EOF

# Also add to /etc/modules for OpenRC
echo "brcmfmac"  >> "${SYSROOT}/etc/modules"
echo "rtl8723bs" >> "${SYSROOT}/etc/modules"

# ── SSH — allow root login ──────────────────────────────────────────────────

echo "==> Configuring sshd (PermitRootLogin yes, PasswordAuthentication yes)..."
sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' \
    "${SYSROOT}/etc/ssh/sshd_config"
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' \
    "${SYSROOT}/etc/ssh/sshd_config"

# ── Serial console ──────────────────────────────────────────────────────────
# Alpine uses /etc/inittab for getty management

echo "==> Configuring serial console (ttyS0)..."
if ! grep -q "ttyS0" "${SYSROOT}/etc/inittab" 2>/dev/null; then
    echo "ttyS0::respawn:/sbin/getty -L ttyS0 115200 vt100" >> "${SYSROOT}/etc/inittab"
fi

# ── Timezone ────────────────────────────────────────────────────────────────

# tzdata was installed in the main apk add block above
cp "${SYSROOT}/usr/share/zoneinfo/UTC" "${SYSROOT}/etc/localtime" || true
echo "UTC" > "${SYSROOT}/etc/timezone"

# ── OpenRC services ─────────────────────────────────────────────────────────

echo "==> Setting up OpenRC services..."

# eDP display check service (cold boot workaround)
install -m 0755 "${REPO_ROOT}/services/check-edp.openrc" \
    "${SYSROOT}/etc/init.d/check-edp"
chroot "${SYSROOT}" rc-update add check-edp default || true

# First-boot partition resize
install -m 0755 "${REPO_ROOT}/services/resize-rootfs.openrc" \
    "${SYSROOT}/etc/init.d/resize-rootfs"
chroot "${SYSROOT}" rc-update add resize-rootfs default || true

# First-boot user creation
install -m 0755 "${REPO_ROOT}/services/setup-user.openrc" \
    "${SYSROOT}/etc/init.d/setup-user"
chroot "${SYSROOT}" rc-update add setup-user default || true

# Enable standard services
chroot "${SYSROOT}" rc-update add devfs sysinit || true
chroot "${SYSROOT}" rc-update add dmesg sysinit || true
chroot "${SYSROOT}" rc-update add mdev sysinit || true
chroot "${SYSROOT}" rc-update add udev sysinit || true
chroot "${SYSROOT}" rc-update add udev-trigger sysinit || true
chroot "${SYSROOT}" rc-update add hwclock boot || true
chroot "${SYSROOT}" rc-update add modules boot || true
chroot "${SYSROOT}" rc-update add sysctl boot || true
chroot "${SYSROOT}" rc-update add hostname boot || true
chroot "${SYSROOT}" rc-update add bootmisc boot || true
chroot "${SYSROOT}" rc-update add syslog boot || true

chroot "${SYSROOT}" rc-update add sshd default || true
chroot "${SYSROOT}" rc-update add chronyd default || true
chroot "${SYSROOT}" rc-update add wpa_supplicant boot || true
chroot "${SYSROOT}" rc-update add dhcpcd default || true
chroot "${SYSROOT}" rc-update add local default || true

chroot "${SYSROOT}" rc-update add mount-ro shutdown || true
chroot "${SYSROOT}" rc-update add killprocs shutdown || true
chroot "${SYSROOT}" rc-update add savecache shutdown || true

# ── rfkill unblock — enable WiFi/BT hardware switch at boot ─────────────────
# brcmfmac and rtl8723bs may come up rfkill-blocked; unblock all at boot.

cat > "${SYSROOT}/etc/init.d/rfkill-unblock" <<'OPENRC'
#!/sbin/openrc-run
description="Unblock all rfkill-managed devices (WiFi, Bluetooth)"
depend() { after modules; before wpa_supplicant; }
start() {
    ebegin "Unblocking rfkill devices"
    rfkill unblock all 2>/dev/null || true
    eend 0
}
OPENRC
chmod 0755 "${SYSROOT}/etc/init.d/rfkill-unblock"
chroot "${SYSROOT}" rc-update add rfkill-unblock default || true

# ── wpa_supplicant — WiFi config ─────────────────────────────────────────────
# Alpine's wpa_supplicant service reads /etc/wpa_supplicant/wpa_supplicant.conf
# Connect on device: wpa_cli -i wlan0
#   > scan
#   > scan_results
#   > add_network / set_network 0 ssid "..." / set_network 0 psk "..." / enable_network 0

mkdir -p "${SYSROOT}/etc/wpa_supplicant"
cat > "${SYSROOT}/etc/wpa_supplicant/wpa_supplicant.conf" <<'WPACFG'
ctrl_interface=/var/run/wpa_supplicant
ctrl_interface_group=0
update_config=1
WPACFG

# Point wpa_supplicant service at wlan0
mkdir -p "${SYSROOT}/etc/conf.d"
cat > "${SYSROOT}/etc/conf.d/wpa_supplicant" <<'WPASVC'
wpa_supplicant_args="-i wlan0 -c /etc/wpa_supplicant/wpa_supplicant.conf"
WPASVC

# dhcpcd: only manage wlan0 and eth0, skip lo and other interfaces
cat > "${SYSROOT}/etc/dhcpcd.conf" <<'DHCPCFG'
allowinterfaces wlan0 eth0
background
timeout 30
DHCPCFG

# ── Audio setup ──────────────────────────────────────────────────────────────
# Audio modules are NOT loaded at boot — loading the A64 codec during early
# boot disrupts the debug serial UART when using an audio-cable serial adapter.
# Run teres-audio-setup manually after login, or it will be called by startx.

echo "==> Installing audio setup script..."
mkdir -p "${SYSROOT}/usr/local/sbin"
install -m 0755 "${REPO_ROOT}/services/teres-audio-setup.sh" \
    "${SYSROOT}/usr/local/sbin/teres-audio-setup.sh"

# Do NOT symlink into local.d — audio is initialized on-demand, not at boot

# ── Battery status script ────────────────────────────────────────────────────

echo "==> Installing battery status script..."
mkdir -p "${SYSROOT}/usr/local/bin"
install -m 0755 "${REPO_ROOT}/services/teres-battery.sh" \
    "${SYSROOT}/usr/local/bin/teres-battery"

# ── Embed install-to-nand.sh ────────────────────────────────────────────────

echo "==> Embedding install-to-nand.sh..."
mkdir -p "${SYSROOT}/usr/local/sbin"
install -m 0755 "${SCRIPT_DIR}/install-to-nand.sh" \
    "${SYSROOT}/usr/local/sbin/install-to-nand.sh"

# ── Copy U-Boot binary to /boot ─────────────────────────────────────────────

echo "==> Copying U-Boot to /boot..."
mkdir -p "${SYSROOT}/boot"
UBOOT_BIN="${REPO_ROOT}/build/uboot/u-boot-sunxi-with-spl.bin"
if [[ -f "${UBOOT_BIN}" ]]; then
    install -m 0644 "${UBOOT_BIN}" "${SYSROOT}/boot/u-boot-sunxi-with-spl.bin"
else
    echo "    WARNING: ${UBOOT_BIN} not found — run scripts/build-uboot.sh first"
fi

# ── Root password ───────────────────────────────────────────────────────────

echo "==> Setting root password to 'root' (change after first boot!)"
echo "root:root" | chroot "${SYSROOT}" chpasswd

# ── sudo configuration ──────────────────────────────────────────────────────

echo "==> Configuring sudo for wheel group..."
mkdir -p "${SYSROOT}/etc/sudoers.d"
echo "%wheel ALL=(ALL:ALL) ALL" > "${SYSROOT}/etc/sudoers.d/wheel"
chmod 440 "${SYSROOT}/etc/sudoers.d/wheel"

# ── DWM / X11 auto-start configuration ──────────────────────────────────────

echo "==> Setting up DWM as default window manager..."
cat > "${SYSROOT}/etc/profile.d/startx-login.sh" <<'XLOGIN'
# Auto-start X11 with DWM on tty1 login (for the default user)
if [ -z "$DISPLAY" ] && [ "$(tty)" = "/dev/tty1" ]; then
    exec startx
fi
XLOGIN

# Default .xinitrc for all users
cat > "${SYSROOT}/etc/skel/.xinitrc" <<'XINITRC'
#!/bin/sh
# Initialize audio (deferred from boot to avoid serial UART disruption)
/usr/local/sbin/teres-audio-setup.sh &
# Set keyboard repeat rate
xset r rate 200 30 &
# Start DWM
exec dwm
XINITRC
chmod 0644 "${SYSROOT}/etc/skel/.xinitrc"

# ── WiFi pre-configuration ──────────────────────────────────────────────────
# Appended to /etc/wpa_supplicant/wpa_supplicant.conf as a network block.

if [[ -n "${WIFI_SSID}" && -n "${WIFI_PASSWORD}" ]]; then
    echo "==> Pre-configuring WiFi for SSID: ${WIFI_SSID}"
    # Use wpa_passphrase to generate a hashed PSK network block
    chroot "${SYSROOT}" wpa_passphrase "${WIFI_SSID}" "${WIFI_PASSWORD}" \
        >> "${SYSROOT}/etc/wpa_supplicant/wpa_supplicant.conf"
    echo "    WiFi profile written (SSID: ${WIFI_SSID})."
elif [[ -n "${WIFI_SSID}" || -n "${WIFI_PASSWORD}" ]]; then
    echo "    WARNING: Both WIFI_SSID and WIFI_PASSWORD must be set to pre-configure WiFi. Skipping."
fi

# ── Cleanup ─────────────────────────────────────────────────────────────────

rm -f "${SYSROOT}/usr/bin/qemu-aarch64-static"
rm -f "${SYSROOT}/etc/resolv.conf"
chroot "${SYSROOT}" apk cache clean 2>/dev/null || true
rm -rf "${SYSROOT}/var/cache/apk/"*

echo ""
echo "==> Alpine Linux ${ALPINE_VERSION} arm64 rootfs ready at: ${SYSROOT}"
echo "    BOARD_HOSTNAME: ${BOARD_HOSTNAME}"
echo "    WIFI_SSID: ${WIFI_SSID:-<not set>}"
echo "    Root credentials: root / root"
echo "    User credentials: user / user (created on first boot)"
echo "    Window manager: DWM (auto-starts on tty1)"
echo "    Next step: sudo scripts/assemble-sd-image.sh"
