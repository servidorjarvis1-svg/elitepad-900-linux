# Plan de port de `powervr_sgx` al PowerVR SGX545 de Clover Trail (Atom Z2760, HP ElitePad 900 G1)

**Fecha:** 2026-11-13 · **Autor:** subagente de investigación de FRIDAY · **Estado:** investigación + plan (no se ha tocado la tableta)

Repositorio estudiado: `https://github.com/The1TrueJoe/powervr_sgx`
Clon local (solo lectura): **`$HOME/src/powervr_sgx`** (33 MB, `--depth 1 --filter=blob:none --no-single-branch`, rama `main`; `dev` accesible como `origin/dev`).
Commit de `main` analizado: `25022a5` (repo creado 2026-08-27, último push 2026-11-13, 14 estrellas).

---

## 0. Resumen ejecutivo (lo que importa en 60 segundos)

1. **El port es viable y el trabajo de kernel es pequeño**: la SGX545 de Clover Trail es el *mismo núcleo* que la de Cedarview/CE5300 (mismo `CORE_ID` 0x0115, mismas features, misma ISA, mismos 16 directorios BIF, MMU de 32 bits). El driver nuevo (`drm/`) hace **toda** la inicialización por sí mismo (clock gating, reset, script de init, kick del microkernel): no necesitamos `srvinit` ni el DDK.
2. **La GPU de la tableta está en `00:02.0`, BAR0 = `0xff200000`, 1 MiB.** La ventana SGX es, con alta probabilidad, **BAR0 + 0x80000 = `0xFF280000`** (offset `MRST_SGX_OFFSET` de Medfield/Cedarview). Los dos registros para identificarla son **`0xFF28001C` (`CORE_ID`)** y **`0xFF280020` (`CORE_REVISION`)**.
3. **i386 no es un bloqueo, pero está sin CI**: Mesa se compila hoy para i386 (`mesa/build.sh i386`), el microkernel es Python offline (agnóstico), y el driver DRM no tiene nada de 64 bits… **pero apunta a Linux 7.3** (`kzalloc_obj()`, `pcim_iomap_region()`, `drm_sched_job_init()` de 5 argumentos) y nuestro kernel es 6.12.117. Hay que elegir: kernel 7.3 i386 (recomendado) o backport de ~6-10 shims.
4. **Encendido de la isla gráfica**: en Cloverview **no hay código ACPI** (`_PS0` solo escribe SSID y una variable global; no existe `_PR0`). La isla la gobierna el **P-Unit** por el bloque **APM** (bit 0 = `APM_GRAPHICS_ISLAND`), accesible por *message bus* en el config space de `00:00.0` (regs `0xD0/0xD4/0xD8`). Con el GOP/efifb escaneando, **la isla ya está encendida** y probablemente no hay que hacer nada.
5. **Pantalla**: con `efifb` no hay KMS y el backend `powervr_sgx` de Mesa **no implementa `bo_wrap`** → el EGL fbdev no puede envolver `/dev/fb0`. La ruta recomendada es **`simpledrm` (KMS sobre el framebuffer del firmware) + kmsro** — exactamente lo que el proyecto ya usa en su placa de desarrollo CE5300.
6. **Estimación honesta (a tiempo parcial):** identificar GPU 1 sesión; driver enlazado y microkernel arriba 2–5 semanas; primer frame 2–6 semanas; Mesa/EGL en pantalla 2–4 semanas; compositor Wayland 1–2 semanas; navegador usable (raster software) 2–4 semanas. **Riesgo principal: que el microkernel no arranque por una errata del stepping de Clover Trail**, no el código de plataforma.

---

## 1. Qué es `powervr_sgx` y en qué estado está (verificado en el clon)

| Pieza | Ruta | Estado según el repo |
|---|---|---|
| Driver DRM nuevo | `drm/powervr_sgx/` | `powervr_sgx`: GEM shmem, `drm_gpuvm`, `drm_sched`, runtime PM, devcoredump, debugfs (`README.md:14`) |
| Firmware abierto | `ukernel/` | Microkernel en ensamblador USSE + ensamblador propio; config por núcleo en `ukernel/cores/sgx545.py` |
| Driver GL | `mesa/` (overlay sobre **Mesa 26.2.5**, `mesa/VERSION`) | Gallium `sgx`: GL 2.1 / GLES2 / EGL / GBM / GLX / DRI3 (`README.md:16`) |
| Parches gma500 | `drm/gma500/0001..0005` | Publican la SGX de Cedarview como dispositivo auxiliar `gma500_gfx.sgx` |
| Camino viejo | `kernel/` (`pvrsrvkm` DDK 1.7), `srvinit/`, `libpvr/` | Se mantiene “para comparaciones”; **el stack nuevo no lo usa** (`README.md:22-24`) |
| Docs de port | `docs/porting/kernel.md`, `microkernel.md`, `mesa.md`, `cores/sgx530.md` | Guías por etapas con criterios de “hecho” y trampas |

**Núcleos soportados hoy** (`docs/porting/README.md:14-20`, `drm/powervr_sgx/pvrsgx_core.c:57-94`):

| Núcleo | Ejemplo | Estado |
|---|---|---|
| **SGX545** | **Cedarview (GMA 3600/3650), CE5300/CE5310** | **Soportado** (revs 1.0.13 y 1.0.14) |
| SGX535 / 530 / 540 | Poulsbo, OMAP3, OMAP4 | “Wanted” |
| SGX543/544/554 | USSE2 (OMAP5, Allwinner, MediaTek) | Requiere USSE2 en compilador y ensamblador |

**Sobre Clover Trail, textual** (`AGENTS.md:44`):
> “**Clover Trail (Atom Z2760)** also has SGX545, but its display has no upstream support. Out of scope.”

Eso es una decisión de **alcance** (la pantalla no tiene driver upstream), no una imposibilidad técnica del núcleo. Nuestro port ataca justo esa parte con `simpledrm`.

**Estado real del hardware soportado** (`README.md:28-40`): dEQP-GLES2 16.587 pasan / 129 fallan; escritorio Xorg+glamor+Xfce; Minecraft 1.7.10 15 min sin recovery; en Cedarview “el microkernel arranca y dibuja frames en la SGX545 (revisión 1.0.13)”.

---

## 2. Estado verificado de *nuestra* tableta (no supuesto)

Todo sale de los logs de arranque reales y de las tablas ACPI descompiladas que ya tenemos.

