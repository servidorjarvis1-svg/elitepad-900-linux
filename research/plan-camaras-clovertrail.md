# Plan: cámaras nativas HP ElitePad 900 G1 (Cloverview Z2760) → Frigate

Fecha: 2026-11-13 · Solo investigación (no se ha tocado la tableta).
Leyenda: **[V]** verificado con evidencia local · **[I]** inferencia razonada · **[P]** pendiente (requiere tableta/Windows)

---

## 0. Resumen ejecutivo (30 segundos)

| Pregunta | Respuesta |
|---|---|
| ISP de Cloverview | **ISP2300 / CSS 1.5**, PCI `8086:08d0` en `00:03.0` **[V]** |
| ¿Sirve el atomisp de mainline (staging)? | **No.** Mainline solo soporta ISP2400/ISP2401 (BYT/CHT/MRFLD). No tiene el ID `0x08d0` **[V]** |
| Entonces… | **Portar atomisp2 "css15"** (base kernel Android 3.10 de android-x86, o 3.4 del K900) a 6.12 como driver out-of-tree. **200–390 h** de trabajo, riesgo alto **[I]** |
| Firmware | `shisp_css15.bin` (formato "bi" de Silicon Hive: cabecera + blobs SP/ISP). **No está en linux-firmware** **[V]** → hay que extraerlo (ROM K900 / DriverStore Windows) **[P]** |
| Sensores | OV8830 (CAM0, 4 lanes, RAW10 BGGR) y OV2720 (CAM1, 1 lane, RAW10 BGGR). Sin driver mainline para OV8830; `atomisp-ov2722` mainline solo casa ACPI `INT33FB` **[V]** |
| Encendido | VPROG1 2.8 V (PMIC MSIC reg `0xD6`=`0xF6`) → reset GPIO 81 alto → MCLK 19.2 MHz (`IPCMSG_OSC_CLK`, clk 1) → 2 ms **[V]** |
| Alternative barata | Webcam USB UVC en el dock (5 puertos, 2 ocupados): **0 h de software** **[V]** |
| Recomendación | **Corto plazo: UVC → Frigate ya.** Cámara nativa como proyecto por fases con puertas go/no-go |

---

## 1. Hechos verificados (evidencia)

