# Kernel 7.3.4 i386 para HP ElitePad 900 G1 (Clover Trail) — parches 6.12 portados

**Fecha:** 2026-11-13 · **Estado:** compilado y verificado en QEMU (sin tocar la tableta)

---

## 1. Versión elegida: Linux 7.3.4 (i386), y por qué

`powervr_sgx` **apunta explícitamente a 7.3**, no a una versión que haya que adivinar:

| Evidencia | Fichero |
|---|---|
| «The driver targets 7.3 and drm-misc-next. For an older kernel, patch a copy of its sources» | `drm/ci/compat.sh:5` |
| `compat.sh` sólo añade `DRIVER_GEM_GPUVA` «(kernel before 7.3)» | `drm/ci/compat.sh:16` |
| Kernel de la placa CE5300: «kernel.org 7.3.3 with the board's patches» | `docs/DRM-DRIVER.md:306` |
| `7.3.3-m2drm` en las medidas de rendimiento | `docs/PERF.md:378` |
| `DRIVER_GEM_GPUVA` «dropped (gone in 7.3)» | `docs/UPSTREAM-READINESS.md:981` |

7.3 existe en kernel.org (serie estable viva; 7.2 ya está EOL, 7.4 va por rc2). Se eligió
**7.3.4**, la última estable de la serie que pide el driver.

**Descarga verificada:**
- Fuente: `https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-7.3.4.tar.xz`
- SHA-256: `b11b6df8295e8e991ff040b71aaa4994a8b55caa23b6b092907f195b5840fd1f` — **idéntico** al de
  `sha256sums.asc` de kernel.org.
- Firma GPG de `sha256sums.asc`: **Good signature from "Kernel.org checksum autosigner <autosigner@kernel.org>"**
  (clave `B8868C80BA62A1FFFAF5FDA9632D3A06589DA6B1`, importada de keyserver.ubuntu.com;
  keys.openpgp.org la sirve sin UID y no sirve para verificar).

> Nota: se usó 7.3.4 en vez de 7.3.3 (la del CI del repo) por ser la última estable de la
> misma serie; las APIs que el driver necesita son las de 7.3.

---

## 2. Parches: estado y adaptaciones

Los 6 parches originales están en `patches/` (6.12). Los de 7.x están en **`patches-7.x/`**,
regenerados contra 7.3.4 limpio. Verificado: aplicar 0001→0006 sobre 7.3.4 prístino reproduce
el árbol de trabajo **byte a byte** (`diff` de los 10 ficheros tocados = idéntico).

| Parche | Contenido | Estado en 7.3.4 |
|---|---|---|
| `0001-ehci-platform-clover-trail-acpi-ids.patch` | IDs ACPI `INT33B6` / `INT33B9` en `ehci-platform.c` | **Aplica limpio** (offset +29 líneas) |
| `0002-ehci-platform-acpi-dsm-post-reset.patch` | `_DSM` post-reset (UUID `ce2ee385…`) para poner el OTG en host mode | **Aplica limpio** (offset +1) |
| `0003-cloverview-scu-cold-reset.patch` | driver `cloverview_scu_reset` (INT33B5) + `do_kernel_restart()` en `native_machine_emergency_restart` | **Aplica limpio** (offset -48 en `reboot.c`, -136 en Kconfig) |
| `0004-gpio-cloverview-int33b2.patch` | driver GPIO propio (INT33B2, 2 bancos × 96 pines, IRQ) | Aplica salvo **1 hunk del Makefile**; ver adaptación A |
| `0005-i2c-designware-cloverview-int33b1.patch` | INT33B1: 17/20.5 MHz, HCNT/LCNT, FIFO 256 | Aplica salvo **1 hunk**; ver adaptación B |
| `0006-sdhci-acpi-cloverview-sdio-1v8.patch` | INT33BB uid2: anunciar 3.3 V, alimentar a 1.8 V | **Aplica limpio** |

### Adaptaciones documentadas

**A) `drivers/gpio/Makefile`** — en 7.3 las entradas están separadas por líneas en blanco y se
añadió `GPIO_CGBC`, así que el contexto del hunk ya no existe. La línea
`obj-$(CONFIG_GPIO_CLOVERVIEW) += gpio-cloverview.o` se inserta en orden alfabético
(entre `GPIO_CGBC` y `GPIO_CLPS711X`). Sin cambio funcional.

**B) `i2c_dw_get_clk_rate_khz()`** — 7.3 renombró la constante `KILO` a `HZ_PER_KHZ`
(`clk_get_rate(dev->clk) / HZ_PER_KHZ`). Sólo cambia la línea de contexto del hunk; el código
nuevo de Cloverview no cambia.

