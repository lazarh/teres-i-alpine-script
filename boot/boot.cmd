# Boot from SD card on Olimex Teres-I.
#
# U-Boot calls the SD slot mmc0, but Linux enumerates it as mmcblk1 because
# the SDIO WiFi chip (BCM43438 / RTL8723BS) attaches to mmc@1c0f000 first and
# becomes mmc0/mmcblk0.  The SD card (mmc@1c10000) becomes mmcblk1.
# The eMMC (mmc@1c11000) becomes mmcblk2.
#
# Uses booti (not bootz) because the kernel image is arm64 Image.
# The DTB is sun50i-a64-teres-i.dtb from the boot partition.

setenv bootargs console=ttyS0,115200 console=tty1 root=/dev/mmcblk1p2 rootwait panic=10 ${extra}
load mmc 0:1 ${fdt_addr_r} sun50i-a64-teres-i.dtb
load mmc 0:1 ${kernel_addr_r} Image
booti ${kernel_addr_r} - ${fdt_addr_r}