| Dato | Valor | Fuente |
|---|---|---|
| GPU PCI | `0000:00:02.0  8086:08cf  class 0x030000` | `ref/logs4/friday-live/dmesg.txt:510` |
| **BAR0** | **`mem 0xff200000-0xff2fffff` (1 MiB)** | `dmesg.txt:511` · `journal.txt:513` |
| BAR1 | `io 0x1000-0x1007` (8 B) | `dmesg.txt:512` |
| BAR2 | `mem 0xe0000000-0xefffffff` (256 MiB, aperture; Linux la reasigna a `0x80000000`) | `dmesg.txt:513,533,551` |
| BAR3 | `mem 0xdffc0000-0xdfffffff` (256 KiB, GTT) | `dmesg.txt:514` |
| Ventana reservada en `_CRS` de PCI0 | `Memory32Fixed(RW, 0xFF200000, 0x00100000)` | `DSDT_INTEL__CLOVERVW_00000011.dsl:5937-5940` |
| **IRQ (INTx A)** | **GSI `0x10` = 16**, fuente directa (`Zero`), `_ADR 0x00020000` | `DSDT...dsl:5874-5883` |
| `_PS0` / `_PS3` | `_PS0`: `SSID = 0x18DC103C`, `\_SB.GDDS = 0` · `_PS3`: `\_SB.GDDS = 3`. **Sin `_PR0`, sin OperationRegion de isla** | `DSDT...dsl:6033-6042` |
| Regiones del DSDT dentro de GFX0 | `GSTS` = `0xFF13F000` (64 KiB), `RBPS` = `0xFF119000` (256 B) — display/panel power sequencing | `DSDT...dsl:5973`, `:5994` |
| PEP | `Device(PEP)` `_HID INT3395`, `_CID PNP0D80` (PEP de Intel para Windows) | `DSDT...dsl:6238-6260` |
| Framebuffer actual | `efifb` 1280x800x32, `linelength=5120`, **`fb at 0x7f000000`, 4032 KiB** | `dmesg.txt:587-594` |
| RAM reservada del firmware | `0x7edff000-0x7fffffff` (incluye el framebuffer) | `dmesg.txt:27` |
| CPU | family 6 model **0x35** = `INTEL_ATOM_CLV` (Cloverview) | `intel_mid_pm.h:33` (`#define INTEL_ATOM_CLV 0x35`) en `$HOME/src/k900/kernel` |
| Kernel propio | 6.12.117 i386 (`X86_32`, `MATOM`, `HIGHMEM4G`), `DRM=y`, **`DRM_GMA500` off**, `FB_EFI=y`, `DRM_SIMPLEDRM` off, `SYSFB_SIMPLEFB` off, `DEVMEM=y`, `STRICT_DEVMEM=y` | `linux-6.12.117/.config:1512-1513,3363,3415,3443,3462,2688,5433` · `config-elitepad.sh` |
| Arranque | GRUB con `noefi`, kernel desde eMMC/USB, initramfs con **busybox 1.35 estático (tiene `devmem`)** | `build-initramfs.sh:11-13`, `initramfs-src/` |

**Conclusión estructural:** una sola función PCI (00:02.0) contiene display (BAR0+0) **y** la SGX (BAR0+n); es el mismo modelo que Cedarview, que el proyecto ya resolvió con un dispositivo auxiliar. Nosotros no tenemos gma500, así que **reclamamos la función nosotros** y mapeamos BAR0 con offset.

---

## 3. Pregunta 1 — Qué necesita el driver para “publicar” la GPU, y cómo identificarla con seguridad

### 3.1 Lo que exige la guía (`docs/porting/kernel.md`)

`docs/porting/kernel.md:15-42` — una plataforma nueva es una entrada en dos tablas:

| Campo | Qué es | De dónde sale |
|---|---|---|
| `family.core` | número de núcleo (545) | glue de bus / DT |
| `family.core_id` | `CORE_ID` esperado | **lectura en hardware (etapa 3)** |
| `family.regs` | registros con offset/campos distintos | `sgx5xxdefs.h` del DDK GPL |
| `family.features` | `PVRSGX_FEATURE_*` | `sgxfeaturedefs.h`; debe incluir `PVRSGX_FEATURES_REQUIRED` |
| `family.isa` | USSE1/USSE2 | SGX545 = USSE |
| `family.num_dir_lists` | listas de directorios BIF | 16 en 535/545 |
| `family.va_bits` | bits de dirección de dispositivo | **32** (el heap necesita 32) |
| `family.init_regs` | script de init parte 2 | capturado de un arranque que funciona |
| `info.core_rev` | `CORE_REVISION` esperado | **lectura en hardware** |
| `info.clock_hz` | reloj del núcleo (timer del microkernel) | orden de magnitud basta |
| `info.fw_name` | `powervr_sgx/sgx<core>_ukernel.bin` | microkernel abierto |

Tres patrones de “publicar” (`kernel.md:44-70`): (a) **función PCI propia** (CE5300, `8086:089b`); (b) **detrás de un driver de display vía bus auxiliar** (Cedarview); (c) **SoC con device tree**. *Nuestro caso es una variante de (a): función PCI propia, pero con la ventana de registros desplazada dentro del BAR.*

**Lo que el driver NO necesita de la plataforma** (verificado en código): no pide clocks ni reguladores ni power domains; el reloj solo se usa como constante (`pvrsgx_fw.c:480`: `hc[HOSTCTL_UK_TIMER_CLOCK] = clock_hz / UKERNEL_TIMER_HZ`). Tampoco pide `srvinit`: `pvrsgx_fw_start()` hace clock gating (`pvrsgx_fw.c:489-495`), `pvrsgx_reset()`, `init_script_part2()` y el kick (`:497-505`).

### 3.2 Offsets exactos (verificados en `drm/powervr_sgx/pvrsgx_regs.h`)

Registros **seguros de leer en un núcleo sin inicializar** (lista blanca del propio repo, `pvrsgx_regs.h:10-15`):

| Offset | Nombre | Contenido / valor esperado | Línea |
|---|---|---|---|
| `0x000` | `CLKGATECTL` | modo 2 bits/unidad; `b10-11` = DPM | `:16-18` |
| `0x004` | `CLKGATECTL2` | ídem para PBE/caches/USE/TEX | `:19-20` |
| `0x008` | `CLKGATESTATUS` | 1 = reloj corriendo; ocioso ≈ `0x20` | `:21-22` |
| **`0x01C`** | **`CORE_ID`** | **`CONFIG` b0-15, `ID` b16-31 → SGX545 = `0x0115xxxx`** | `:23`, layout en `docs/UKERNEL.md:1016` |
| **`0x020`** | **`CORE_REVISION`** | `MAINTENANCE` b0-7, `MINOR` b8-15, `MAJOR` b16-23, `DESIGNER` b24-31 → 1.0.14 = `0x0001000e` | `:24`, `UKERNEL.md:1017` |
| `0x080` | `SOFT_RESET` | BIF b0, DPM b1, TA b2, USE b3, ISP b4, TSP b5 | `:25-31` |
| `0x12C` | `EVENT_STATUS` | `MASTER_INTERRUPT` b31, `TIMER` b29, `SW_EVENT` b14 | `:35-38` |
| `0x130` | `EVENT_HOST_ENABLE` | enables | `:39` |
| `0xC00` | `BIF_CTRL` | `PAUSE` b1, `INVALDC` b3, `CLEAR_FAULT` b4 | `:52-55` |