| # | Hecho | Evidencia |
|---|---|---|
| 1 | El ISP existe y está enumerado: `[8086:08d0]` class `0x048000`, BAR0 4 MB @ `0x90000000` | `logs/w/arranque-002/dmesg.txt:241` y `:299` |
| 2 | `ISP0` es PCI `00:03.0` (`_ADR 0x00030000`), **sin `_HID`**, con `_DEP` en `\_SB.PEP` y `_PR3` → power resource `\_SB.PEP.ID3C` | `ref/acpi/DSDT…dsl:6208-6222` |
| 3 | `ID3C._OFF` llama a `ISVR()` (reset de estado del sensor hub), `_ON` vacío | `DSDT…dsl:6270-6285`, `2239-2256` |
| 4 | CAM0 = `INTCF2A`, `_DDN "OmniVision OV8830"`, I2C4 @ `0x10` + `0x0C` + `0x50`, GPIO `GPO1` pin `0x51`=81 | `DSDT…dsl:4234-4296` |
| 5 | CAM1 = `INTCF0B`, `_DDN "OmniVision OV2720"`, I2C4 @ `0x36`, GPIO `0x50`=80 y `0x52`=82 | `DSDT…dsl:4378-4433` |
| 6 | STRB = `INTCF1C`, `_DDN "LED flash Lm3554"`, I2C4 @ `0x53`, GPIO 65/63/79/32/78 | `DSDT…dsl:4525-4578` |
| 7 | **CAM0/CAM1/STRB no tienen `_PS0`/`_PS3`**: el AML *no* enciende los rails → la secuencia de energía es responsabilidad del driver | `DSDT…dsl:4234-4433` (ausencia) |
| 8 | SCU IPC = `INT33B5` @ `0xFF11C000`, y `IPC.MREG` = `INTCFFA` "MSIC Register Access" (registros del PMIC) | `DSDT…dsl:5095-5152` |
| 9 | Cloverview usa ISP2300: el driver tiene cláusula explícita "Medfield and Clovertrail" → `ATOMISP_HW_REVISION_ISP2300` | `src/k900/kernel/drivers/media/video/atomisp2/atomisp_driver/atomisp_v4l2.c:1105-1112` |
| 10 | Tabla PCI del driver: Clovertrail = `0x08D0` (solo compilada con `CONFIG_ISP2300`) | `…/atomisp_v4l2.c:1280-1281` |
| 11 | CSS 1.5 se compila del mismo árbol con `-DCONFIG_ISP2300 -DCONFIG_VIDEO_ATOMISP_CSS15` | `…/css2300_build/Makefile:1-3` |
| 12 | En CTP/ISP2300 **solo 1 stream** (1 cámara a la vez) | `…/atomisp_internal.h:246-250` |
| 13 | Firmware para ISP2300 = `shisp_css15.bin` | `…/atomisp_v4l2.c:937-965` |
| 14 | Formato del firmware: `sh_css_fw_bi_file_h` + N `sh_css_fw_info`; el blob 1 es el programa del SP (DSP) | `…/css/sh_css_firmware.c:47-80` |
| 15 | linux-firmware **solo** trae `shisp_2400b0_v21.bin` y `shisp_2401a0_v21.bin` (no css15) | `git.kernel.org/…/linux-firmware/WHENCE` (consultado) |
| 16 | Mainline solo tiene `0x0f38` (BYT), `0x1178/79/7a` (MRFLD), `0x1478` (ANN), `0x22b8` (CHT) | `linux-6.12.117/drivers/staging/media/atomisp/pci/atomisp_internal.h:51-59` |
| 17 | Mainline: `atomisp-ov2722` casa ACPI `INT33FB` (Bay Trail), no `INTCF0B` | `…/atomisp/i2c/atomisp-ov2722.c:1007-1010` |
| 18 | Secuencia power-up del sensor: `power_ctrl` → `gpio_ctrl` (suelta reset) → `flisclk` (MCLK) → `msleep(2)` → I2C | `src/k900/kernel/drivers/media/video/ov8830.c:740-770` |
| 19 | CAM0: 4 lanes, RAW10, BGGR, MCLK 19200 kHz (`OSC_CLK_CAM0`) | `…/device_libs/platform_ov8830.c:61,120-126` |
| 20 | CAM1: 1 lane, RAW10, BGGR, MCLK 19200 kHz (`OSC_CLK_CAM1`) | `…/device_libs/platform_ov2722.c:100-101,229-236` |
| 21 | `ov8830.c` sirve OV8830 y OV8835 (chip-id) | `…/ov8830.c:1576-1580` |
| 22 | `ov2722.c` contempla **los dos IDs**: `OV2720_ID 0x2720` y `OV2722_ID 0x2722` | `…/ov2722.h:71-72`, `ov2722.c:955-961` |
| 23 | PMIC: `MSIC_VPROG1_CTRL=0xD6` (ON `0xF6` = 2.8 V auto / OFF `0x24`); `VPROG2=0xD7` (`0x36`/`0x24`) | `src/k900/kernel/drivers/platform/x86/intel_scu_ipcutil.c:327-351` |
| 24 | MCLK por IPC `IPCMSG_OSC_CLK (0xE6)`: wbuf[0]=clk (CAM0=1, CAM1=2), wbuf[1]=`0x03｜div<<2` on / `0x00` off | `…/intel_scu_ipcutil.c:245-277`, `arch/x86/include/asm/intel_scu_ipc.h:23` |
| 25 | Kernel 6.12 ya expone `intel_scu_ipc_dev_iowrite8()` (MSIC, sirve para VPROG) pero **no** un comando genérico → falta envoltorio para `0xE6` | `linux-6.12.117/drivers/platform/x86/intel_scu_ipc.c:366,450,489` |
| 26 | Driver css15 (3.4 y 3.10) usa la API **videobuf** (no vb2) → hay que reescribir el núcleo de captura | `…/atomisp2/atomisp_driver/atomisp_fops.c:67-283` |
| 27 | Dock con hub USB de 5 puertos; ocupados LAN9514 + teclado → quedan libres | `logs/w/arranque-002/dmesg.txt:470,477,486` |
| 28 | El kernel actual no compila atomisp (`# CONFIG_INTEL_ATOMISP2_PM is not set`, sin `CONFIG_INTEL_ATOMISP`) | `linux-6.12.117/.config:4318` |

