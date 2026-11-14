# SPDX-License-Identifier: GPL-2.0-only
#
# Siflower SF19A2890 target images.
#
# Adds the Tenbay WR1204S (marketed as eWeLink / twifi, ODM Shenzhen
# Nuoxincheng) next to the upstream Siflower EVB definition.
#
# WR1204S differences vs EVB / BPI-WiFi5:
#   - Airoha AN8855 5-port switch (EVB uses RTL8367B, BPI also uses AN8855)
#   - 16 MiB SPI NOR with product + custom partitions (EVB has neither)
#   - firmware starts at 0xb0000, not 0xa0000
#   - reset key GPIO 14 (EVB/BPI both say 27, which is the WPS key here)

KERNEL_LOADADDR := 0x80100000

define Device/Default
  PROFILES := Default
  BLOCKSIZE := 64k
  FILESYSTEMS := squashfs
  DEVICE_DTS_DIR := ../dts
  KERNEL := kernel-bin | append-dtb | lzma | uImage lzma
  KERNEL_INITRAMFS := kernel-bin | append-dtb | lzma | uImage lzma
  IMAGES := sysupgrade.bin
  IMAGE/sysupgrade.bin = append-kernel | pad-to $$$$(BLOCKSIZE) | \
	append-rootfs | pad-rootfs | append-metadata
endef

# ---------------------------------------------------------------------------
# Tenbay WR1204S / eWeLink WR1204S
#
# DEVICE_PACKAGES is deliberately short: the firmware partition is 15.25 MiB
# and there is only ~1.4 MiB of rootfs_data, so every megabyte counts.
# Extra tooling is a `opkg install` away once the image is running.
# ---------------------------------------------------------------------------
define Device/tenbay_wr1204s
  DEVICE_VENDOR := Tenbay
  DEVICE_MODEL := WR1204S
  DEVICE_ALT0_VENDOR := eWeLink
  DEVICE_ALT0_MODEL := WR1204S
  DEVICE_ALT1_VENDOR := twifi
  DEVICE_ALT1_MODEL := WR1204S
  BOARD_NAME := tenbay,wr1204s
  DEVICE_DTS := sf19a2890_wr1204s
  SUPPORTED_DEVICES += tenbay,wr1204s twifi,wr1204s
  # firmware partition is 0xf40000 = 15616 KiB
  IMAGE_SIZE := 15616k
  DEVICE_PACKAGES := \
	kmod-input-gpio-keys \
	kmod-usb-dwc2 \
	kmod-usb-storage \
	kmod-fs-ext4 \
	kmod-fs-vfat \
	uboot-envtools
endef
TARGET_DEVICES += tenbay_wr1204s

# ---------------------------------------------------------------------------
# Minimal build: no LuCI, smallest possible rootfs. Useful as the first
# flash when you want maximum headroom to probe the hardware.
# ---------------------------------------------------------------------------
define Device/tenbay_wr1204s-min
  DEVICE_VENDOR := Tenbay
  DEVICE_MODEL := WR1204S (minimal)
  BOARD_NAME := tenbay,wr1204s
  DEVICE_DTS := sf19a2890_wr1204s
  SUPPORTED_DEVICES += tenbay,wr1204s
  IMAGE_SIZE := 15616k
  DEVICE_PACKAGES :=
  IMAGES := sysupgrade.bin
endef
TARGET_DEVICES += tenbay_wr1204s-min

# ---------------------------------------------------------------------------
# Upstream Siflower evaluation board, kept for reference.
# ---------------------------------------------------------------------------
define Device/siflower_sf19a2890-evb
  DEVICE_VENDOR := Siflower
  DEVICE_MODEL := SF19A2890 EVB
  BOARD_NAME := siflower,sf19a2890-evb
  DEVICE_DTS := sf19a2890_evb
  DEVICE_PACKAGES := kmod-switch-rtl8367b swconfig
endef
TARGET_DEVICES += siflower_sf19a2890-evb