Valores de referencia del mismo núcleo (`pvrsgx_core.c:73-94`): CE5300 → `0x01150000` / `0x0001000e`; Cedarview → `0x01150000` / `0x0001000d`.

> **Atención (posible bug a parchear):** `pvrsgx_core_lookup()` compara `core_id` con **igualdad exacta** (`pvrsgx_core.c:118`). Si Clover Trail devuelve `CORE_ID` con bits de `CONFIG` distintos de 0 (p. ej. `0x01150001`), el driver rechazará el núcleo aunque sea una SGX545. Ver §6.1 (c).

### 3.3 Procedimiento **seguro** para identificar el núcleo en la tableta

**Regla de oro del repo** (`docs/porting/microkernel.md:44-59`): *solo registros con nombre; nunca barridos de MMIO; un barrido del espacio de display colgó una placa CE5300; un SGX colgado puede colgar el bus y solo se sale con cold boot.*

#### Paso 0 — Confirmar el BAR (sin MMIO, riesgo cero)
```sh
lspci -s 00:02.0 -vv | head -12        # o: setpci -s 00:02.0 10.l
# esperado: 0xff200000 (memoria, 1 MiB) e IRQ 16
```

#### Paso 1 — **Dos** lecturas, de una en una
```sh
busybox devmem 0xFF28001C 32    # CORE_ID       -> esperado 0x0115xxxx
busybox devmem 0xFF280020 32    # CORE_REVISION -> esperado 0x000100xx
```
Interpretación:
- `0x0115xxxx` → **núcleo confirmado**; el `xxxx` es `CONFIG` (b0-15).
- `0x0115` + `0x0001000d`/`0x0001000e` → misma revisión que Cedarview/CE5300 → camino directo.
- `0x0115` + otra `MAINTENANCE` (p. ej. `0x0001000f`) → solo hay que añadir una entrada a la tabla.
- `0xFFFFFFFF` o `0x00000000` → **la ventana no está ahí o el reloj/isla está apagado**: parar y hacer el Paso 2 (encendido) antes de probar otros offsets.

#### Paso 2 (solo si el Paso 1 no da `0x0115`) — mirar el estado de la isla **sin tocar MMIO de GPU**
```sh
# base del bloque APM desde el P-Unit (message bus en el config space de 00:00.0)
setpci -s 00:00.0 0xd0.l=0x10047af0      # READ, port 0x04, reg 0x7a (OSPM_APMBA), dword
setpci -s 00:00.0 0xd4.l                 # -> base APM (16 bits bajos)
setpci -s 00:00.0 0xd0.l=0x100478f0      # READ, port 0x04, reg 0x78 (OSPM_OSPMBA)
setpci -s 00:00.0 0xd4.l                 # -> base OSPM
# estado de islas (APM_STS = base+4), 2 bits por LSS: 0 = D0I0 (on), 3 = D0I3 (off)
dd if=/dev/port bs=1 skip=$((APM_BASE+4)) count=4 2>/dev/null | od -An -tx4
# bit 0-1 = APM_GRAPHICS_ISLAND ("GFX"), esperado 00 (encendida)
```
*Cuidado con los dos espacios de nombres:* `APM_GRAPHICS_ISLAND 0x1` (`intel_mid_pm.h:51`) indexa **islas del bloque APM** (bits 0-1 del registro), mientras que `GFX_LSS_INDEX 1` (`intel_soc_clv.h:31`) es el **índice del dispositivo PCI** en la tabla del driver de PMU — no es el mismo “1”. El que vale para el registro es el bit 0.
Esto es **solo lectura de config space + puertos de E/S**, sin MMIO de GPU: riesgo prácticamente nulo.

#### Paso 3 (opcional) — resto de la lista blanca, una por una
```sh
busybox devmem 0xFF280000 32   # CLKGATECTL
busybox devmem 0xFF280008 32   # CLKGATESTATUS
busybox devmem 0xFF280080 32   # SOFT_RESET
busybox devmem 0xFF28012C 32   # EVENT_STATUS
busybox devmem 0xFF280130 32   # EVENT_HOST_ENABLE
busybox devmem 0xFF280C00 32   # BIF_CTRL
```

#### **Lo que NO hay que tocar**
| Zona | Por qué |
|---|---|
| `0xFF200000`–`0xFF27FFFF` (mitad baja de BAR0) | registros del motor de display; una lectura a un registro equivocado puede colgar la máquina |
| **Cualquier escritura** al bloque SGX con `devmem` | `CLKGATECTL`/`SOFT_RESET` mal escritos cuelgan el bus; para escribir está el driver |
| `0xFF119000` (`RBPS`) y `0xFF13F000` (`GSTS`) | secuenciación de panel/backlight del DSDT (`DSDT:5973,5994`) |
| `0xFF11C000`–`0xFF11DFFF` | buzón SCU IPC (reset/PMIC): un write aquí puede apagar o resetear la tableta |
| BAR2 (`0x80000000`, 256 MiB) y BAR3 (`0xdffc0000`, GTT) | aperture/GTT: no hacen falta para identificar nada |
| Barridos (`for addr in ...`) | prohibidos por el propio proyecto; fue la causa de un cuelgue documentado |

#### Plan de recuperación (obligatorio antes de empezar)
1. USB con el kernel 6.12.117 actual + initramfs conocido (ya existe) como *fallback*.
2. Nunca flashear: arrancar kernels nuevos **desde USB/RAM** (`kernel.md:11-13`).
3. Si se cuelga: pulsación larga (10 s) y arranque desde USB. La ElitePad no tiene consola serie: el coste de un cuelgue es un ciclo de encendido, no un ladrillo.

---

## 4. Pregunta 2 — ¿Soporta i386? Veredicto por componente

