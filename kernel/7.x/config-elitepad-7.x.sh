#!/bin/sh
# Configuración del kernel i386 7.x para la HP ElitePad 900 G1 (Clover Trail)
#
# Uso:  ./config-elitepad-7.x.sh [ARBOL]
#       (por defecto $HOME/elitepad-dev/linux-7.x/linux-7.3.4)
#
# Diferencias con config-elitepad.sh (6.12):
#   - NO parte de i386_defconfig: parte de la config 6.12 ya validada en la
#     tableta (out/config-6.12.117-elitepad) y deja que olddefconfig resuelva
#     los símbolos nuevos/renombrados.  Así se conserva todo lo que costó
#     encontrar en 6.12 (ATH6KL_SDIO, I2C_DESIGNWARE, etc.).
#   - Añade SYSFB_SIMPLEFB + DRM_SIMPLEDRM + DRM_FBDEV_EMULATION (ruta de
#     pantalla para powervr_sgx: KMS sobre el framebuffer del firmware).
#   - PINCTRL_BAYTRAIL: en 7.3 el símbolo sólo existe si CONFIG_PINCTRL=y.
#     Aquí CONFIG_PINCTRL se deja en 'n', así que pinctrl-baytrail (que reclama
#     INT33B2 y hacía que la tapa se viera "cerrada") no puede compilarse.
set -e
TREE=${1:-$HOME/elitepad-dev/linux-7.x/linux-7.3.4}
BASE=$HOME/elitepad-dev/out/config-6.12.117-elitepad
cd "$TREE"

if [ ! -f .config ]; then
	cp "$BASE" .config
fi

C="scripts/config --file .config"
$C --set-str LOCALVERSION "-elitepad" --disable LOCALVERSION_AUTO

# CPU / memoria (MATOM = Bonnell/Saltwell, el núcleo del Z2760)
$C --enable SMP --enable MATOM --enable HIGHMEM4G

# Arranque EFI y consola
$C --enable EFI --enable EFI_STUB --enable SYSFB --enable FB --enable FB_CORE
$C --enable FB_EFI --enable FRAMEBUFFER_CONSOLE --enable FRAMEBUFFER_CONSOLE_DETECT_PRIMARY

# ACPI sin pinctrl-baytrail
$C --enable ACPI --enable ACPI_BUTTON --enable ACPI_VIDEO
$C --disable PINCTRL --disable PINCTRL_BAYTRAIL

# KMS para la ruta de powervr_sgx (simpledrm sobre el fb del firmware)
$C --enable DRM --enable DRM_KMS_HELPER --enable DRM_SIMPLEDRM --enable DRM_FBDEV_EMULATION

# eMMC
$C --enable MMC --enable MMC_BLOCK --enable MMC_SDHCI --enable MMC_SDHCI_PLTFM --enable MMC_SDHCI_ACPI

# Sistemas de ficheros
$C --enable NTFS3_FS --enable VFAT_FS --enable EXT4_FS --enable NLS_UTF8 --enable NLS_CODEPAGE_437 --enable NLS_ISO8859_1

# USB (EHCI parcheado) + dock
$C --enable USB_SUPPORT --enable USB --enable USB_EHCI_HCD --enable USB_EHCI_HCD_PLATFORM --enable USB_OHCI_HCD --enable USB_STORAGE
$C --enable HID --enable HID_GENERIC --enable USB_HID --enable INPUT_EVDEV
$C --enable NETDEVICES --enable USB_NET_DRIVERS --enable USB_USBNET --enable USB_NET_SMSC95XX --enable USB_NET_CDCETHER --enable USB_NET_AX8817X --enable USB_RTL8152

# I2C / táctil
$C --enable COMMON_CLK --enable I2C --enable I2C_DESIGNWARE_CORE --enable I2C_DESIGNWARE_PLATFORM
$C --enable I2C_HID --enable I2C_HID_ACPI --enable I2C_CHARDEV

# GPIO de Cloverview (driver propio, INT33B2)
$C --enable GPIOLIB --enable GPIO_ACPI --enable GPIO_CLOVERVIEW --enable GPIO_CDEV

# WiFi AR6004 (SDIO) + multitáctil
$C --enable ATH6KL --enable ATH6KL_SDIO --enable HID_MULTITOUCH --enable DYNAMIC_DEBUG

# Reinicio por el SCU (INT33B5)
$C --enable CLOVERVIEW_SCU_RESET

# initramfs y utilidades
$C --enable DEVTMPFS --enable DEVTMPFS_MOUNT --enable BLK_DEV_INITRD --enable RD_GZIP --enable BLK_DEV_LOOP
$C --disable IPV6_SIT --enable PRINTK_TIME --enable MAGIC_SYSRQ --enable IKCONFIG --enable IKCONFIG_PROC

# Sin depuración (compila más rápido)
$C --disable DEBUG_INFO --disable DEBUG_INFO_DWARF5 --disable DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT --enable DEBUG_INFO_NONE

# zram: swap comprimida en RAM (2 GB y Chromium); lz4 es el compresor más barato para el Atom
$C --enable ZSMALLOC --enable ZRAM --enable ZRAM_BACKEND_LZ4 --enable CRYPTO_LZ4

# user namespaces: el sandbox de Chromium (sin ellos hace falta --disable-gpu-sandbox) y colord
$C --enable USER_NS

make ARCH=i386 olddefconfig

for o in X86_32 MATOM HIGHMEM4G EFI EFI_STUB SYSFB SYSFB_SIMPLEFB FB_EFI DRM DRM_KMS_HELPER \
         DRM_SIMPLEDRM DRM_FBDEV_EMULATION FRAMEBUFFER_CONSOLE MMC_SDHCI_ACPI NTFS3_FS \
         USB_EHCI_HCD_PLATFORM USB_NET_SMSC95XX USB_HID I2C_DESIGNWARE_PLATFORM I2C_HID_ACPI \
         DEVTMPFS_MOUNT ACPI_BUTTON CLOVERVIEW_SCU_RESET GPIO_CLOVERVIEW ATH6KL_SDIO HID_MULTITOUCH PINCTRL \
         ZSMALLOC ZRAM ZRAM_BACKEND_LZ4 USER_NS; do
	printf "%-26s %s\n" "$o" "$(grep -E "^(CONFIG_$o=|# CONFIG_$o is not set)" .config || echo AUSENTE)"
done