---

## 2. Pregunta 1 — ISP/CSS, ID y coste de cada opción

**Veredicto: ISP2300, CSS 1.5, `8086:08d0`. El atomisp de mainline NO puede soportarlo. Hay que portar atomisp2-css15.**

Por qué mainline no sirve:
- El atomisp upstream usa firmware **`shisp_2400b0_v21.bin` (CSS `irci_stable_candrpv_0415_20150423_1753`)** y **`shisp_2401a0_v21.bin` (CSS `irci_master_2015…`)**. El CSS 1.5 de Cloverview es una generación anterior (2012-2013, "hive_isp_css"), con receptor propio (`sh_css_rx.c`) y **VAMEM tipo 1** en lugar de tipo 2 — tablas con tamaños y formato distintos (`ia_css_gc_types.h:42` y `ia_css_xnr_types.h:50` en mainline lo documentan).
- Upstream **eliminó deliberadamente** los restos de ISP2300 ("the upstreamed atomisp driver now supports only ISP2400 and ISP2401", commit `5a1b2725558f`). Re-añadirlo dentro del árbol reestructurado de upstream es *más* trabajo que portar el driver css15 completo.

Comparativa de coste **[I]** (estimación de ingeniero, no medida):

| Opción | Trabajo | Horas | Riesgo | Veredicto |
|---|---|---|---|---|
| A. Portar `atomisp2/atomisp_driver_css15` (base 3.10 android-x86) a 6.12 | adaptar 24 k LOC de driver + 42 k LOC de CSS; videobuf→vb2, media_entity, ACPI/GPIO/regulador, PM | **200–390 h** | Alto (40–60 % de éxito) | **Única vía real** |
| B. Re-añadir CSS1.5 al atomisp de mainline | revertir limpiezas + injertar generación CSS antigua | > 400 h | Muy alto | Descartada |
| C. Esperar soporte upstream | — | ∞ | — | No existe ni se espera |
| D. Webcam USB UVC | nada | **0 h** | Nulo | Para Frigate *ya* |

Base recomendada para el port (mejor que el K900 3.4):
`android.googlesource.com/kernel/x86` rama `android-x86-grant-3.10-marshmallow-mr1-wear-release`,
ruta `drivers/external_drivers/camera/drivers/media/pci/atomisp2/` — tiene **`atomisp_driver_css15/` separado** de `atomisp_driver/` (css20) y `css2300/` + `css2300_build/`, y su tabla PCI incluye `{PCI_DEVICE(PCI_VENDOR_ID_INTEL, 0x08D0)}`. Sigue usando videobuf, pero 3.10 está más cerca de 6.12 que 3.4 en el resto de APIs **[V, comprobado descargando `atomisp_driver_css15/atomisp_v4l2.c`]**.

Trabajo concreto del port (checklist):
1. `atomisp_v4l2.c`: añadir `0x08d0`, forzar `ISP2300`/`CSS_VERSION_15`, quitar `pci_get_bus_and_slot`, `setup_timer`→`timer_setup`.
2. `atomisp_fops.c` + `atomisp_ioctl.c`: **videobuf → vb2** (el grueso: ~1.500-2.000 LOC a reescribir).
3. `media_entity_init`→`media_entity_pads_init`, `media_entity_create_link`→`media_create_pad_link`, ops de entidad.
4. Sustituir `struct camera_sensor_platform_data` + `platform_camera.c` por: GPIOs vía `gpiod_get`/ACPI `GpioIo` (ya descritos en `_CRS`), regulador VPROG1 vía SCU IPC, MCLK vía nuevo comando `0xE6`.
5. CSS: correcciones de compilación (dma_alloc_coherent, `get_user_pages`, `ktime`, `bool`), mantener el resto intacto.
6. `sh_css_load_firmware` → `request_firmware("shisp_css15.bin")` desde `/lib/firmware`.

