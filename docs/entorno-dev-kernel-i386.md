# Fase 1: kernel propio i386 + entorno en RAM con SSH

Receta para arrancar Linux moderno en una tableta x86 de 32 bits **sin
instalar nada**: kernel compilado a mano, initramfs con busybox y dropbear, y
una entrada nueva en el gestor de arranque que ya funciona (Wubi/Windows). Se
hace en el homelab (x86_64) y solo se copian dos archivos al equipo.

Objetivo real: dejar de depender de fotos y de apagar a la fuerza. En cuanto
hay Ethernet en el dock, se gana **SSH al Linux** y los drivers se depuran en
vivo, sin un reinicio por prueba.

## 1. Kernel: `i386` desde un host x86_64

No hace falta toolchain cruzado: `make ARCH=i386` funciona con el gcc del host
si el árbol tiene soporte de 32 bits.

```sh
cd linux-6.12.x
make ARCH=i386 i386_defconfig
scripts/config --file .config --set-str LOCALVERSION "-elitepad" --disable LOCALVERSION_AUTO
make ARCH=i386 -j6 bzImage
```

Config que sí importa para esta clase de equipo:

```sh
C="scripts/config --file .config"
$C --enable MATOM --enable HIGHMEM4G          # Atom; HIGHMEM para 2 GB
$C --enable EFI --enable EFI_STUB --enable SYSFB --enable FB --enable FB_EFI
$C --enable FRAMEBUFFER_CONSOLE --enable FRAMEBUFFER_CONSOLE_DETECT_PRIMARY
$C --enable ACPI_BUTTON --enable ACPI_VIDEO --disable PINCTRL_BAYTRAIL
$C --enable MMC_SDHCI --enable MMC_SDHCI_PLTFM --enable MMC_SDHCI_ACPI
$C --enable NTFS3_FS --enable VFAT_FS --enable EXT4_FS --enable NLS_UTF8
$C --enable USB_EHCI_HCD --enable USB_EHCI_HCD_PLATFORM --enable USB_OHCI_HCD
$C --enable USB_USBNET --enable USB_NET_SMSC95XX --enable USB_NET_AX8817X --enable USB_RTL8152
$C --enable HID_GENERIC --enable USB_HID --enable INPUT_EVDEV
$C --enable COMMON_CLK                     # ANTES de I2C_DESIGNWARE_PLATFORM
$C --enable I2C --enable I2C_DESIGNWARE_CORE --enable I2C_DESIGNWARE_PLATFORM
$C --enable I2C_HID --enable I2C_HID_ACPI
$C --enable DEVTMPFS --enable DEVTMPFS_MOUNT --enable BLK_DEV_INITRD --enable RD_GZIP
$C --enable PRINTK_TIME --enable MAGIC_SYSRQ --enable IKCONFIG --enable IKCONFIG_PROC
$C --disable DEBUG_INFO --enable DEBUG_INFO_NONE   # compila en minutos, no en horas
make ARCH=i386 olddefconfig
```

**`scripts/config --enable X` no avisa si X no se puede activar.** Si una
dependencia del Kconfig no se cumple, la opción se queda fuera en silencio y te
enteras al compilar o, peor, al arrancar sin ese bus. Verifica siempre después
del `olddefconfig`:

```sh
for o in MATOM HIGHMEM4G EFI FB_EFI FRAMEBUFFER_CONSOLE PINCTRL_BAYTRAIL \
         MMC_SDHCI_ACPI NTFS3_FS USB_EHCI_HCD_PLATFORM USB_NET_SMSC95XX \
         I2C_DESIGNWARE_PLATFORM I2C_HID_ACPI DEVTMPFS_MOUNT; do
  printf "%-24s %s\n" "$o" "$(grep -E "^(CONFIG_$o=|# CONFIG_$o is)" .config || echo AUSENTE)"
done
```

Caso concreto que muerde: `I2C_DESIGNWARE_PLATFORM` lleva
`depends on (ACPI && COMMON_CLK) || !ACPI`, y `i386_defconfig` **no** activa
`COMMON_CLK`. Sin orden explícito (`COMMON_CLK` primero) no hay I2C y por tanto
ni táctil ni GPIO.

`PINCTRL_BAYTRAIL` se deja **fuera a propósito**: en Cloverview engancha por
`INT33B2` al chip equivocado y deja la tapa "cerrada" (ver
`acpi-dsdt-y-drivers.md`).

## 2. Initramfs con busybox y dropbear (i386)

Paquetes de Debian i386 descargados del pool sin instalar nada en el host:
`busybox-static` (ELF estático, no necesita librerías) + `dropbear-bin` con su
cadena glibc.

```sh
curl -sL -o Packages.xz https://deb.debian.org/debian/dists/bookworm/main/binary-i386/Packages.xz
xz -dc Packages.xz > Packages          # de aquí salen Version y Filename exactos
# ... descargar cada Filename con curl -O y extraer con dpkg -x:
for d in *.deb; do dpkg -x "$d" x; done
```

Librerías: sácalas de `objdump`, no de la lista de dependencias del paquete
(que trae las directas de Debian, no las que acaban necesitando):

```sh
objdump -p usr/sbin/dropbear | awk '/NEEDED/{print $2}'   # libtomcrypt, libtommath, libz, libcrypt, libc
```

Y comprueba también las **transitivas**: cada `.so` copiado puede pedir otra
(`libgmp`, `libgcc_s`, `libnss_files`). Un `NEEDED` sin resolver no da error en
el arranque del kernel: da `not found` en el initramfs y te deja sin SSH.

