#!/bin/bash
# install-to-nand.sh — Write the running SD card OS to the internal NAND flash.
#
# Run this from the booted SD card image as root on the Teres-I.
#
# The Teres-I uses raw NAND accessed via the Linux MTD subsystem.
# The mainline kernel's sunxi-nand driver exposes MTD devices:
#   /dev/mtd0 (label "boot") — U-Boot SPL + proper (raw write, 4 MiB)
#   /dev/mtd1 (label "ubi")  — UBI container (boot volume + rootfs volume)
#
# NAND layout written:
#   /dev/mtd0  : U-Boot (SPL + proper), written raw with nandwrite
#   /dev/mtd1  : UBI
#     ubi0:boot   (256 MiB, UBIFS) — /boot: Image, DTB, boot.scr
#     ubi0:rootfs (remaining,UBIFS) — /: Debian rootfs
#
# After install: remove the SD card and reboot.  U-Boot will boot from NAND.

set -euo pipefail

UBOOT_BIN=/boot/u-boot-sunxi-with-spl.bin
BOOT_VOLUME_SIZE="256MiB"
WORK_DIR=$(mktemp -d)
UBI_MTD=""  # set after MTD detection; used by cleanup

# ── Helpers ────────────────────────────────────────────────────────────────

cleanup() {
    umount "${WORK_DIR}/boot"  2>/dev/null || true
    umount "${WORK_DIR}/root"  2>/dev/null || true
    if [[ -n "${UBI_MTD}" ]]; then
        ubidetach -p "${UBI_MTD}" 2>/dev/null || true
    fi
    rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

die() { echo "ERROR: $*" >&2; exit 1; }

# Find an MTD device by its label (reads /sys/class/mtd/mtdN/name).
find_mtd() {
    local label="$1"
    for sysfs_entry in /sys/class/mtd/mtd[0-9]*; do
        [[ -f "${sysfs_entry}/name" ]] || continue
        if [[ "$(cat "${sysfs_entry}/name")" == "${label}" ]]; then
            echo "/dev/$(basename "${sysfs_entry}")"
            return 0
        fi
    done
    return 1
}

# ── Preflight checks ────────────────────────────────────────────────────────

[[ $EUID -eq 0 ]] || die "Must be run as root"

command -v flash_erase  >/dev/null || die "flash_erase not found — install mtd-utils"
command -v nandwrite    >/dev/null || die "nandwrite not found — install mtd-utils"
command -v ubiformat    >/dev/null || die "ubiformat not found — install mtd-utils"
command -v ubiattach    >/dev/null || die "ubiattach not found — install mtd-utils"
command -v ubimkvol     >/dev/null || die "ubimkvol not found — install mtd-utils"
command -v mkimage      >/dev/null || die "mkimage not found — install u-boot-tools"

[[ -f "${UBOOT_BIN}" ]] || die "${UBOOT_BIN} not found — was the SD image built correctly?"

echo "==> Detecting NAND MTD devices..."
MTD_LIST=""
for m in /sys/class/mtd/mtd[0-9]*; do
    n="$(cat "${m}/name" 2>/dev/null || echo '?')"
    MTD_LIST+="  /dev/$(basename "${m}"): ${n}\n"
done

BOOT_MTD=$(find_mtd "boot") || die \
    "MTD partition 'boot' not found.
    Make sure:
      1. The sunxi-nand driver is loaded (check: lsmod | grep nand)
      2. The kernel DTS defines NAND partitions with labels 'boot' and 'ubi'
      3. You are running this on the Teres-I hardware
    Available MTD devices:
$(printf '%b' "${MTD_LIST}")"

UBI_MTD=$(find_mtd "ubi") || die \
    "MTD partition 'ubi' not found.
    Available MTD devices:
$(printf '%b' "${MTD_LIST}")"

echo "    U-Boot MTD : ${BOOT_MTD}"
echo "    UBI MTD    : ${UBI_MTD}"

# Warn if UBI is already formatted (existing installation)
if ubiattach -p "${UBI_MTD}" -d 9 2>/dev/null; then
    ubidetach -d 9 2>/dev/null || true
    read -rp "NAND already has a UBI volume. Overwrite? [y/N] " answer
    [[ "${answer,,}" == "y" ]] || { echo "Aborted."; exit 0; }
fi

echo ""
echo "==> Installing to NAND.  All NAND data will be lost."
echo "    Press Ctrl-C within 5 seconds to abort."
sleep 5

# ── Write U-Boot to NAND ───────────────────────────────────────────────────

echo "==> Erasing U-Boot MTD partition (${BOOT_MTD})..."
flash_erase "${BOOT_MTD}" 0 0

echo "==> Writing U-Boot to ${BOOT_MTD}..."
nandwrite -p "${BOOT_MTD}" "${UBOOT_BIN}"
echo "    U-Boot written."

# ── Format UBI partition ───────────────────────────────────────────────────

echo "==> Formatting UBI partition (${UBI_MTD})..."
ubiformat "${UBI_MTD}" -y

echo "==> Attaching UBI (${UBI_MTD} → /dev/ubi0)..."
ubiattach -p "${UBI_MTD}" -d 0

# ── Create UBI volumes ─────────────────────────────────────────────────────

echo "==> Creating UBI volume 'boot' (${BOOT_VOLUME_SIZE})..."
ubimkvol /dev/ubi0 -N boot -s "${BOOT_VOLUME_SIZE}"

echo "==> Creating UBI volume 'rootfs' (remaining space)..."
ubimkvol /dev/ubi0 -N rootfs -m

# ── Mount UBI volumes ──────────────────────────────────────────────────────

mkdir -p "${WORK_DIR}/boot" "${WORK_DIR}/root"
mount -t ubifs ubi0:boot   "${WORK_DIR}/boot"
mount -t ubifs ubi0:rootfs "${WORK_DIR}/root"

# ── Copy boot files ────────────────────────────────────────────────────────

echo "==> Copying boot files to UBI 'boot' volume..."
cp -a /boot/. "${WORK_DIR}/boot/"
# U-Boot binary is already written raw to mtd0 — no need to keep it in UBIFS
rm -f "${WORK_DIR}/boot/u-boot-sunxi-with-spl.bin"

# Generate a NAND-specific boot.scr that loads kernel/DTB from UBI 'boot'
# and mounts rootfs from UBI 'rootfs' as UBIFS.
echo "==> Generating NAND boot script..."
NAND_BOOT_CMD=$(mktemp /tmp/nand-boot.XXXXXX.cmd)
cat > "${NAND_BOOT_CMD}" <<'BOOTCMD'
# Boot from NAND UBI on Teres-I.
# Mounts the UBI 'boot' volume (UBIFS) to load kernel and DTB,
# then mounts 'rootfs' volume as the root filesystem.
ubi part ubi
ubifsmount ubi0:boot
ubifsload ${kernel_addr_r} Image
ubifsload ${fdt_addr_r} sun50i-a64-teres-i.dtb
setenv bootargs console=ttyS0,115200 console=tty1 ubi.mtd=ubi root=ubi0:rootfs rootfstype=ubifs rootwait panic=10 ${extra}
booti ${kernel_addr_r} - ${fdt_addr_r}
BOOTCMD
mkimage -C none -A arm64 -T script \
    -d "${NAND_BOOT_CMD}" \
    "${WORK_DIR}/boot/boot.scr"
rm -f "${NAND_BOOT_CMD}"
echo "    NAND boot.scr written."

# ── Copy rootfs ────────────────────────────────────────────────────────────

echo "==> Copying rootfs (this takes several minutes)..."
rsync -aAX --exclude=/proc --exclude=/sys --exclude=/dev \
           --exclude=/run  --exclude=/tmp --exclude=/boot \
           / "${WORK_DIR}/root/"

# Recreate essential empty mountpoints
mkdir -p "${WORK_DIR}/root"/{proc,sys,dev,run,tmp,boot}
chmod 1777 "${WORK_DIR}/root/tmp"

# ── Update /etc/fstab for NAND boot ───────────────────────────────────────

echo "==> Updating /etc/fstab for NAND boot..."
cat > "${WORK_DIR}/root/etc/fstab" <<'EOF'
ubi0:rootfs  /      ubifs  defaults,noatime  0  0
tmpfs        /tmp   tmpfs  defaults,nosuid,nodev  0  0
EOF

sync
echo ""
echo "==> Done! Remove the SD card and reboot to start from NAND."
echo ""
echo "    NAND layout:"
echo "      ${BOOT_MTD}  : U-Boot SPL + proper (raw)"
echo "      ${UBI_MTD}   : UBI container"
echo "        ubi0:boot   — /boot (UBIFS, ${BOOT_VOLUME_SIZE})"
echo "        ubi0:rootfs — /     (UBIFS, remaining)"
echo ""
echo "    On next boot U-Boot will detect the absent SD card and use NAND."
echo "    If it does not, enter U-Boot shell and run:"
echo "      => run nandboot"
echo "    Or set the boot command permanently:"
echo "      => setenv bootcmd 'run nandboot'; saveenv"
