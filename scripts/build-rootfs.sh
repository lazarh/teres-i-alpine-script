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
# dwl is only available in Alpine testing
@testing ${ALPINE_MIRROR}/edge/testing
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
    alpine-base openrc busybox-extras bash shadow sudo \
    eudev eudev-openrc \
    util-linux e2fsprogs e2fsprogs-extra dosfstools parted \
    rsync curl wget ca-certificates \
    kmod iproute2 iputils iptables nftables \
    wpa_supplicant dhcpcd openresolv iw \
    linux-firmware-brcm linux-firmware-rtlwifi \
    openssh chrony dbus \
    mesa-dri-gallium mesa-gbm mesa-egl \
    libinput \
    seatd seatd-openrc \
    foot wmenu wl-clipboard xkeyboard-config waybar \
    font-dejavu font-noto \
    alsa-utils alsa-lib \
    neovim less htop \
    brightnessctl \
    tzdata \
    cloud-utils-growpart \
    wlrctl 

# dwl is in the Alpine testing repository — install separately with @testing tag
# dwl is the core Wayland compositor — fail the build if it cannot be installed
if ! chroot "${SYSROOT}" apk add --no-cache dwl@testing; then
    die "Failed to install dwl from Alpine testing repository"
fi

# Firefox ESR — stable branch, forced to run under Wayland via environment variable
chroot "${SYSROOT}" apk add --no-cache firefox-esr || true

# ── Decompress .zst firmware files ──────────────────────────────────────────
# Alpine ships firmware as .zst but the kernel needs CONFIG_FW_LOADER_COMPRESS_ZSTD
# to load them. Decompress all .zst firmware to plain files so any kernel works.
echo "==> Decompressing .zst firmware files..."
find "${SYSROOT}/lib/firmware" -name "*.zst" | while read -r f; do
    out="${f%.zst}"
    [[ -f "$out" ]] && continue  # already decompressed
    zstd -d "$f" -o "$out" --force -q 2>/dev/null || true
done
echo "    Firmware decompressed."


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

# Note: axp20x_battery and axp20x_charger are now built-in (=y), no modprobe needed.

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

# First-boot group and user creation
cat > "${SYSROOT}/etc/init.d/setup-groups" <<'GROUPSETUP'
#!/sbin/openrc-run
description="Create required groups on first boot"
depend() { need localmount; keyword -prefix; }
start() {
    ebegin "Creating system groups"
    for group in render seat video audio; do
        if ! getent group "$group" >/dev/null 2>&1; then
            addgroup -S "$group" 2>/dev/null || true
        fi
    done
    eend 0
}
GROUPSETUP
chmod 0755 "${SYSROOT}/etc/init.d/setup-groups"
chroot "${SYSROOT}" rc-update add setup-groups default || true

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
chroot "${SYSROOT}" rc-update add seatd default || true

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

# Fallback resolv.conf — dhcpcd/openresolv will overwrite with router-supplied
# DNS once a lease is obtained. These act as a safety net.
cat > "${SYSROOT}/etc/resolv.conf" <<'RESOLV'
nameserver 1.1.1.1
nameserver 8.8.8.8
RESOLV

# ── Audio setup ──────────────────────────────────────────────────────────────
# Audio modules are NOT loaded at boot — loading the A64 codec during early
# boot disrupts the debug serial UART when using an audio-cable serial adapter.
# Run teres-audio-setup manually after login, or it will be called when dwl starts.

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

# ── Wayland / dwl auto-start configuration ──────────────────────────────────

echo "==> Setting up dwl as default Wayland compositor..."

# Environment variables for Wayland: force Firefox to use Wayland, set Lima GPU,
# GTK dark theme, and XDG_RUNTIME_DIR for Wayland sockets.
# Named with 00- prefix so it is sourced before start-dwl.sh (alphabetical order).
cat > "${SYSROOT}/etc/profile.d/00-wayland-env.sh" <<'WAYENV'
# Wayland environment for Teres-I
export XDG_RUNTIME_DIR="/tmp/runtime-$(id -u)"
export XDG_SESSION_TYPE=wayland
export XDG_CURRENT_DESKTOP=dwl

# Start dbus user session if not already running (with fallback if dbus-launch unavailable)
if [ -z "$DBUS_SESSION_BUS_ADDRESS" ]; then
    if command -v dbus-launch >/dev/null 2>&1; then
        eval "$(dbus-launch --sh-syntax)"
    fi
fi

# Force Firefox to use Wayland (no X11 fallback)
export MOZ_ENABLE_WAYLAND=1
export MOZ_WEBRENDER=1

# Lima GPU (Mali-400 MP2) — use the software renderer as fallback
export WLR_RENDERER=gles2
export LIBSEAT_BACKEND=seatd

# GTK dark mode
export GTK_THEME=Adwaita:dark

# Qt Wayland support (if any Qt apps are installed)
export QT_QPA_PLATFORM=wayland

export WLR_NO_HARDWARE_CURSORS=1 
WAYENV