---

## 3. Pregunta 2 — Firmware del ISP

- Fichero: **`shisp_css15.bin`** (mismo nombre para Medfield y Cloverview/Clover Trail+; el CSS2300 es el mismo silicio, por eso el BSP comparte blob) **[V, `atomisp_v4l2.c:961`]**
- Formato: binario propietario "bi" de Silicon Hive → `struct sh_css_fw_bi_file_h` (tamaño + nº de binarios) seguido de N `sh_css_fw_info`; **el binario #1 es el programa del SP** (procesador escalar del ISP), el resto son blobs de pipeline para el ISP. Incluye cadenas de versión que el driver valida (`sh_css_check_firmware_version`) **[V, `sh_css_firmware.c:47-80`]**
- **No se puede recompilar**: el código del SP se ensambla con el toolchain propietario de Intel/Silicon Hive. Es un blob obligatorio **[I, muy alto]**
- **No está en linux-firmware** (solo `shisp_2400b0_v21.bin` y `shisp_2401a0_v21.bin`) **[V]**

Vías para conseguirlo **[P]** (por orden de probabilidad):
1. **DriverStore de la propia tableta (Windows)**: buscar en la carpeta del driver de cámara/ISP (`buscarcfg`/`DriverStore/FileRepository/*camera*`, `*isp*`) ficheros `*.bin` de ~1–2 MB; nombres típicos `shisp_css15.bin`, `isp_css15.bin`, `shisp*.bin`. **Esta es la mejor fuente: es el blob que corresponde exactamente a este ISP2300.**
2. ROM stock de Lenovo K900 (Android 4.2): `system/etc/firmware/shisp_css15.bin`.
3. ROMs Medfield (Motorola RAZR i) — mismo ISP2300.
4. Driver para Windows descargable de HP (SoftPaq con "Camera Sensor OV8830 / Flash LM3554", p.ej. sp66596 y familiares).

Riesgo asociado: si el blob no aparece, el proyecto muere en la fase 2 (no hay alternativa: sin SP no hay datapath).

---

## 4. Pregunta 3 — Sensores y secuencia de encendido

### 4.1 Disponibilidad de drivers

| Sensor | Mainline | En el árbol K900 | Notas |
|---|---|---|---|
| **OV8830** (CAM0, 8 MP) | **No existe** | `drivers/media/video/ov8830.c` (1.958 LOC, init en C, sin ficheros msr binarios) + `ov8830.h` (tablas de modo) | `ov8830.c` cubre OV8830 y OV8835 por chip-id; modos 3280x2464, 3280x1852, 1080p, 720p, `cont_cap_720P/1080P` **[V]** |
| **OV2720** (CAM1, 1080p) | Parcial: `atomisp-ov2722.c` existe pero casa `INT33FB` y usa `atomisp_gmin_platform` (Bay Trail) | `drivers/media/video/ov2722.c` (1.373 LOC) — **contempla `OV2720_ID 0x2720` y `OV2722_ID 0x2722`** | Mismo HID `INTCF0B` que OV2722 en K900 ⇒ hay que detectar por chip-id **[V]** |
| Flash LM3554 (STRB) | `drivers/media/i2c/lm3560.c` (familia, no idéntico) | `drivers/media/video/lm3554.c` | No necesario para Frigate |

Implicación práctica: el sensor **no** es el problema; el problema es el ISP. `ov8830.c` es autónomo (tablas en C), así que se puede adaptar a subdev moderno sin dependencias ocultas.

### 4.2 Secuencia de encendido (la que hay que implementar)

De `ov8830.c:740-770` + `platform_ov8830.c` + DSDT:

