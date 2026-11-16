# Audio en Clover Trail (ElitePad 900): RT5640 + DSP SST

Micro y altavoces son dos piezas distintas que hay que poner en marcha en
orden: el **códec RT5640** (por I2C y SSP) y el **DSP SST** de Intel (firmware
propio, cargado por MMIO). Sin el primero no hay sonido aunque el DSP arranque;
sin el segundo no hay procesado de voz, pero el códec puede funcionar en
`bypass` por I2S.

## Inventario

| Pieza | Cómo se anuncia | Detalle |
|---|---|---|
| Códec Realtek RT5640 | ACPI `INTCCFFD` uid 2 (`AUD1`), I2C5 `0x1C` | ID `0x10EC:0x6231` rev 3; driver Windows `rtii2sac.inf` |
| DSP SST | ACPI `INTC33B3` uid 2 (`AUD1`) | driver Windows `isstrtc.sys` + firmware `realtek_fw_sst.bin` |
| Enlace al códec | SSP3 | `0xFFA23000`; en Clover Trail también `CLKCTL`/`CSR2` del SHIM |
| Gestor de energía | `clvpep.sys` (PEP de Windows) | enciende islas y relojes que Linux no toca |

Las dos rutas del DSDT (`AUD0`/`AUD1`) se seleccionan con el método `FABX`:
si devuelve 1, el dispositivo que vale es el uid 2.

## Mapa físico (extraído de los literales de `isstrtc.sys`)

Sacado con la receta de SKILL.md §"Sin datasheet" (literales de 32 bits del
`.sys` + `_CRS` del DSDT) y confirmado leyendo los registros por `devmem`: el
SHIM y el buzón devuelven valores coherentes.

| Bloque | Base | Tamaño |
|---|---|---|
| SHIM (registros de control) | `0xFFAE8000` | 0x88 |
| IRAM del DSP | `0xFFB00000` | 512 KB |
| DRAM del DSP | `0xFFB80000` | 512 KB |
| Buzón (mailbox) | `0xFFFF1000` | 8 KB |
| Búfer SRAM | `0xFFFC0000` | 64 KB |
| SSP3 (I2S al códec) | `0xFFA23000` | — |
| DMA del audio (el que usan Windows y Android: **DMA1**) | `0xFFAF0000` | — (DMA0 en `0xFFAF8000`) |
| PMU del SoC | `0xFF11D000` | — |
| SCU (IPC) | `0xFF11C000` | `CMDR`+0, `STS`+4 |

Layout del PMU (`mrst_pmu_reg`): `sts` +0x00, `cmd` +0x04, `ssc` +0x20 (se
consulta) , `sss` +0x30 (se fija). Las islas de alimentación (LSS) que
importan aquí: 8 audio engine, 9 audio DMA, 10-13 SRAM del audio.

## Registros del SHIM (`0xFFAE8000`)

| Offset | Registro | Notas |
|---|---|---|
| `0x00` | `SST_CSR` | `mfld_strb:1`, `sst_reset:1`, `clk_sel:3`, `sst_clk:2`, `bypass:3`, `run_stall:1`, `rsvd:2`, `strb_cntr_rst:1` |
| `0x18` | IRAM/DRAM info | 0 en esta máquina |
| `0x78` | `SST_CLKCTL` | salidas de reloj de SSP; el init de CLV pone `0x7 << 16` |
| `0x80` | `SST_CSR2` | bits 1 y 2: desactivar «DMA finish» de SSP0/1 y SSP3 |

Secuencia que hace la referencia Android (equivalente a `sst.c` 780-812,
`sst_dsp.c` 47-90 y 1353-1430 del kernel de K900, `sound/soc/intel/sst/`):

1. `CSR |= 0x30000` (reloj de arranque del LPE y tamaño de RAM) y
   `CSR &= ~0xC` (clk_sel = OSC para SSP0/1).
2. `CLKCTL |= 0x7 << 16` en Cloverview.
3. `CSR2 |= BIT(1) | BIT(2)`.
4. Reset: `CSR |= 0x382` y `run_stall = 1`; se descarga el firmware parseando los
   bloques del módulo (`SST_IRAM`/`SST_DRAM`) **con el DMAC, no con la CPU**;
   después `bypass = 0`, `mfld_strb = 1`, `run_stall = 0`, `sst_reset = 0`.
5. Se espera el ACK de `FW_DWNL_ID` en el buzón.

