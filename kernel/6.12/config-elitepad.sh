#!/bin/sh
# Configuración del kernel i386 para la HP ElitePad 900 G1 (Clover Trail)
set -e
cd $HOME/elitepad-dev/linux-6.12.117
make ARCH=i386 i386_defconfig >/dev/null
C="scripts/config --file .config"

$C --set-str LOCALVERSION "-elitepad" --disable LOCALVERSION_AUTO

# CPU / memoria
$C --enable SMP --enable MATOM --enable HIGHMEM4G

# Arranque EFI y pantalla (efifb + consola)
$C --enable EFI --enable EFI_STUB --enable SYSFB --enable FB --enable FB_EFI
$C --enable FRAMEBUFFER_CONSOLE --enable FRAMEBUFFER_CONSOLE_DETECT_PRIMARY

# ACPI: tapa, y SIN pinctrl-baytrail (enlaza mal INT33B2 Cloverview -> tapa "cerrada")
$C --enable ACPI --enable ACPI_BUTTON --enable ACPI_VIDEO --disable PINCTRL_BAYTRAIL

# eMMC
$C --enable MMC --enable MMC_BLOCK --enable MMC_SDHCI --enable MMC_SDHCI_PLTFM --enable MMC_SDHCI_ACPI

# Sistemas de ficheros
$C --enable NTFS3_FS --enable VFAT_FS --enable EXT4_FS --enable NLS_UTF8 --enable NLS_CODEPAGE_437 --enable NLS_ISO8859_1

# USB (EHCI parcheado) + dock: hub SMSC, Ethernet smsc95xx, teclado HID, almacenamiento
$C --enable USB_SUPPORT --enable USB --enable USB_EHCI_HCD --enable USB_EHCI_HCD_PLATFORM --enable USB_OHCI_HCD --enable USB_STORAGE
$C --enable HID --enable HID_GENERIC --enable USB_HID --enable INPUT_EVDEV
$C --enable NETDEVICES --enable USB_NET_DRIVERS --enable USB_USBNET --enable USB_NET_SMSC95XX --enable USB_NET_CDCETHER --enable USB_NET_AX8817X --enable USB_RTL8152

# I2C / tactil (para la fase 2)
$C --enable COMMON_CLK --enable I2C --enable I2C_DESIGNWARE_CORE --enable I2C_DESIGNWARE_PLATFORM --enable I2C_HID --enable I2C_HID_ACPI --enable I2C_CHARDEV

# GPIO de Cloverview (INT33B2, driver propio; pinctrl-baytrail tambien reclama INT33B2: fuera)
$C --enable GPIOLIB --enable GPIO_ACPI --enable GPIO_CLOVERVIEW --enable GPIO_CDEV --disable PINCTRL_BAYTRAIL

# WiFi AR6004 (SDIO) + multitactil
$C --enable ATH6KL --enable ATH6KL_SDIO --enable HID_MULTITOUCH --enable DYNAMIC_DEBUG

# reinicio por el SCU (INT33B5): FADT HW-reduced sin registro de reset
$C --enable CLOVERVIEW_SCU_RESET

# initramfs y utilidades de depuracion
$C --enable DEVTMPFS --enable DEVTMPFS_MOUNT --enable BLK_DEV_INITRD --enable RD_GZIP --enable BLK_DEV_LOOP
$C --disable IPV6_SIT --enable PRINTK_TIME --enable MAGIC_SYSRQ --enable IKCONFIG --enable IKCONFIG_PROC

# Sin info de depuracion (compila mas rapido)
$C --disable DEBUG_INFO --disable DEBUG_INFO_DWARF5 --disable DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT --enable DEBUG_INFO_NONE

make ARCH=i386 olddefconfig >/dev/null

for o in X86_32 MATOM HIGHMEM4G EFI EFI_STUB FB_EFI FRAMEBUFFER_CONSOLE PINCTRL_BAYTRAIL MMC_SDHCI_ACPI NTFS3_FS \
         USB_EHCI_HCD_PLATFORM USB_NET_SMSC95XX USB_HID I2C_DESIGNWARE_PLATFORM I2C_HID_ACPI DEVTMPFS_MOUNT ACPI_BUTTON CLOVERVIEW_SCU_RESET GPIO_CLOVERVIEW; do
  printf "%-26s %s\n" "$o" "$(grep -E "^(CONFIG_$o=|# CONFIG_$o is)" .config || echo AUSENTE)"
done