| Componente | ¿i386? | Evidencia | Riesgo |
|---|---|---|---|
| **Microkernel (`ukernel/`)** | **Sí, nativo** | Se ensambla offline con Python (`ukernel/build.py <core> out.bin`); es código para el procesador del GPU, no para la CPU | nulo |
| **Herramientas (`tools/`)** | **Sí** | `docs/porting/state.md:168`: el tracer “build.sh (i386 y x86_64)” | nulo |
| **Mesa gallium `sgx`** | **Sí, ya construido** | `mesa/build.sh:26-33`: targets `x86_64` **e `i386`** (`zig cc`, `x86-linux-gnu.2.36`, `cpu=i686`); `mesa/README.md` §Building: `mesa/build.sh x86_64 i386` | bajo |
| **uAPI (DRM)** | **Sí, por diseño** | `docs/UAPI.md:631` “idéntico en i386 y x86_64”; `AGENTS.md:61` lo exige; CI compila el header para `i386-linux-gnu` (`.github/workflows/powervr-sgx-upstream.yml:57-70`) | nulo |
| **`pvrsrvkm` (camino viejo)** | **Sí, probado** | `AGENTS.md:33`: “portado a Linux 7.1 con un puente compat i386↔x86_64”; el cliente i386 `gles2tri` dibuja en sus pruebas (`docs/SRVINIT.md`) | bajo (pero es el camino que el proyecto abandona) |
| **Driver DRM `powervr_sgx`** | **Compila en teoría, nunca se ha compilado** | `Kconfig:6` `depends on DRM && PCI && MMU && X86` (no `X86_64`); no hay `CONFIG_64BIT` ni suposiciones de 64 bits; `dma_set_mask_and_coherent(DMA_BIT_MASK(32))` (`pvrsgx_drv.c:251`), `alloc_page(__GFP_DMA32)` (`pvrsgx_device.c:329`). **Pero todo el CI es `ARCH=x86_64`** (`powervr-sgx-cedarview.yml:76`, `powervr-sgx.yml:97`) | **medio** |

### 4.1 El problema real de i386 no es el ancho, es la **versión de kernel**

El driver se desarrolla y se prueba contra **Linux 7.3.3** (`.github/workflows/powervr-sgx-cedarview.yml:25`) y usa APIs que **no existen en 6.12**:

| API usada | Dónde | Desde |
|---|---|---|
| `kzalloc_obj(*p)` | `pvrsgx_drv.c:145`, `pvrsgx_gem.c:52`, `pvrsgx_job.c:465,743,752`, `pvrsgx_kobj.c:61`, `pvrsgx_mmu.c:60,107`, `pvrsgx_render.c:109,249,478`, `pvrsgx_transfer.c:36`, `pvrsgx_vm.c:281,407` | ~6.15 |
| `pcim_iomap_region()` | `pvrsgx_drv.c:267` | ~6.13 |
| `drm_sched_job_init(..., drm_file, client_id)` (5 args) | `pvrsgx_job.c:756` | ~6.16 |

**Lo que sí existe ya en nuestro 6.12.117** (comprobado en `$HOME/elitepad-dev/linux-6.12.117`): `include/drm/drm_exec.h`, `include/drm/drm_gpuvm.h` (con `drm_gpuvm_init`, `drm_gpuvm_exec_lock`, `drm_gpuvm_ops`), y los `config DRM_EXEC / DRM_GPUVM / DRM_SCHED` (`drivers/gpu/drm/Kconfig:310-364`). Es decir: **el 90 % de las dependencias ya están**; falta la capa de azúcar de APIs.

**Decisión recomendada:**

| Opción | Trabajo | Riesgo |
|---|---|---|
| **A. Kernel 7.3.x i386** (recomendada) | Rebasear nuestros 6 parches locales (`patches/0001-0006`: EHCI ACPI ids, SCU cold reset, GPIO INT33B2, I2C INT33B1, SDHCI SDIO 1V8) y añadir fragmento `cloverview.fragment`. `MATOM` y `X86_32` siguen existiendo en v7.3 (`arch/x86/Kconfig.cpu`, comprobado) | medio: APIs de GPIO/I2C/SDHCI pueden haber cambiado |
| **B. Backport a 6.12** | Shims: `kzalloc_obj`→`kzalloc(sizeof(*p))`, `pcim_iomap_region`→`pcim_iomap_regions`+offset, `drm_sched_job_init` de 5 args→4 + relleno | medio: el driver cambia a menudo; mantenimiento continuo |
| C. Dejar 6.12 y esperar | — | no sirve: el firmware/microkernel depende del driver nuevo |

**Veredicto:** *i386 no es el bloqueo; la versión de kernel sí.* Con 7.3 i386 el driver compila “tal cual” (su CI ya lo hace para x86_64 con el mismo código C). El único punto a vigilar es el **cliente Mesa de 32 bits** (ya construido hoy) y el **kernel de 32 bits con 2 GB** (`HIGHMEM4G`: los BOs deben quedar por debajo de 4 GB, que es el caso).

### 4.2 ¿Depende el microkernel de la revisión del núcleo (1014 vs 10131)?

**No.** Verificado en `docs/UKERNEL.md:930-975`:
- Ambas revisiones reportan `CORE_ID` `0x0115`; `CORE_REVISION` `0x0001000d` (Cedarview, errata 10131) o `0x0001000e` (CE5300, 1014).
- “**No `SGX_FEATURE_*` is keyed on the revision**”, así que mismas features, ISA y palabras de estado.
- “**The microkernel does not branch on the revision**”: el DDK solo lee `CORE_REVISION`/`CORE_ID` para reportarlas en `GETMISCINFO`.
- Lo único atado a revisión es `FIX_HW_BRN_31939` (build 1013, un watchdog en la palabra 16 del host-control) y `FIX_HW_BRN_SAMPLE_CACHE` (heap de texturas separado en `0xf0000000`, aplica a **todas**).

**Para otra revisión de SGX545 solo hay que**: (1) añadir la entrada en `cores[]` con el `core_rev` leído y `clock_hz` (Z2760 = **533 MHz**, dato público: notebookcheck “SGX545 is clocked at 533 MHz” para el Z2760), (2) usar el mismo `sgx545_ukernel.bin`, (3) comprobar que no aparece una errata nueva. Para **otro núcleo** (530/535/540) sí haría falta `ukernel/cores/<core>.py` y datos de ISA (`docs/porting/microkernel.md:14-22`).

---

## 5. Pregunta 3 — Cómo se enciende la isla gráfica en Clover Trail

### 5.1 Lo que hace el DSDT (y lo que no)