**Pitfall de `cp -a`:** en el `.deb`, `ld-linux.so.2` es un symlink relativo a
`ld-2.36.so`; copiado con `cp -a` a un árbol nuevo queda **colgando** y el
siguiente `cp` falla con `not writing through dangling symlink`. Usa `cp -L`
(sigue el enlace) o copia el `.so` real con el nombre del intérprete.

Mínimos de glibc que dropbear necesita aunque no lo parezca: `etc/passwd`,
etc/group`, `etc/shadow`, `etc/shells`, `etc/nsswitch.conf`. Sin ellos la
autenticación falla sin mensaje útil. `authorized_keys` en `root/.ssh` con
`chmod 700` / `600`.

### Verifica el userspace ANTES de gastar un reinicio

El intérprete del propio initramfs puede ejecutar los binarios del initramfs en
el host:

```sh
./lib/ld-linux.so.2 --library-path lib/i386-linux-gnu ./usr/sbin/dropbear -V
./bin/busybox | head -1
sh -n init
```

Si `dropbear -V` imprime versión, el arranque no va a morir por una librería
que falta. Es la comprobación más rentable de toda la receta: cuesta un segundo
y ahorra un ciclo entero de encender / esperar cuelgue / apagar a la fuerza.

## 3. `init` del entorno

Orden que funciona:

1. `busybox --install -s`, montar `proc`, `sysfs`, `devtmpfs`, `devpts`,
   `tmpfs` en `/run` y `/tmp`, `hostname`, `echo 8 > printk`.
2. **Localizar la partición de Windows por contenido, no por número.** Recorre
   `/dev/mmcblk0p*`, monta con `-t ntfs3`, y acepta la que contenga `/ubuntu`;
   si no, desmonta y sigue. Numerar particiones a mano se rompe al reparticionar.
3. Crear un **directorio de arranque numerado** (`arranque-001`, `-002`, …) y
   lanzar un bucle que cada 2 s vuelque `dmesg`, su propio log y
   `/proc/interrupts` con `sync`. Así un cuelgue en negro deja datos del punto
   exacto, y los intentos no se pisan.
4. Red: esperar a que aparezca una **Ethernet de verdad** (hasta ~40 s; el
   `smsc95xx` del dock tarda en enumerar), `ip link set up`, y `udhcpc`.
   **busybox no trae `default.script`**: escríbelo tú (bound/renew → `ip addr`,
   `ip route`, `/etc/resolv.conf`) o no habrá IP.

   No vale con "la primera que no sea `lo`": el kernel puede haber creado
   `sit0`/`tunl0` antes y entonces configuras un túnel IPv6 sin IP, el log dice
   `SSH escuchando` y la máquina es invisible. Filtra por tipo ARPHRD_ETHER y
   por tener dispositivo físico detrás:

   ```sh
   for d in /sys/class/net/*; do
       n=$(basename "$d")
       [ "$(cat "$d/type" 2>/dev/null)" = 1 ] || continue   # ARPHRD_ETHER
       [ -e "$d/device" ] || continue                       # descarta sit0, tunl0, lo
       IFACE=$n; break
   done
   ```

   Y quita la trampa de raíz: `scripts/config --file .config --disable IPV6_SIT`
   en el kernel de diagnóstico. Un entorno en RAM que solo necesita Ethernet no
   pierde nada y gana un fallo menos que diagnosticar.
5. `dropbear -R -E -s -p 22`: `-R` genera las claves de host al vuelo (no hay
   `/etc/dropbear` persistente), `-s` solo clave pública, `-E` logs a stderr.
6. Dejar una shell en consola (`setsid cttyhack sh -l` en bucle) y volcar
   `lsusb` a pantalla: sirve para saber si el dock enumera.

Escribe el `init` sin bashismos y pásalo por `sh -n`: el `sh` es busybox.

## 4. Entrada de arranque

El `grub.cfg` de Wubi usa **CRLF**. Al parchearlo desde Linux, escríbelo con
`newline=''` y `\r\n` explícitos, o grub puede no reconocer las líneas.

```
menuentry "FRIDAY dev kernel 6.12 (Clover Trail)" {
    insmod efi_gop
    insmod efi_uga
    insmod gfxterm
    set gfxmode=auto
    set gfxpayload=keep
    terminal_output gfxterm
    echo "FRIDAY dev: cargando kernel..."
    linux /ubuntu/friday-dev/bzImage console=tty0 loglevel=7 noefi idle=poll button.lid_init_state=open
    echo "FRIDAY dev: cargando initramfs..."
    initrd /ubuntu/friday-dev/initramfs-elitepad.gz
    echo "FRIDAY dev: arrancando"
}
```

Antes de insertar, compáralo con el de la tableta (`scp` desde el Windows y
`cmp`): el dueño puede haberlo editado y no conviene pisar cambios a ciegas.
Inserta la entrada **delante** de las existentes, guarda el original como
`.bak-friday` y confirma con `grep -n menuentry` que quedó primera.

Los parámetros de esta entrada son los de diagnóstico ya validados
(`noefi`, `idle=poll`, `button.lid_init_state=open`); al pasar a la fase 3 se
revisan uno a uno, porque `idle=poll` quema CPU y rompe s2idle.

## Copiar los artefactos al equipo

Dos archivos, `bzImage` (~5-8 MB) e `initramfs-elitepad.gz` (~3 MB), a
`C:\ubuntu\friday-dev\` por `scp` al Windows. Comprobar tamaño en destino antes
de decirle al humano que reinicie: un `scp` cortado por suspensión de Windows
da un kernel truncado que falla igual que un parámetro mal puesto.