**C) Cambio de API real: `struct gpio_chip.set` devuelve `int` en 7.3** (era `void` en 6.12).
`clv_set()` en `gpio-cloverview.c` pasa a `static int` y termina en `return 0;`. Es el **único**
cambio de API necesario; el resto (IRQ chip inmutable, `devm_register_sys_off_handler`,
`sdhci_set_power`, `host->ocr_mask`, `devm_platform_ioremap_resource`) sigue igual en 7.3.

Los seis objetos implicados compilan **sin un solo warning**:
`arch/x86/kernel/reboot.o`, `cloverview_scu_reset.o`, `gpio-cloverview.o`,
`i2c-designware-platdrv.o`, `sdhci-acpi.o`, `ehci-platform.o`. La compilación completa
(`bzImage`) salió con **0 warnings**.

---

## 3. Configuración

Script: **`config-elitepad-7.x.sh`** (acepta el árbol como `$1`). No parte de `i386_defconfig`
como el de 6.12: parte de la config ya validada en la tableta
(`out/config-6.12.117-elitepad`) y deja que `olddefconfig` resuelva los símbolos nuevos.

Opciones exigidas, **todas verificadas en el `.config` final**:

```
X86_32=y                 MATOM=y                  GPIO_CLOVERVIEW=y
CLOVERVIEW_SCU_RESET=y   I2C_DESIGNWARE_PLATFORM=y  I2C_HID_ACPI=y
HID_MULTITOUCH=y         ATH6KL_SDIO=y            MMC_SDHCI_ACPI=y
USB_EHCI_HCD_PLATFORM=y  USB_NET_SMSC95XX=y       NTFS3_FS=y
FB_EFI=y                 SYSFB=y                  SYSFB_SIMPLEFB=y
DRM=y                    DRM_KMS_HELPER=y         DRM_SIMPLEDRM=y
DRM_FBDEV_EMULATION=y    FRAMEBUFFER_CONSOLE=y    EFI=y  EFI_STUB=y
LOCALVERSION="-elitepad"
```

### PINCTRL_BAYTRAIL: desactivado (y por qué es más fuerte que "desactivado")

En 7.3 el *menú* de pinctrl Intel sólo se evalúa si `CONFIG_PINCTRL=y`. Aquí `CONFIG_PINCTRL`
está en `n`, así que **`PINCTRL_BAYTRAIL` ni siquiera existe como símbolo** en el `.config`
(no se puede activar por accidente). Se mantiene la lección de 6.12: `pinctrl-baytrail` reclama
`INT33B2` y hacía que la tapa se leyera como "cerrada".

### Pantalla: qué consola queda con simpledrm

`SYSFB_SIMPLEFB=y` hace que `sysfb` (drivers/firmware/sysfb.c:167-173) cree el dispositivo
`simple-framebuffer` en vez del `efi-framebuffer`, así que:

- **Con EFI (la tableta):** `simpledrm` toma el framebuffer del GOP → `/dev/fb0` **KMS** →
  `fbcon` se engancha igual que antes. **La consola de texto sigue funcionando**, pero por
  simpledrm, no por efifb. `efifb` queda compilado y **sin engancharse** (no recibe dispositivo).
- **Si el modo del firmware no es compatible con simplefb** (parseo de `screen_info` falla, p.ej.
  profundidad rara), `sysfb` cae al camino antiguo `efi-framebuffer` y **`efifb` vuelve a
  engancharse automáticamente**. Por eso `FB_EFI` se deja activado: es el respaldo.
- Esto es lo que pide la ruta de `powervr_sgx` (KMS sobre el fb del firmware + kmsro), según
  `ref/plan-sgx545-clovertrail.md` §0.5.

Comprobado en el binario: `simpledrm_probe` y `sysfb_init` están en `System.map`, y las cadenas
`simple-framebuffer`, `efi-framebuffer` y `simpledrm` están en `vmlinux`.

---

## 4. Compilación

```
cd linux-7.x/linux-7.3.4
nice -n 10 make ARCH=i386 -j3 bzImage
```

Resultado: `Kernel: arch/x86/boot/bzImage is ready (#1)`, 13 MB, **0 warnings**. Tiempo medido
(config + compilación, de extremo a extremo): **~15 min** con `-j3` y `nice 10`, para no cargar
la VM. Tipo: `Linux kernel x86 boot executable, bzImage, version 7.3.4-elitepad ...
SMP PREEMPT_DYNAMIC`, gcc 14.2.0.

Log completo: `logs/build-7.3.4.log`.

Verificación de que los parches están dentro del binario:

```
clv_gpio_probe        1     INT33B2  1   INT33B6  1
clv_scu_reset_probe   1     INT33B5  1   INT33B9  1
sdhci_acpi_clv_sdio_set_power 1   INT33B1 2  INT33BB 2
```
(`ehci_platform_acpi_post_reset` e `i2c_dw_clv_configure` salen 0 porque son `static` inlineados;
sus tablas ACPI sí están, como muestran las cadenas.)

---

## 5. Verificación en QEMU