- GFX0 tiene `_ADR 0x00020000`, `_DEP` = `\_SB.PEP, \_SB.I2C0, \_SB.I2C3` (`DSDT:5944-5950`).
- `_PS0`: `SSID = 0x18DC103C` (subsystem id) y `\_SB.GDDS = Zero`. `_PS3`: `\_SB.GDDS = 0x03` (`:6033-6042`). **No hay `PowerResource`, no hay `_PR0/_PR3`, no hay `OperationRegion` de P-Unit, no hay escritura a registros de GPU.**
- El `PEP` (`INT3395`, `PNP0D80`) expone el `_DSM` de Intel (`UUID b8febfe0-…`, `:6250-6265`) — es la vía **de Windows** (D-state/PEP), no hay driver en mainline.
- Conclusión: **la isla no la enciende ACPI.** La gobierna el P-Unit; `GDDS` es solo una variable global del firmware (“Graphics Device Driver Status”) que el ASL usa para decidir si notifica a la tapa (`:2995`).

### 5.2 El mecanismo real en Medfield/Cloverview (kernel K900, Linux 3.4)

`$HOME/src/k900/kernel` (kernel Android de Clover Trail+):

1. **Cloverview está explícitamente soportado**: `INTEL_ATOM_CLV 0x35` (`include/linux/intel_mid_pm.h:33`), drivers `intel_soc_clv.c/.h`, `intel_soc_mdfld_clv_common.c`, y `platform_is(INTEL_ATOM_CLV)` en todas las rutas de PM. Nuestro modelo de CPU es **0x35**, así que este código aplica tal cual.
2. **Las bases de los bloques de power se leen del P-Unit por *message bus*** (`arch/x86/platform/intel-mid/intel_soc_pmu.c:1842-1848`):
   ```c
   data = intel_mid_msgbus_read32(OSPM_PUNIT_PORT /*0x04*/, OSPM_APMBA  /*0x7a*/);
   mid_pmu_cxt->apm_base  = data & 0xffff;
   data = intel_mid_msgbus_read32(OSPM_PUNIT_PORT, OSPM_OSPMBA /*0x78*/);
   mid_pmu_cxt->ospm_base = data & 0xffff;
   ```
   y el *message bus* es **config space de `00:00.0`** (`arch/x86/platform/intel-mid/intel-mid.c:157-207`): `CTRL 0xD0`, `DATA 0xD4`, `CTRL_EXT 0xD8`; comando = `(0x10<<24)|(port<<16)|((addr&0xff)<<8)|0xF0` para lectura dword (`arch/x86/include/asm/intel-mid.h:34-39`).
3. **El bloque APM tiene CMD en `+0x00` y STS en `+0x04`**, 2 bits por LSS (`D0I0=0`, `D0I1=1`, `D0I2=2`, `D0I3=3`), y un cambio es *read-modify-write* + *poll* del STS (`intel_soc_mdfld_clv_common.c:360-445`, `intel_soc_pmu.h:131-139`).
4. **Islas** (`include/linux/intel_mid_pm.h:51-56`):
   ```
   APM_GRAPHICS_ISLAND  0x1     APM_VIDEO_DEC_ISLAND 0x2
   APM_VIDEO_ENC_ISLAND 0x4     APM_GL3_CACHE_ISLAND 0x8
   APM_ISP_ISLAND       0x10    APM_IPH_ISLAND       0x20
   ```
   y la tabla de depuración las nombra: `{APM_REG_TYPE, APM_GRAPHICS_ISLAND, "GFX"}` (`intel_soc_pm_debug.c:365`). El “mundo entero encendido” que usa el kernel en pánico es exactamente `pmu_nc_set_power_state(0xffff, OSPM_ISLAND_UP, APM_REG_TYPE)` (`intel_soc_pmu.c:261-262`).
5. **Ningún código del SoC enciende la isla gráfica a mano**: no hay una sola referencia a SGX en `arch/x86/platform/intel-mid/` (grep vacío). El driver de display (`gma500`/`mdfld`) solo toca registros de display (`gma_power_begin/end`), y el camino normal es **transición de D-state PCI → estado del LSS en el P-Unit** (`pmu_pci_set_power_state()`, `intel_soc_pmu.c:1338+`).

### 5.3 Qué significa para la tableta

| Pregunta | Respuesta | Base |
|---|---|---|
| ¿Está encendida la isla tras el arranque UEFI? | **Muy probablemente sí.** El GOP programó el display y `efifb` escanea desde `0x7f000000` con la pantalla encendida; display y SGX comparten la misma isla `GFX` | `dmesg.txt:587-594` + `APM_GRAPHICS_ISLAND` |
| ¿Hay que encenderla desde el driver? | **Probablemente no.** Si `CORE_ID` responde, está viva | lectura del Paso 1 |
| Si estuviera apagada, ¿cómo se enciende? | Escribir el par de bits del LSS 0 del APM a `D0I0` (0) vía `outl` en `apm_base+0`, y *poll* de `apm_base+4` | `intel_soc_mdfld_clv_common.c:397-445` |
| ¿Riesgo de que el P-Unit la apague mientras el driver la usa? | Sí, si se permite D3 al dispositivo. El driver sostiene runtime PM; con PCI propio, hay que **impedir el D3** (`pci_disable_device`/PM) o mantener la isla arriba con el APM | `pvrsgx_pm.c:20-30` |
| ¿Dónde NO mirar? | No hay nada en ACPI (`_PS0` vacío), ni en el DSDT `_PR0`; el PEP es solo para Windows | `DSDT:6033-6042`, `:6238+` |

**Nota de honestidad:** que la isla ya esté arriba es una **inferencia fuerte** (display vivo + mismo dominio de potencia), no una medida. Se confirma con la lectura de `CORE_ID` y, si se quiere, con `APM_STS` (bit 0-1 = `00`).

---

## 6. Pregunta 4 — Ruta de pantalla

### 6.1 El problema concreto

- Hoy: `efifb` 1280x800 (`/dev/fb0`), **sin KMS**, sin GEM, sin dma-buf.
- El backend `powervr_sgx` de Mesa **no implementa `bo_wrap`** (`mesa/src/gallium/winsys/sgx/drm/sgx_frame.c:145-148` responde `-ENOTSUP`; solo lo implementa el backend `services`, `sgx_pvr.c:136`). El driver gallium lo necesita para envolver el *mmap* de `/dev/fb0` (`mesa/src/gallium/drivers/sgx/sgx_resource.c:249-283`).
- Por tanto **EGL fbdev no puede presentar en `/dev/fb0` con `powervr_sgx`** tal como está hoy. El camino que sí existe es **kmsro**: el render target es nuestro, se exporta como dma-buf y lo escanea el dispositivo de display (`docs/WINSYS.md`, tabla “scanout (kmsro)”).