**Corrección importante**: la CPU no puede escribir la IRAM/DRAM del DSP (ver
"El DMA del LPE" abajo). Copiar el firmware con `memcpy_toio` como hace el
driver de Merrifield no funciona en Cloverview: hay que hacerlo por DMA, que es
lo que hacen tanto el kernel Android (`use_dma = 1`, `use_lli = 1`) como el
driver de Windows (reserva un búfer contiguo y lanza el canal).

## El DMA del LPE: receta verificada

El controlador es un DesignWare **AHB DMAC** (`COMP_TYPE` `0x44570140` en
`+0x3FC`) con 4 canales y 0x58 bytes por canal. Registros por canal: `SAR`
+0x00, `DAR` +0x08, `LLP` +0x10, `CTL_LO` +0x18, `CTL_HI` +0x1C, `CFG_LO`
+0x40, `CFG_HI` +0x44. Globales: `DmaCfgReg` +0x398 (bit 0 = enable),
`ChEnReg` +0x3A0, `RawTfr` +0x2C0, `ClearTfr` +0x338.

Transferencia memoria→memoria de 32 bits que **sí funciona** (verificada
copiando 4 palabras dentro de la SRAM y leyéndolas de vuelta):

```
DmaCfgReg = 1
ClearTfr  = 0xFFFFFFFF
SAR = origen ; DAR = destino ; LLP = 0
CTL_LO = 0xD825   # int_en=1, 32b src/dst, incremento, burst 16, tt_fc=0
CTL_HI = nwords   # block transfer size
CFG_LO = 0        # memoria→memoria: sin handshake por software
CFG_HI = 0
ChEnReg = 0x0101  # bit0 = canal 0 habilitado + bit8 = write-enable
```

Dos trampas que costaron varias vueltas:

- **`CFG_LO = 0x5` es handshake por software, solo vale para periférico.** En
  memoria→memoria con `0x5` el canal no arranca y se concluye (mal) que el DMAC
  no tiene reloj. Si dudas del controlador, prueba DDR→DDR con una página
  `dma_alloc_coherent` antes de tocar el destino: separa el fallo del DMAC del
  fallo del destino.

- **Escribir solo `0x01` en `ChEnReg` no arranca nada**: hace falta el bit de
  *write enable* (`bit 8 + canal`). Es el fallo silencioso típico: el registro
  se lee 0, el canal nunca se marca ocupado y parece que "no hace nada".
- **Con lista enlazada (`LLP` apuntando a un descriptor) no transfiere** en esta
  revisión del bloque, aunque el driver Android la use. Empieza por la
  transferencia directa de un bloque; solo si necesitas fragmentos, investiga
  el LLI aparte.

Diagnóstico: mientras el canal siga marcado en `ChEnReg` la transferencia **no
ha terminado**. En este DMAC un esclavo que no responde deja el canal colgado
pero **no bloquea el bus**, así que se puede seguir leyendo por SSH: es un
timeout, no un cuelgue. Si el canal no se libera, deshabilítalo escribiendo el
bit de write-enable (`ChEnReg = 0x0100 | canal << 8`) antes de seguir.

## Estado verificado en la tableta (y dónde se atasca)

Verificado leyendo registros, sin cargar nada:

- `PM_SSS` = 0 en todas las islas y `CSR` = `0x04800401` (marshal strobe a 1,
  `sst_reset` a 0, `run_stall` a 1): DSP sin arrancar, en el estado del que se
  parte.
- El buzón (`0xFFFF1000`) se lee y devuelve un valor, y el SHIM también: las
  direcciones son buenas.
- `DmaCfgReg` acepta el enable y `ChEnReg` responde: el DMAC está relojado y
  operativo.
- Copia **SRAM → SRAM** verificada (datos correctos en destino).
- **El driver de Windows solo escribe `CSR = 0x04830882`** (`sst_reset` +
  `bypass` + `strb_cntr_rst` + `0x30000`); no toca `CLKCTL`, `CSR2` ni `PIMR`
  (este último se lee 0 y no se deja escribir). Copiar su secuencia exacta es
  más fiable que mezclar la de Android con la de Merrifield.

Atasco: **cualquier transferencia DMA a la IRAM (`0xFFB00000`) o a la DRAM
(`0xFFB80000`) deja el canal ocupado y no llega ni un byte**, con cualquier
valor de `CSR` probado (`0x04830882`, `0x04830880`, `0x04800082`, `0x04800401`,
`0x04830082`) y cualquier tamaño (4, 16 y 64 palabras). El mapa y el DMAC son
correctos (SRAM→SRAM copia), así que lo que falta es el **encendido de esas
RAM**, no la configuración del canal.