```
timeout -s TERM 90 qemu-system-i386 -cpu max -m 1024 -nographic -no-reboot \
  -kernel out-7.x/bzImage -initrd out/initramfs-elitepad.gz \
  -append "console=ttyS0 loglevel=7" -nic user
```

Salida real (`logs/qemu-7.3.4.log`, 376 líneas, **0** `BUG:`, `Oops`, `WARNING:` o panic):

```
[    0.000000] Linux version 7.3.4-elitepad (friday@friday) ... #1 SMP PREEMPT_DYNAMIC
[FRIDAY 5.61s] init arrancado, kernel 7.3.4-elitepad
[FRIDAY 25.93s] AVISO: no he podido montar el NTFS de Windows (sin logs persistentes)
[FRIDAY 26.08s] interfaz de red: eth0 (52:54:00:12:34:56)
[FRIDAY 30.19s] IP:     inet 10.0.2.15/24 scope global eth0
[FRIDAY 30.32s] SSH escuchando en el puerto 22
[FRIDAY 30.34s] listo. Dispositivos USB:
/ #
```

El init del initramfs llega al final y da shell: red por `-nic user`, dropbear escuchando, sin
errores de drivers. QEMU terminó por `timeout` (rc 124); **no queda ningún proceso vivo**.

**Límite honesto de esta prueba:** en QEMU con BIOS no hay firmware EFI de 32 bits instalado
(`/usr/share/OVMF` sólo trae x86_64), así que la ruta `simpledrm` no se puede ejercitar aquí; lo
verificado es que el kernel arranca, monta el initramfs y completan todos los initcalls (el core
DRM registra `drm_connector`). La pantalla real se valida en la tableta.

---

## 6. Ficheros

| Ruta | Qué es |
|---|---|
| `linux-7.x/linux-7.3.4/` | árbol 7.3.4 con los 6 parches aplicados y compilado |
| `patches-7.x/0001…0006-*.patch` | parches portados a 7.3.4 (aplican con `patch -p1`) |
| `config-elitepad-7.x.sh` | script de config (parte de la config 6.12 + opciones DRM/SYSFB) |
| `out-7.x/bzImage` | kernel compilado (13 MB) |
| `out-7.x/config-7.3.4-elitepad` | config final |
| `out-7.x/System.map-7.3.4-elitepad` | símbolos |
| `logs/build-7.3.4.log` | log de compilación |
| `logs/qemu-7.3.4.log` | log del arranque en QEMU |

### Reproducir desde cero

```sh
cd ~/elitepad-dev
curl -O https://cdn.kernel.org/pub/linux/kernel/v7.x/linux-7.3.4.tar.xz
sha256sum linux-7.3.4.tar.xz   # b11b6df8295e8e991ff040b71aaa4994a8b55caa23b6b092907f195b5840fd1f
mkdir -p linux-7.x && tar -xf linux-7.3.4.tar.xz -C linux-7.x && rm linux-7.3.4.tar.xz
cd linux-7.x/linux-7.3.4
for p in ../../patches-7.x/*.patch; do patch -p1 --forward --batch < "$p"; done
../../config-elitepad-7.x.sh .
nice -n 10 make ARCH=i386 -j3 bzImage
```

---

## 7. Siguiente paso (no hecho aquí)

`powervr_sgx` como módulo contra este árbol:

```sh
cd ~/src/powervr_sgx/drm
sh ci/compat.sh ~/elitepad-dev/linux-7.x/linux-7.3.4 .   # no debería tocar nada: ya es 7.3
make KDIR=~/elitepad-dev/linux-7.x/linux-7.3.4 ARCH=i386 modules
```

Antes de tocar la tableta conviene arrancar este `bzImage` **en RAM** (initramfs actual) y
comprobar en `dmesg` que siguen saliendo los bindings de INT33B2/B1/BB/B6/B9 y que simpledrm
toma la pantalla.

## Parches 0007-0010 (7.x)

| Parche | Qué hace |
|---|---|
| `0007-mmc-sdhci-acpi-clover-trail-emmc-ctv_emmc.patch` | ranura INT33BA con bus de 8 bits, activable con `sdhci_acpi.ctv_emmc=1` |
| `0008-x86-cpa-skip-highmem-pages-in-page-arrays.patch` | CPA: no desreferenciar páginas HIGHMEM en arrays de páginas (oops con `powervr_sgx.highmem=1`) |
| `0009-x86-pat-track-memtype-of-highmem-pages-in-page-arrays.patch` | PAT: reservar el tipo de memoria de las páginas HIGHMEM (WC real para la GPU) |
| `0010-drm-simpledrm-use-vblank-timer.patch` | `simpledrm` con el temporizador de vblank de DRM: Present deja de ir a ~1 Hz |

`config-7.3.4-elitepad` es el `/proc/config.gz` del kernel que corre en la tableta
(#8, con `USER_NS`, zram/zsmalloc y los cuatro parches de arriba).
