# Boot from SD card (mmc 0) on Olimex Teres-I.
# U-Boot mmc device 0 = SD card → /dev/mmcblk0
#
# Uses booti (not bootz) because the kernel image is arm64 Image.
# The DTB is sun50i-a64-teres-i.dtb from the boot partition.

setenv bootargs console=ttyS0,115200 console=tty1 root=/dev/mmcblk0p2 rootwait panic=10 ${extra}
load mmc 0:1 ${fdt_addr_r} sun50i-a64-teres-i.dtb
load mmc 0:1 ${kernel_addr_r} Image
booti ${kernel_addr_r} - ${fdt_addr_r}