```
ON:
 1. VPROG1 = 2.8 V   → SCU IPC PCNTRL write MSIC 0xD6 = 0xF6
 2. reset GPIO 81 = 0, msleep(20), = 1        (CAM0; en CAM1: PWDN 80 = 0 y RESET 82 = 0→50 ms→1)
 3. MCLK 19.2 MHz    → SCU IPC 0xE6, wbuf = {1, 0x03}   (clk 1 = CAM0; clk 2 = CAM1)
 4. msleep(2)        (mín. 8192 ciclos de reloj antes del primer I2C)
 5. I2C: leer chip-id (OV8830: 0x300A/0x300B) y cargar tabla de modo

OFF (orden inverso, el del driver):
 1. MCLK off   → 0xE6, {clk, 0x00}
 2. reset = 0  (CAM0) / PWDN = 0 (CAM1)
 3. VPROG1 off → 0xD6 = 0x24
```

Detalles útiles:
- I2C del _CRS a **400 kHz** (`0x00061A80`) sobre `\_SB.I2C4`; el parche local ya sube el reloj del controlador para UID 4 **[V, `patches/0005-i2c-designware-cloverview-int33b1.patch`]**.
- CAM0 expone además `0x0C` (VCM DRV201, usado por `drv201_t_focus_abs` en `ov8830.c`) y `0x50` (EEPROM/calibración) **[V]**. No son necesarios para vídeo.
- Los rails **no** los toca el AML (`_PS0` no existe en CAM0/1) ⇒ sin driver no hay cámara, y el "apagado real" se puede hacer desde el driver/usuario sin pelearse con ACPI.
- ISP: `_PR3`→`PEP.ID3C` significa que el ISP está detrás de un power resource ACPI. En la fase 2 hay que comprobar que el *runtime PM* de PCI lo pone en D0 antes de tocar MMIO **[I]**.

---

## 5. Pregunta 4 — Alternativa barata (solo para dejar anotado)

| | Cámara nativa (ISP2300) | Webcam USB UVC en el dock |
|---|---|---|
| Software | 200–390 h de port | **0 h** (uvcvideo ya en el kernel) |
| Calidad/encaje | 8 MP, integrada, sin cables | 1080p típico, cable, ocupa puerto |
| CPU | ISP hace el pipeline (bien) | MJPEG por USB (bien) |
| Frigate | vía go2rtc tras el port | **directo hoy** (`rtsp` o `exec:ffmpeg -f v4l2`) |
| Puertos libres | — | **3 de 5** en el hub del dock (LAN9514 + teclado ya conectados) **[V]** |
| Riesgo | alto (firmware, vb2, CSS) | nulo |
| Recomendación | proyecto por fases | **poner ya para tener la cámara en Frigate mientras se porta** |

---

## 6. Pregunta 5 — Ruta a Frigate y botón "apagar cámara de verdad"

### 6.1 Cadena de vídeo

```
OV8830 → MIPI CSI-2 (4 lanes, RAW10) → ISP2300 (CSS1.5) → /dev/video0 (NV12)
        → ffmpeg/libx264 (ultrafast, zerolatency) → RTSP :8554 → Frigate (servidor)
```

go2rtc en la tableta:
```yaml
streams:
  elitepad: >
    exec:ffmpeg -hide_banner -loglevel warning
    -f v4l2 -input_format nv12 -video_size 640x480 -framerate 10 -i /dev/video0
    -c:v libx264 -preset ultrafast -tune zerolatency -profile:v baseline -g 20 -b:v 800k
    -f rtsp {output}
```
Frigate:
```yaml
cameras:
  elitepad_cam:
    ffmpeg:
      inputs:
        - path: rtsp://<ip-tableta>:8554/elitepad
          roles: [detect, record]
    detect: { width: 640, height: 480, fps: 5 }
```

Presupuesto de CPU en Z2760 (2×1.8 GHz Bonnell, sin aceleración HW de vídeo en mainline **[V: no hay driver VED/VXD en 6.12]**) **[I]**:
- 640×480 @ 5–10 fps x264 ultrafast: **cómodo** (objetivo inicial).
- 1280×720 @ 5 fps: justo; medir con `ffmpeg -benchmark`.
- 1080p: **no viable**.
- Medición real: `ffmpeg -f v4l2 … -c:v libx264 … -f null - -benchmark` y `top`. Puerta: si `ffmpeg` > 60 % de un core, bajar a 5 fps.