# Auto-start dwl on tty1 login (for the default user)
cat > "${SYSROOT}/etc/profile.d/start-dwl.sh" <<'DWLLOGIN'
# Auto-start dwl Wayland compositor on tty1 login
if [ -z "$WAYLAND_DISPLAY" ] && [ "$(tty)" = "/dev/tty1" ]; then
    # Ensure XDG_RUNTIME_DIR exists (set by 00-wayland-env.sh, sourced before this)
    mkdir -p "$XDG_RUNTIME_DIR"
    chmod 0700 "$XDG_RUNTIME_DIR"

    # Initialize audio (deferred from boot to avoid serial UART disruption)
    /usr/local/sbin/teres-audio-setup.sh &

    # Launch dwl with dbus-run-session to provide dbus session bus
    exec dbus-run-session -- dwl -s "waybar"
fi
DWLLOGIN

# ── Waybar configuration ────────────────────────────────────────────────────
# Waybar is a Wayland status bar that works with dwl

echo "==> Configuring waybar status bar..."
mkdir -p "${SYSROOT}/etc/xdg/waybar"

cat > "${SYSROOT}/etc/xdg/waybar/config.jsonc" <<'WAYBARCONFIG'
{
    "layer": "top",
    "position": "top",
    "height": 24,
    "spacing": 4,
    "modules-left": ["custom/tag1", "custom/tag2", "custom/tag3", "custom/tag4"],
    "modules-center": [],
    "modules-right": ["custom/uptime", "cpu", "memory", "battery", "clock"],

    "custom/tag1": { "format": "1", "on-click": "wlrctl keyboard type 'M-1'" },
    "custom/tag2": { "format": "2", "on-click": "wlrctl keyboard type 'M-2'" },
    "custom/tag3": { "format": "3", "on-click": "wlrctl keyboard type 'M-3'" },
    "custom/tag4": { "format": "4", "on-click": "wlrctl keyboard type 'M-4'" },

    "cpu": {
        "interval": 10,
        "format": "L: {usage}%",
        "max-length": 10
    },

    "memory": {
        "interval": 30,
        "format": "M: {used:0.1f}G",
        "max-length": 10
    },

    "battery": {
        "interval": 60,
        "states": {
            "warning": 30,
            "critical": 15
        },
        "format": "B: {capacity}%",
        "format-charging": "B: {capacity}%+",
        "max-length": 10
    },

    "clock": {
        "format": "{:%Y-%m-%d %H:%M}",
        "tooltip": false
    },

    "custom/uptime": {
        "exec": "uptime -p | sed 's/up //'",
        "interval": 60,
        "format": "U: {}"
    }
}
WAYBARCONFIG

cat > "${SYSROOT}/etc/xdg/waybar/style.css" <<'WAYBARSTYLE'
* {
    border: none;
    border-radius: 0;
    font-family: "DejaVu Sans Mono", "Monospace";
    font-size: 10px;
    min-height: 0;
}

window#waybar {
    background: #000000;
    color: #ffffff;
    border-bottom: 1px solid #444444;
}

#taskbar button {
    color: #ffffff;
    padding: 0 5px;
}

#taskbar button.active {
    background-color: #444444;
    color: #ffffff;
}

#custom-uptime, #cpu, #memory, #battery, #clock {
    padding: 0 8px;
    background-color: transparent;
}

/* Colors for specific states */
#battery.warning { color: #ffaa00; }
#battery.critical { color: #ff5555; }
WAYBARSTYLE

# ── Foot terminal configuration ────────────────────────────────────────────
# Configure foot terminal with DejaVu Sans Mono 

echo "==> Configuring foot terminal..."
mkdir -p "${SYSROOT}/root/.config/foot"

cat > "${SYSROOT}/root/.config/foot/foot.ini" <<'FOOTCONFIG'
[main]
term=xterm-256color
font=DejaVu Sans Mono:size=10
dpi-aware=yes

[cursor]
style=beam

[colors]
foreground=ffffff
background=000000
FOOTCONFIG

# ── wmenu wrapper script ───────────────────────────────────────────────────
# Create wrapper script to launch wmenu with font configuration
# Replace the original wmenu so dwl keybindings automatically use the configured version

echo "==> Configuring wmenu launcher..."
mkdir -p "${SYSROOT}/usr/local/bin"

# Backup original wmenu and create wrapper
chroot "${SYSROOT}" sh -c 'mv /usr/bin/wmenu /usr/bin/wmenu.real 2>/dev/null || true'

cat > "${SYSROOT}/usr/local/bin/wmenu" <<'WMENUWRAPPER'
#!/bin/sh
# wmenu wrapper with font configuration
exec /usr/bin/wmenu.real -f "DejaVu Sans Mono-10" "$@"
WMENUWRAPPER
chmod 0755 "${SYSROOT}/usr/local/bin/wmenu"

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

# Generate dbus machine-id (unique identifier for this system instance)
chroot "${SYSROOT}" dbus-uuidgen --ensure=/etc/machine-id

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
echo "    Compositor: dwl (Wayland, auto-starts on tty1)"
echo "    Status bar: waybar (taskbar, uptime, CPU, memory, battery, clock)"
echo "    Terminal: foot"
echo "    Launcher: wmenu"
echo "    Browser: Firefox ESR (Wayland-native)"
echo "    Editor: neovim"
echo "    Next step: sudo scripts/assemble-sd-image.sh"