Lo siguiente a mirar, por orden, sin volver a probar el mismo registro:

1. La isla de RAM de audio: en Cloverview existe `PMU_AUDIO_RAM_LSS_25`
   (`intel_soc_clv.h`), aparte de las islas 8 (audio engine) y 9 (audio DMA).
2. La secuencia que aplica `clvpep.sys` (PEP de Windows): es quien enciende esas
   islas cuando el driver de audio hace `_PS0`. Volcado del PEP en `ref/win-pep/`.
3. El bloque `0xFFAE0000` (el `_CRS` de `INTC33B3` lo declara, 0x4000): no se ha
   mirado y puede llevar los relojes del LPE.
4. Diferenciar reset y alimentación: si el registro de control acepta escritura
   y la RAM no, el problema es corriente, no reloj.

Nada de esto se ha validado todavía: no dar por bueno un método de encendido
hasta ver el canal liberarse y `devmem` devolviendo lo escrito.

## Dónde está el atasco ahora (medido)

Lo que queda por encender es la **RAM del DSP**, no el bus ni el DMAC. Descartado
o medido, para no repetirlo:

- **La GSI/IRQ del bloque no es el problema aquí** (este chip no la usa para
  esto). El atlas del audio está en `references/audio-sst-cloverview.md` y en la
  sección de DMA.
- **`0xFFAE0000` (los 0x4000 que declara el `_CRS` de `INTC33B3`) no se toca con
  `devmem`**: una lectura a `+0x8` **cuelga la CPU para siempre** (segunda vez
  comprobado, hay que mantener el botón de encendido). Si hay que mirarlo, va
  dentro de un `debugfs` del driver con lista blanca.
- **PMU: `pm_cmd = 0x2201` deja `pm_sts = 0x100` (BUSY) para siempre.** El PMU
  acepta la escritura y no procesa la orden.
- **SCU: la orden `IPCMSG_OSC_CLK = 0xE6` tampoco completa**, aunque el mismo
  buzón sí ejecuta el cold reset (`0xF1`). O sea que el reloj de audio vía SCU no
  se consigue igual que en Clover Trail+; no es la misma revisión de firmware
  del SCU.
- **`CSR = 0x04830882` (la del driver de Windows) y `CLKCTL |= 0x70000` no
  encienden nada por sí solos.**

Siguiente candidato, sin volver a probar lo anterior: la secuencia exacta con la
que `isstrtc.sys` toca `IRAM`/`DRAM` (`[obj+0x494]`/`[obj+0x498]`) y el beacon de
vida del DSP **antes** de bajar el firmware, sacada con REA y verificada contra
hardware. Si el driver de Windows tampoco escribe la RAM antes de un paso que
aquí falta, es que Windows la enciende por `PoFx`/PEP y entonces la pieza es
replicar el PEP, no el driver.

## Ruta B: sonido sin el DSP

El códec RT5640 está vivo sin tocar el DSP: en `i2c-5` (adaptador 5) dirección
`0x1c` devuelve `0x10EC` en el registro `0xFE` (fabricante Realtek) y `0x6231`
en `0xFF` (dispositivo), **sin MCLK ni driver cargado**. Con el códec accesible
y el SSP3 relojado, el camino barato es I2S directo (ASoC + `snd-soc-rt5640`)
con el DSP en `bypass`, sin firmware ni RAM del DSP.

Cautela: el árbol 7.3.4 usado para la GPU no lleva ASoC ni el driver de bring-up
del SST. Para esta ruta hay que activar `SND`/`SND_SOC`/`SND_SOC_RT5640` y el
SSP (o volver al árbol 6.12 donde ya estaba el driver de pruebas).

## Bring-up sin arriesgar el arranque

Una prueba de DMA o de MMIO puede dejar el equipo sin red. **Nunca la ejecutes
desde `probe()`**: pon el driver a mapear y registrar, y expón la prueba en
`debugfs` (un `debugfs_create_file("dma_test", 0200, ...)` que acepte
"sram"/"iram"). Así el arranque siempre termina, la prueba se dispara por SSH
cuando interesa y, si se cuelga, el log ya está volcado a disco en el intento
anterior.

## Firmware

`realtek_fw_sst.bin` (carpeta del driver `isstrtc.inf_x86_*`) usa el formato
`$SST$`: cabecera de módulo + bloques con `type` (IRAM/DRAM), `size` y
`entry_point`, exactamente lo que espera el cargador `sst_parse_module_*` de
Android. No hay que convertir nada: hay que portar el cargador.