### 6.2 Opciones, con coste y encaje

| # | Ruta | Qué hace falta | Coste | Veredicto |
|---|---|---|---|---|
| **A** | **`simpledrm` + kmsro** (recomendada) | Kernel: `CONFIG_FB_EFI=n`, `CONFIG_SYSFB=y`, `CONFIG_SYSFB_SIMPLEFB=y`, `CONFIG_DRM_SIMPLEDRM=y`, `CONFIG_DRM_FBDEV_EMULATION=y`. Mesa: ya hay parche kmsro para simpledrm (`mesa/patches/0004-kmsro-dril-sgx-render-only.patch`, y `docs/porting/mesa.md:106-118`) | **bajo**: 5 líneas de config + probar | Reusa exactamente lo que el proyecto usa en su placa EA. `simpledrm` da `card0` con atomic + dumb buffers + PRIME; el SGX renderiza y exporta |
| **B** | **Parche Mesa: presentar por CPU** | En `platform_fbdev.c`, si `bo_wrap` falla: renderizar a un BO normal, `mmap`, `memcpy` a `/dev/fb0` en `swap_buffers` | **bajo-medio** (~100 líneas, sin tocar el kernel) | Plan B si `simpledrm` no arranca. Coste: 4 MB por frame a 1280x800 (~2–5 ms en el Atom), tearing |
| **C** | **uAPI `userptr` en el driver** (wrap de páginas de usuario como GEM) | Nuevo ioctl + `pin_user_pages` + `sg_table` + `bo_wrap` en el winsys | **alto** (~300-400 líneas, uAPI nueva, no upstream-able) | Solo si A y B fallan y se quiere cero copia |
| **D** | Driver KMS propio para el display de Cloverview | Ingeniería inversa del VDC/planos de Clover Trail (no hay driver upstream) | **muy alto** (meses) | Fuera de alcance |

### 6.3 Qué da cada ruta para el escritorio

| Consumidor | Con A (simpledrm+kmsro, GLES2/GL2.1) |
|---|---|
| `es2gears`, `kmscube`, `glmark2-es2-drm` a pantalla completa | **Sí** |
| Wayland `cage`/`labwc`/`sway` (wlroots, renderer GLES2) | **Sí en teoría** (necesitan KMS+GBM+EGL; `simpledrm` + kmsro los provee). Riesgo: wlroots pide `gbm_surface` en el device KMS y export/import dma-buf — es el caso que el proyecto ya prueba en la EA |
| Xorg `modesetting` + glamor | **Sí**: el driver expone GL 2.1 (glamor lo necesita; con menos, “texto en cajas”, `docs/porting/mesa.md:120-134`) |
| Firefox / Chromium **acelerados** | **No**: WebRender y el raster de Chromium piden GLES3/GL3.x; el driver es **GLES2**. Funcionarán con **raster software** (WebRender software / SwiftShader) — usable, lento |
| Vídeo (YouTube 720p+) | **No**: el decodificador VXD no tiene driver abierto (`AGENTS.md:143`) → decodificación en CPU de 2 núcleos in-order = no viable por encima de 480p |

**Recomendación:** **A** como ruta principal; **B** como red de seguridad. Asumir desde el principio que el objetivo realista es **GLES2 a pantalla completa + compositor ligero**, no un navegador acelerado.

---

## 7. Pregunta 5 — Estimación por fases, riesgos y evidencia necesaria

Supuesto de esfuerzo: **una persona, ~10 h/semana**, con la tableta delante y el host para compilar. Los rangos son anchos a propósito: la fase 2 es la que históricamente se lleva el tiempo (en el proyecto, “the hard part of SGX545 took weeks of hardware runs”, `docs/porting/microkernel.md:6`).

### F0 — Identificar la GPU (1 sesión, 1–3 h)
- **Hacer:** §3.3 pasos 0-3. Anotar `CORE_ID`, `CORE_REVISION`, `BAR0`, IRQ, y `APM_STS`.
- **Salida:** dos valores hexadecimales + confirmación de que la ventana `0xFF280000` responde.
- **Riesgo:** cuelgue por offset equivocado (bajo, lectura única) → cold boot.
- **Evidencia a guardar:** salida de `lspci -vv`, los `devmem`, y `dmesg` posterior.

### F1 — El driver enlaza y el microkernel arranca (2–5 semanas)
Trabajo concreto (ver §8): kernel 7.3 i386 con nuestros parches, `PCI id 0x08cf` + offset de BAR, entrada en la tabla de núcleos, firmware en `/lib/firmware/powervr_sgx/sgx545_ukernel.bin` (generado con `python3 ukernel/build.py sgx545`, sin dependencias).
- **Salida:** `dmesg` con `SGX core id 0x0115xxxx revision 0x000100xx: …` y `microkernel started`; `/sys/kernel/debug/dri/128/status` sin faults; `powered: 0` tras 500 ms idle.
- **Riesgos:** (i) el microkernel no arranca (script de init o errata del stepping) — **el riesgo grande**; (ii) IRQ compartida con el display → tormenta de interrupciones (el handler enmascara `MASTER_INTERRUPT`; el motor de display podría dejar la línea alta); (iii) el P-Unit apaga la isla al poner el dispositivo en D3.
- **Mitigación:** arrancar por USB, `job_timeout_ms` corto, devcoredump, y si hay tormenta: `nointremap`/no reclamar la IRQ en el primer arranque (modo *polling* de debug).

### F2 — Primer kick, primer triángulo, primer frame (2–6 semanas)
- **Herramientas del repo:** `powervr_sgx_test submit-null-job`, `powervr_sgx_frame -n 1 -v`, `-n 30 -k 1`, `powervr_sgx_blit -n 10`, `powervr_sgx_hang -n 5` (`docs/porting/kernel.md:133-165`).
- **Salida:** frames correctos píxel a píxel y `blit` byte a byte; después `hang` recuperando 5/5.
- **Riesgos:** palabras de estado del 3D distintas (el `init_regs` es de Cedarview/CE5300; siendo el mismo núcleo debería valer), timer del microkernel mal calibrado (533 MHz), DPM/free-list.
- **Evidencia:** los frames en PNG + `devcoredump` de cualquier fallo, guardados en `elitepad-dev/ref/sgx/`.

### F3 — Mesa/EGL en la pantalla (2–4 semanas)
- `simpledrm` + kmsro + `es2gears` a 1280x800; luego `glmark2-es2-drm`.
- **Riesgos:** alineación de stride (el winsys exige `stride % 128 == 0`, `sgx_resource.c:288`; 1280×4 = 5120 ✓), formatos, `DIRTYFB`.
- **Salida:** `eglinfo` con `PowerVR SGX545`, y un frame visible en el panel sin fbcon.

