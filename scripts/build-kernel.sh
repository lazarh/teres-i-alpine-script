#!/bin/bash
# build-kernel.sh — Download, configure, and cross-compile the Linux kernel
#                   for Olimex Teres-I (Allwinner A64 / sun50i-a64, AArch64).
#
# Produces:
#   build/kernel/Image                            — uncompressed kernel image (arm64)
#   build/kernel/sun50i-a64-teres-i.dtb           — device tree blob
#   build/kernel/modules/                         — kernel modules
#
# Requires: gcc-aarch64-linux-gnu, make, bc, flex, bison, libssl-dev, libncurses-dev
# Run: scripts/install-deps.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

KERNEL_VERSION="6.12.18"
KRELEASE="6"
KERNEL_URL="https://www.kernel.org/pub/linux/kernel/v${KRELEASE}.x/linux-${KERNEL_VERSION}.tar.xz"
KERNEL_SHA256=""  # Set to SHA256 of the tarball to enable verification

CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"
ARCH=arm64
JOBS="${JOBS:-$(nproc)}"

BUILD_DIR="${REPO_ROOT}/build/kernel"
MODULES_DIR="${BUILD_DIR}/modules"
SOURCES_DIR="${REPO_ROOT}/build/sources"
KERNEL_SRC="${SOURCES_DIR}/linux-${KERNEL_VERSION}"
CONFIG_FRAGMENT="${REPO_ROOT}/configs/kernel/teres-i.config"
PATCHES_DIR="${REPO_ROOT}/patches/kernel"
PATCH_STAMP="${KERNEL_SRC}/.patched"

# ── Helpers ────────────────────────────────────────────────────────────────

die() { echo "ERROR: $*" >&2; exit 1; }

command -v "${CROSS_COMPILE}gcc" >/dev/null || die "${CROSS_COMPILE}gcc not found — run scripts/install-deps.sh"

mkdir -p "${BUILD_DIR}" "${SOURCES_DIR}"

# If modules from a different kernel version exist, remove them to avoid stale modules
STAMP="${BUILD_DIR}/.kernel-version"
if [[ -f "${STAMP}" ]] && [[ "$(cat "${STAMP}")" != "${KERNEL_VERSION}" ]]; then
    echo "==> Cleaning stale modules ($(cat "${STAMP}") → ${KERNEL_VERSION})..."
    rm -rf "${MODULES_DIR}"
fi
mkdir -p "${MODULES_DIR}"

# ── Download ───────────────────────────────────────────────────────────────

TARBALL="${SOURCES_DIR}/linux-${KERNEL_VERSION}.tar.xz"
if [[ ! -f "${TARBALL}" ]]; then
    echo "==> Downloading Linux ${KERNEL_VERSION}..."
    curl -fL --progress-bar "${KERNEL_URL}" -o "${TARBALL}"
fi

if [[ -n "${KERNEL_SHA256}" ]]; then
    echo "==> Verifying checksum..."
    echo "${KERNEL_SHA256}  ${TARBALL}" | sha256sum -c -
else
    echo "==> Kernel checksum not set — skipping verification."
    echo "    SHA256: $(sha256sum "${TARBALL}" | cut -d' ' -f1)"
fi

# ── Extract ────────────────────────────────────────────────────────────────

if [[ ! -d "${KERNEL_SRC}" ]]; then
    echo "==> Extracting kernel source..."
    tar -xJf "${TARBALL}" -C "${SOURCES_DIR}"
fi

# ── Apply patches ──────────────────────────────────────────────────────────

if [[ ! -f "${PATCH_STAMP}" ]]; then
    echo "==> Applying kernel patches..."
    for p in "${PATCHES_DIR}"/*.patch; do
        [[ -f "${p}" ]] || continue
        echo "    Applying $(basename "${p}")..."
        if ! patch -N -r /dev/null -p1 -d "${KERNEL_SRC}" < "${p}"; then
            echo "    WARNING: patch $(basename "${p}") did not apply cleanly — continuing anyway"
        fi
    done
    touch "${PATCH_STAMP}"
    echo "    Patches applied."
fi

# ── Configure ─────────────────────────────────────────────────────────────

echo "==> Applying arm64 defconfig..."
make -C "${KERNEL_SRC}" \
    ARCH="${ARCH}" \
    CROSS_COMPILE="${CROSS_COMPILE}" \
    O="${BUILD_DIR}" \
    defconfig

echo "==> Merging Teres-I config fragment..."
"${KERNEL_SRC}/scripts/kconfig/merge_config.sh" \
    -m -O "${BUILD_DIR}" \
    "${BUILD_DIR}/.config" \
    "${CONFIG_FRAGMENT}"

# Re-run olddefconfig to resolve any new symbols introduced by the fragment
make -C "${KERNEL_SRC}" \
    ARCH="${ARCH}" \
    CROSS_COMPILE="${CROSS_COMPILE}" \
    O="${BUILD_DIR}" \
    olddefconfig

# ── Build kernel image, DTBs, and modules ─────────────────────────────────

echo "==> Building kernel (-j${JOBS})..."
make -C "${KERNEL_SRC}" \
    ARCH="${ARCH}" \
    CROSS_COMPILE="${CROSS_COMPILE}" \
    O="${BUILD_DIR}" \
    -j"${JOBS}" \
    Image dtbs modules

# ── Install modules ────────────────────────────────────────────────────────

echo "==> Installing modules to ${MODULES_DIR}..."
make -C "${KERNEL_SRC}" \
    ARCH="${ARCH}" \
    CROSS_COMPILE="${CROSS_COMPILE}" \
    O="${BUILD_DIR}" \
    INSTALL_MOD_PATH="${MODULES_DIR}" \
    modules_install

# Remove build/source symlinks (not needed on target and contain host paths)
find "${MODULES_DIR}" -name "build" -o -name "source" | xargs rm -f 2>/dev/null || true

# ── Copy artifacts ─────────────────────────────────────────────────────────

cp "${BUILD_DIR}/arch/arm64/boot/Image" "${BUILD_DIR}/Image"
cp "${BUILD_DIR}/arch/arm64/boot/dts/allwinner/sun50i-a64-teres-i.dtb" "${BUILD_DIR}/"

echo ""
echo "==> Kernel build complete."
echo "    Image : ${BUILD_DIR}/Image"
echo "    DTB   : ${BUILD_DIR}/sun50i-a64-teres-i.dtb"
echo "    Modules: ${BUILD_DIR}/modules/"
echo "    Next step: sudo scripts/build-rootfs.sh"

# Write version stamp so build-rootfs.sh can verify the modules match
echo "${KERNEL_VERSION}" > "${BUILD_DIR}/.kernel-version"