Nota: el ISP CSS1.5 también puede sacar JPEG/MJPEG, pero **no** lo usaremos: la ruta NV12 + x264 es la predecible.

### 6.2 Botón "apagar cámara" en Home Assistant (corte real)

Tres capas, en este orden (importante: soltar DMA antes de cortar rails):

```
OFF:
 1. HA: mqtt.publish  frigate/elitepad_cam/enabled/set  "OFF"      # Frigate deja de consumir/grabar
 2. HA: shell_command → ssh friday@elitepad 'cam-off.sh'
      cam-off.sh:
        systemctl stop go2rtc-cam            # ffmpeg cierra /dev/video0
        gpioset -c gpiochip0 81=0            # reset del OV8830
        scu-osc-clk cam0 off                 # 0xE6, {1,0x00}  ← helper nuevo (≈30 líneas)
        scu-msic-write 0xD6 0x24             # VPROG1 off (ya hay ioctl PCNTRL)
        rmmod atomisp_css15 (o unbind PCI)   # opcional, deja el ISP en D3

ON (inverso, o simplemente dejar que el driver lo haga):
        scu-msic-write 0xD6 0xF6 → reset 0/1 (20 ms) → scu-osc-clk cam0 on → 2 ms
        systemctl start go2rtc-cam
        mqtt.publish frigate/elitepad_cam/enabled/set "ON"
```

Coste del botón una vez que la cámara funcione: **2–4 h** (script + 2 plantillas HA + helper IPC) **[I]**.

Riesgo abierto **[P]**: no sabemos si `VPROG1` alimenta algo más (flash LM3554, táctil). Verificar con esquemático o midiendo: si está compartido, el "apagado real" se queda en reset+MCLK off (consumo residual µA, no cero).

---

## 7. Plan por fases (con puertas go/no-go)

| Fase | Contenido | Horas **[I]** | Puerta de salida |
|---|---|---|---|
| **0** | Conseguir `shisp_css15.bin` (DriverStore Windows / ROM K900) y confirmar tamaño+strings de versión. Descargar el árbol 3.10 de android-x86 (`--depth 1`, solo `external_drivers/camera`). | 4–8 | **G1: blob en mano y con la cadena de versión esperada** |
| **0.5** | Experimento barato en tableta: módulo de 30 líneas o `devmem` sobre BAR0 → leer 8–16 dwords del ISP y del SP. Confirma que el bloque responde en D0 (power/clock). | 2–4 | **G2: lecturas coherentes (no 0xFFFFFFFF)** |
| **1** | Helpers kernel: comando `IPCMSG_OSC_CLK (0xE6)` en `intel_scu_ipc` (≈30 líneas) + `scu-msic-write` en userspace para VPROG1. Probar MCLK y rail a mano. | 4–8 | G3: MCLK conmuta, VPROG1 da 2.8 V medidos |
| **2** | Esqueleto del driver out-of-tree: PCI probe `0x08d0`, ioremap, IRQ/MSI, `hmm` (MMU) y `request_firmware` + `sh_css_load_firmware`. | 40–80 | **G4: el SP arranca (init OK sin timeout)** |
| **3** | Núcleo de captura: videobuf→vb2, nodo `/dev/video0`, TPG (test pattern del ISP). | 60–120 | **G5: frames de test pattern con `v4l2-ctl --stream-mmap`** |
| **4** | Sensor OV8830: subdev moderno, GPIO/MCLK/VPROG, CSI 4 lanes RAW10, tabla 720p. | 60–120 | **G6: primer frame real** |
| **5** | Estabilización, fps, x264, go2rtc, Frigate, botón HA. | 30–60 | **G7: cámara en Frigate + off/on por HA** |
| **6** (opcional) | CAM1 OV2720 (1 lane) y flash LM3554. | 20–40 | — |
| | **Total** | **200–390 h** | |

