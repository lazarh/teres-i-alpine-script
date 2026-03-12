#!/bin/bash
# install-deps.sh — Install build host dependencies for Teres-I cross-compilation.
#
# Run once on a Debian/Ubuntu x86-64 build host.
# Must be run as root (apt-get).
#
# Installs:
#   - aarch64-linux-gnu cross-compiler (kernel, U-Boot, TF-A)
#   - ARM Trusted Firmware build dependencies
#   - Kernel build tools
#   - debootstrap + qemu-user-static for arm64 rootfs
#   - Image assembly tools

set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "ERROR: Must be run as root" >&2; exit 1; }

apt-get update -q
apt-get install -y --no-install-recommends \
    gcc-aarch64-linux-gnu \
    binutils-aarch64-linux-gnu \
    make \
    bc \
    bison \
    flex \
    libssl-dev \
    libncurses-dev \
    libgnutls28-dev \
    libglib2.0-dev \
    device-tree-compiler \
    u-boot-tools \
    debootstrap \
    qemu-user-static \
    binfmt-support \
    parted \
    dosfstools \
    e2fsprogs \
    rsync \
    pigz \
    bmap-tools \
    curl \
    wget \
    xz-utils \
    ca-certificates \
    git \
    python3 \
    python3-cryptography \
    mtd-utils

echo ""
echo "==> All build dependencies installed."
echo "    Build order:"
echo "      1. scripts/build-uboot.sh"
echo "      2. scripts/build-kernel.sh"
echo "      3. sudo scripts/build-rootfs.sh"
echo "      4. sudo scripts/assemble-sd-image.sh"