### F4 — Compositor Wayland (1–2 semanas)
- `cage` o `labwc` (wlroots GLES2) sobre simpledrm+kmsro; cursor por hardware no existe → cursor software.
- **Riesgo:** wlroots exige `gbm_surface` con modifiers/atomic que `simpledrm` puede no aceptar; si falla, Xorg+glamor es la alternativa.

### F5 — Uso real: navegador y escritorio (2–4 semanas)
- Firefox con `gfx.webrender.software=true`, Chromium con `--disable-gpu`, terminal, editor, PDF.
- **Expectativa honesta:** 1280x800 con GLES2 y 2 GB de RAM en un Atom de 2 núcleos in-order: escritorio ligero sí, vídeo y web moderna pesada no.

### F6 — Devolver el trabajo al proyecto (paralelo, opcional)
- PR pequeña y upstream-able: entrada en `cores[]`, `PCI id`, offset de BAR, fragmento de config, y una nota en `docs/porting/cores/`. La pantalla (simpledrm) es nuestra y no bloquea.
- **Riesgo social:** el proyecto declara Clover Trail “out of scope” (`AGENTS.md:44`); el argumento a su favor es que **el núcleo es el mismo** y el coste para ellos es una tabla + un offset.

**Resumen temporal:** F0 1 sesión · F1 2–5 sem · F2 2–6 sem · F3 2–4 sem · F4 1–2 sem · F5 2–4 sem → **≈2–4 meses a tiempo parcial**, con la mayor incertidumbre en F2.

---

## 8. Cambios de código concretos (lista cerrada y pequeña)

### 8.1 Kernel — `drm/powervr_sgx/`

**(a) ID PCI + offset de ventana** — `pvrsgx_drv.c:265-271,287-291`
```c
/* idea, no aplicada */
static const struct pvrsgx_part {
    unsigned int core;
    u32 regs_off;          /* 0 en CE5300; 0x80000 en Clover Trail */
} parts[] = {
    { 545, 0x00000 },      /* CE5300: la SGX es el BAR entero */
};

if (pci_resource_len(pdev, 0) < part->regs_off + PVRSGX_REGS_MIN)
        return -ENODEV;
sdev->regs = pcim_iomap_region(pdev, 0, PVRSGX_DRIVER_NAME) + part->regs_off;
...
{ PCI_VDEVICE(INTEL, 0x089b), ... },   /* CE5300  */
{ PCI_VDEVICE(INTEL, 0x08cf), ... },   /* Clover Trail Z2760 (nuevo) */
```
Nota: `PVRSGX_REGS_MIN` = `0x4000` (`pvrsgx_drv.h:20`); con offset `0x80000` quedan `0x80000` bytes de ventana (BAR 1 MiB) → sobra.

**(b) Entrada en la tabla de núcleos** — `pvrsgx_core.c:73-94`
```c
{
    .family = &families[0],
    .name = "Intel Clover Trail (SGX545 1.0.xx)",
    .core_rev = 0x0001000d,      /* <- EL VALOR LEÍDO EN F0 */
    .clock_hz = 533000000,       /* Z2760, SGX545 @533 MHz */
    .fw_name = "powervr_sgx/sgx545_ukernel.bin",
},
```

**(c) Comparación de `CORE_ID` con máscara** — `pvrsgx_core.c:118`
```c
- if (core_id != family->core_id)
+ if ((core_id & 0xffff0000) != family->core_id)   /* CONFIG b0-15 es del integrador */
```
(Necesario solo si `devmem 0xFF28001C` devuelve algo distinto de `0x01150000` en los 16 bits bajos.)

**(d) Nada más.** No hay que tocar MMU (32 bits, 16 listas), `init_regs` (mismo núcleo), firmware (mismo binario), ni el modelo de IRQ (INTx compartida: `request_threaded_irq(..., IRQF_SHARED)`, `pvrsgx_device.c:300`).

**(e) Config del kernel (fragmento nuevo, estilo `drm/ci/*.fragment`)**
```
CONFIG_DRM=y
CONFIG_DRM_POWERVR_SGX=y
CONFIG_FW_LOADER=y
CONFIG_DRM_SIMPLEDRM=y
CONFIG_SYSFB=y
CONFIG_SYSFB_SIMPLEFB=y
CONFIG_DRM_FBDEV_EMULATION=y
# dejar FB_EFI=y; poner "# CONFIG_FB_EFI is not set" solo si simpledrm no aparece
```
(o) sobre el reparto de `screen_info` en 6.12: `sysfb_init()` crea primero un dispositivo **`simple-framebuffer`** si `CONFIG_SYSFB_SIMPLEFB=y` (`drivers/firmware/sysfb.c:145-149` → `sysfb_simplefb.c:114`), y `simpledrm` solo casa con ese nombre/compatible (`drivers/gpu/drm/tiny/simpledrm.c:1107-1113`). Hoy `efifb` funciona porque `SYSFB_SIMPLEFB=n` y `sysfb` cae al dispositivo legado **`efi-framebuffer`** (`sysfb.c:167-171`, `efifb.c:602`). Por eso basta con activar `SYSFB_SIMPLEFB` + `DRM_SIMPLEDRM`; si `simpledrm` no aparece (modo no convertible a simplefb), entonces sí hay que poner `FB_EFI=n`. Al perder `efifb` se pierde `fbcon`, así que `DRM_FBDEV_EMULATION=y` no es opcional.

### 8.2 Mesa — sin cambios para F3 (si A funciona); para la ruta B
- `mesa/patches/` ya trae kmsro (`0004`), loader (`0005`) y el driver; solo hay que **construir para i386** (`mesa/build.sh i386`) y apuntar el loader al render node.
- Ruta B: parche local a `platform_fbdev.c` (presentar con `memcpy` cuando `bo_wrap` devuelve `-ENOTSUP`).

### 8.3 Firmware
```sh
python3 ukernel/build.py sgx545 /tmp/sgx545_ukernel.bin /tmp/manifest.json
install -D -m644 /tmp/sgx545_ukernel.bin /lib/firmware/powervr_sgx/sgx545_ukernel.bin
```
Sin dependencias más allá de CPython (`ukernel/README.md`, última sección).

---

## 9. Verificado vs. supuesto (para no autoengañarnos)