Ritmo realista a 8–10 h/semana: **6–12 meses** para G6. G5 (test pattern) ya valida el 80 % del riesgo técnico y llega hacia la mitad.

**Regla de corte**: si G1 falla → no empezar. Si G2 falla (ISP no responde en MMIO) → investigar PEP/PSU o abandonar. Si G4 falla tras 120 h → abandonar y quedarse con UVC.

---

## 8. Riesgos

| # | Riesgo | Impacto | Mitigación |
|---|---|---|---|
| 1 | No aparece `shisp_css15.bin` | **Bloqueante total** | DriverStore Windows primero; ROM K900 después. Hacerlo antes de escribir código |
| 2 | videobuf→vb2 en un driver de 24 k LOC | Alto (es el grueso del trabajo) | Portar solo la ruta de captura usada (mmap, 1 cola), no todo el legado |
| 3 | El ISP no sale de D3 (PEP `ID3C`) | Bloqueante | Fase 0.5 lo detecta con 4 h de coste |
| 4 | Firmware del K900 (CLV+) ≠ CLV | Medio | El CSS2300 es el mismo; si hay mismatch, usar el blob del DriverStore de la ElitePad |
| 5 | `VPROG1` compartido con otros periféricos | Medio | No cortar el rail por defecto; usar reset+MCLK off |
| 6 | Solo 1 stream en ISP2300 | Bajo | Frigate usa una cámara por dispositivo; la frontal es un "extra" |
| 7 | Mantenimiento 6.12→7.x | Medio | Driver out-of-tree/DKMS con `compat.h` |
| 8 | Sin docs del ISP2300 | Alto | La única referencia es el BSP de Intel (ya clonado) + prueba y error |
| 9 | Rendimiento de encode en Atom | Bajo | 640×480@5–10 fps y medir |

---

## 9. Pendiente / requiere tableta o Windows (no ejecutado aquí)

1. **[P]** Buscar `shisp_css15.bin` en el DriverStore (crítico).
2. **[P]** Confirmar en la tableta que existe `/dev/i2c-4` y que los clientes son `i2c-INTCF2A:00`, `i2c-INTCF0B:00`, `i2c-INTCF1C:00`; leer 0xD6 del MSIC antes de escribir.
3. **[P]** Confirmar que el GPIO 81 es alcanzable por gpiolib (`gpioinfo | grep -i 81`, chip de `INT33B2`/GPO1) y con qué número global.
4. **[P]** Verificar el reparto de `VPROG1` (esquemático ElitePad 900) antes de usar el corte de rail.
5. **[P]** Medir el consumo/CPU real de x264 a 640×480 y 720p.
6. **[P]** Confirmar en el DriverStore qué IDs de hardware usa el driver de cámara Windows (para validar la hipótesis del ISP2300 y el formato del blob).

---

## 10. Anexo — rutas de referencia

- DSDT descompilado: `ref/acpi/DSDT_INTEL__CLOVERVW_00000011.dsl`
- Kernel Android Clover Trail+ (3.4): `src/k900/kernel`
  - driver: `drivers/media/video/atomisp2/atomisp_driver/`
  - CSS 1.5: `drivers/media/video/atomisp2/css/` + `css2300_build/`
  - sensores: `drivers/media/video/{ov8830,ov2722,lm3554}.c`
  - plataforma: `arch/x86/platform/intel-mid/device_libs/platform_{ov8830,ov2722,camera}.c`
  - IPC/PMIC: `drivers/platform/x86/intel_scu_ipcutil.c`
- Kernel objetivo: `elitepad-dev/linux-6.12.117` (mainline atomisp en `drivers/staging/media/atomisp/`)
- Logs de arranque: `logs/w/arranque-002/dmesg.txt`
- Base recomendada del port: `android.googlesource.com/kernel/x86` → rama `android-x86-grant-3.10-marshmallow-mr1-wear-release`, `drivers/external_drivers/camera/drivers/media/pci/atomisp2/atomisp_driver_css15/`