| Afirmación | Estado | Fuente |
|---|---|---|
| La SGX545 de Clover Trail es el mismo núcleo que Cedarview/CE5300 (USSE, 16 listas, 32 bits) | **Verificado** (documentación y tablas del repo) | `docs/porting/README.md:16`, `pvrsgx_core.c:57-71`, `UKERNEL.md:1005-1030` |
| El microkernel no depende de la revisión | **Verificado** (texto explícito) | `docs/UKERNEL.md:963-972` |
| BAR0 = 1 MiB en `0xff200000`, IRQ 16 | **Verificado** (log real + DSDT) | `dmesg.txt:511`, `DSDT:5874-5883,5937-5940` |
| **SGX en BAR0+0x80000** | **Supuesto fuerte** | `MRST_SGX_OFFSET 0x80000` en `mdfld_device.c:535` y `cdv_device.c:573` (`linux-6.12.117/drivers/gpu/drm/gma500/psb_drv.h:48`); BAR de 1 MiB = 2×0x80000. **Se confirma en F0** |
| La isla gráfica está encendida tras el GOP/efifb | **Supuesto fuerte** (mismo dominio de potencia, display vivo) | `dmesg.txt:587-594` + `APM_GRAPHICS_ISLAND` |
| No hay encendido por ACPI | **Verificado** (`_PS0/_PS3` sin regiones; sin `_PR0`) | `DSDT:6033-6042` |
| i386 soportado en Mesa y en `pvrsrvkm` | **Verificado** | `mesa/build.sh:26-33`, `AGENTS.md:33` |
| El driver DRM compila en i386 | **No verificado** (nunca en CI) | `.github/workflows/*` solo `ARCH=x86_64` |
| El driver requiere APIs de kernel > 6.12 | **Verificado** | `kzalloc_obj`, `pcim_iomap_region`, `drm_sched_job_init` 5 args |
| EGL fbdev no puede presentar hoy con `powervr_sgx` | **Verificado** (`bo_wrap` ausente → `-ENOTSUP`) | `sgx_frame.c:145-148`, `sgx_resource.c:249-283` |
| `simpledrm`+kmsro es la ruta prevista por el proyecto | **Verificado** | `mesa/patches/0004`, `docs/WINSYS.md`, `docs/porting/mesa.md:104-118` |
| Revisión exacta (`CORE_REVISION`) de la SGX545 de Clover Trail | **Desconocida** — hay que medirla | — |
| Rendimiento esperado | **Estimación**, sin medida | — |

---

## 10. Referencias

**Repo (clon local `$HOME/src/powervr_sgx`)**
- `README.md:6-8,14-24,28-40` · `AGENTS.md:33,42-44,61,131-143` · `CONTRIBUTING.md`
- `docs/porting/kernel.md:15-42,44-70,72-97,99-112,133-165` · `docs/porting/microkernel.md:6,44-59,63-100` · `docs/porting/mesa.md:104-134` · `docs/porting/README.md:14-20,37-65`
- `docs/UKERNEL.md:930-975,1005-1030` · `docs/UAPI.md:10,631` · `docs/WINSYS.md` · `docs/SRVINIT.md` · `docs/PERF.md:9,65`
- `drm/powervr_sgx/pvrsgx_regs.h:10-71` · `pvrsgx_core.c:57-124` · `pvrsgx_drv.c:242-291` · `pvrsgx_aux.c` · `pvrsgx_device.c:193-302,316-374` · `pvrsgx_fw.c:438-520` · `pvrsgx_pm.c` · `pvrsgx_hw.h`
- `drm/gma500/README.md`, `0001-…auxiliary.patch`, `0003-…graphics-island.patch`
- `mesa/build.sh:26-33` · `mesa/VERSION` (Mesa 26.2.5) · `mesa/patches/0004-kmsro-dril-sgx-render-only.patch` · `mesa/src/gallium/winsys/sgx/drm/sgx_frame.c:145-148` · `mesa/src/gallium/drivers/sgx/sgx_resource.c:249-283` · `mesa/src/egl/drivers/dri2/platform_fbdev.c:73-118,178-215,280-300`
- `ukernel/cores/sgx545.py` · `ukernel/README.md` · `.github/workflows/powervr-sgx-cedarview.yml:25,76`

**Nuestra tableta**
- `elitepad-dev/ref/logs4/friday-live/dmesg.txt:510-514,533,551,587-594` · `journal.txt:513-516`
- `elitepad-dev/ref/acpi/DSDT_INTEL__CLOVERVW_00000011.dsl:5874-5883,5933-5941,5942-6042,6238-6265`
- `elitepad-dev/linux-6.12.117/.config` · `elitepad-dev/patches/0001-0006` · `elitepad-dev/config-elitepad.sh` · `elitepad-dev/build-initramfs.sh:11-13`

**Kernel de referencia Clover Trail+ (Linux 3.4)**
- `src/k900/kernel/include/linux/intel_mid_pm.h:33,51-56` · `arch/x86/include/asm/intel-mid.h:34-39` · `arch/x86/include/asm/intel_scu_ipc.h:13,22`
- `arch/x86/platform/intel-mid/intel-mid.c:157-207` · `intel_soc_pmu.c:261-262,795-810,1338+,1842-1848`
- `arch/x86/platform/intel-mid/intel_soc_mdfld_clv_common.c:360-445` · `intel_soc_clv.h:31-34` · `intel_soc_pm_debug.c:365`
- `drivers/gpu/drm/gma500/mdfld_device.c:535` · `psb_drv.h:44-52`

**Web**
- `https://github.com/The1TrueJoe/powervr_sgx` (ramas `main`, `dev`)
- notebookcheck, “Imagination PowerVR SGX545”: “integrated graphics card in some of the Intel Atom Clover Trail SoCs (for example, the Atom Z2760). SGX545 is clocked at 533 MHz”
- `https://raw.githubusercontent.com/torvalds/linux/v7.3/arch/x86/Kconfig.cpu` (confirma `X86_32` y `MATOM` vivos en 7.3)

---

## 11. Qué queda en disco y qué se puede borrar

| Ruta | Tamaño | Acción |
|---|---|---|
| `$HOME/src/powervr_sgx` | 33 MB | **Conservar** (es la referencia del port; se puede re-clonar con un comando) |
| `$HOME/src/k900/kernel` | ya existía | **Conservar** (única copia del PM de Cloverview) |
| `$HOME/elitepad-dev/ref/acpi` | 0,5 MB | **Conservar** |
| Resto de `$HOME/src` (tar.gz y árboles de instaladores) | ~13 MB + | No lo ha tocado esta tarea |

No se ha instalado nada en el host, no se ha compilado nada, no se ha accedido a la tableta.
