# Inventario ACPI del equipo y mapa de drivers

Para saber qué chips tiene una máquina y qué driver necesita cada uno, sin
desmontarla ni fiarse del fabricante: saca sus tablas ACPI desde el sistema que
sí arranca (normalmente Windows), descomponlas y búscalas en la fuente del
kernel. Sin esto, "crear drivers desde cero" es adivinar.

## 1. Volcar las tablas ACPI desde Windows

Las tablas viven en el registro, como valores binarios bajo
`HKLM\HARDWARE\ACPI`. Se copian a disco con PowerShell (sin privilegios
especiales; solo lee):

```powershell
$out = 'C:\ubuntu\acpi'
New-Item -ItemType Directory -Force $out | Out-Null
Get-ChildItem -Recurse 'HKLM:\HARDWARE\ACPI' | ForEach-Object {
  $k = $_
  foreach ($n in $k.GetValueNames()) {
    $v = $k.GetValue($n)
    if ($v -is [byte[]]) {
      $name = ($k.Name -replace '^HKEY_LOCAL_MACHINE\\HARDWARE\\ACPI\\','' -replace '\\','_') + '.dat'
      [IO.File]::WriteAllBytes((Join-Path $out $name), $v)
    }
  }
}
Get-ChildItem $out | Select-Object Name,Length | Format-Table -AutoSize
```

Los nombres de clave delatan el firmware: `DSDT\INTEL_\CLOVERVW` = plataforma
Cloverview (Clover Trail), `FADT\INTEL_\LANFORDC` = placa Lanford. Lo que
interesa es el `DSDT` (decenas de KB); los `SSDT`/`SSD*` son complementos.

Llevarlo al equipo de trabajo con `scp`:

```
scp -q "usuario@IP:C:/ubuntu/acpi/*" acpi/
```

## 2. Descompilar sin instalar nada como root

`iasl` viene en `acpica-tools`. Se desempaqueta en local y se usa desde ahí:

```
cd tools && apt-get download acpica-tools && dpkg -x acpica-tools_*.deb x
cd ../acpi && for f in *.dat; do ../tools/x/usr/bin/iasl -d $f; done
```

Quedan los `.dsl` legibles.

## 3. Leer el DSDT: qué buscar

No lo leas entero, extrae por bloques con llaves balanceadas (los `{`/`}` de
ASL son equilibrados, así que un contador basta):

```python
import re
def block(s, name):
    m = re.search(r'Device \(' + name + r'\)\s*\{', s)
    i, d = m.end(), 1
    while d:
        c = s[i]; d += (c == '{') - (c == '}'); i += 1
    return s[m.start():i]
```

En cada `Device` mira: `_HID` (identificador con el que el kernel lo enlaza),
`_CID` (compatibles), `_DDN` (nombre que le pone el fabricante, muy útil),
`_CRS` (MMIO e IRQ reales), `_DEP` (de quién depende), `_STA`.

Un barrido rápido de todos los `Device` con su `_HID`, memoria e IRQ da el
inventario completo en una tabla. Eso es el mapa del hardware.

## 4. Decidir si ya existe driver (fuente del kernel por versión)

Busca el `_HID` en los drivers candidatos de varias versiones. La fuente por
rama se sirve así (con `?h=<tag>`):

```
B=https://git.kernel.org/pub/scm/linux/kernel/git/torvalds/linux.git/plain
curl -s "$B/drivers/mmc/host/sdhci-acpi.c?h=v6.1" | grep -oE 'INT33B[0-9A-F]'
```

`raw.githubusercontent.com` responde 429 con facilidad; `git.kernel.org` aguanta
el barrido. Comprueba siempre **al menos dos versiones** (la antigua que se va a
usar y una moderna): un ID puede faltar en la vieja y estar resuelto en la nueva.

Sitios donde mirar por tipo de chip: `drivers/i2c/busses/i2c-designware-platdrv.c`,
`drivers/usb/host/ehci-platform.c` y `ehci-pci.c`, `drivers/mmc/host/sdhci-acpi.c`,
`drivers/pinctrl/intel/`, `drivers/tty/serial/8250/8250_dw.c`,
`drivers/spi/spi-pxa2xx*`, `drivers/acpi/acpi_lpss.c`, `drivers/acpi/acpi_apd.c`,
`drivers/idle/intel_idle.c`, `drivers/hid/i2c-hid/`.

## 5. Los tres modos de fallo (y qué implica cada uno)

1. **El chip tiene driver pero el ID no está en su tabla.** Lo más barato: añadir
   el `_HID` (o el PCI ID) a la tabla de match. Ejemplo: `INT33B6`/`INT33B9` son
   EHCI que se anuncian con el `_CID` malformado `"ACPI\\PNP0D20"` (con prefijo
   `ACPI\` dentro de la cadena) y por eso `ehci-platform` no los enlaza.
2. **Hay driver, pero está enlazado al chip equivocado.** El kernel enlaza por
   ID, sin comprobar el silicio. Si dos chips de la familia comparten HID, entra
   el driver de otro con otro mapa de registros: no da error, da **datos falsos**.
   Es el fallo más caro de diagnosticar porque los síntomas son plausibles e
   incoherentes entre sí.
3. **El chip no está en ningún kernel.** Ahí sí hay que escribir driver, y
   conviene reutilizar el de la familia (mismo bloque IP, otra variante).

## 6. Caso resuelto: familia Intel Cloverview (Clover Trail, Atom Z2760)

Mapa de IDs de esta familia, sacado de un DSDT real (`HID → driver que lo
necesita`):

| ID | Qué es | Driver |
|---|---|---|
| `INT33B0` | SPI | `spi-pxa2xx` |
| `INT33B1` | I2C DesignWare ×6 | `i2c-designware-platdrv` (no enlazado en ningún kernel) |
| `INT33B2` | GPIO: `GPO0` AON y `GPO1` Corewell | **no** es Baytrail: `pinctrl-baytrail` se engancha y lee mal |
| `INT33B4` | I2C de consumo (CHAB) | `i2c-designware` |
| `INT33B5` | IPC / MSIC | `intel_mid_powerbtn`/`intel_mid_thermal` (legacy) |
| `INT33B6` | USB OTG EHCI | `ehci-platform` + añadir ID |
| `INT33B9` | USB SPH EHCI | `ehci-platform` + añadir ID |
| `INT33BB` | SD/eMMC (hub compartido) | `sdhci-acpi` (sí lo soporta) |
| `INT33BC` | HSUART ×3 | `8250_dw` |
| `INT33BD` | Mailbox | `intel_mid_pwr`/legacy |
| `ATML1000` | táctil Atmel, `_CID PNP0C50` | `i2c-hid` (necesita el bus I2C) |
| `SMO91D0` | sensor hub | `hid-sensor-hub` |

Dos trampas concretas de esta plataforma:

- **`INT33B2` engancha `pinctrl-baytrail`** (también aparece en `acpi_lpss`). El
  bloque IP no es Baytrail: mapas de registros distintos → lecturas falsas. La
  base correcta es `gpio-intel-mid` (la variante Cloverview se identifica por
  PCI `0x08eb`/`0x08f7`).
- **`_LID` de la tapa no es un GPIO normal**: `LID0._LID` devuelve
  `\_SB.GPO0.HALS` (pin `0x47` del GPIO AON) solo si `GPO0.AVBL==1`; si no,
  devuelve 1 (abierta). Con el driver equivocado, `AVBL` se registra y la
  lectura del pin da "cerrada" siempre → `systemd-logind` suspende a los pocos
  segundos de arrancar y el equipo parece colgado con pantalla negra.

En `intel_idle`, `ATOM_SALTWELL` (familia 6 modelo `0x36`, Cedarview) está
soportado; `SALTWELL_TABLET` (modelo `0x35`, Cloverview) **no**, ni en 6.1 ni en
6.12. Mientras no se parchee: `idle=poll`.

## 7. El `_DSM` de post-reset: lo que Windows hace y Linux no

Cuando el controlador EHCI arranca, dice `1 port detected` y el puerto no
enumera nada, el driver está bien y falta la configuración que el firmware
espera tras cada reset. Windows llama para eso a un `_DSM` con UUID
`ce2ee385-00e6-48cb-9f05-2edb927c4899`:

| Función | Qué hace |
|---|---|
| 1 | *Post-reset processing* en controladores dual-role: modo host, VBUS, PHY |
| 2 | Tipo de puerto (host / peripheral / dual-role) |
| 7 | Indicador de rol del conector |

Se localiza en el ASL con `grep -n 'ce2ee385' *.dsl` y se reconoce porque el
cuerpo escribe el registro `USBMODE` (en Cloverview, `USBCMD`/`UFOT` y
`USBMODE`/`UFOS` dentro del `OperationRegion (KEYS, SystemMemory, 0xFFA60000…)`
con `UFOS = 0x23`). El `_PS0`/`_PS3` del mismo `Device` solo toca bits de
alimentación (`UFOT`), así que si el puerto sigue muerto el que falta es el `_DSM`.

Parche mínimo en el driver del controlador (aquí `ehci-platform.c`, dentro de
`*_reset()` después de `ehci_setup()`, que es cuando el controlador ya está
reiniciado):

```c
static const guid_t usb_dsm_guid =
	GUID_INIT(0xce2ee385, 0x00e6, 0x48cb,
		  0x9f, 0x05, 0x2e, 0xdb, 0x92, 0x7c, 0x48, 0x99);

static void ehci_platform_acpi_post_reset(struct device *dev)
{
	acpi_handle handle = ACPI_HANDLE(dev);
	union acpi_object *obj;

	if (!handle || !acpi_check_dsm(handle, &usb_dsm_guid, 0, BIT(1)))
		return;
	obj = acpi_evaluate_dsm(handle, &usb_dsm_guid, 0, 1, NULL);
	ACPI_FREE(obj);
}
```

Detalles que cuestan un ciclo de prueba si se ignoran:

- **`acpi_check_dsm` con máscara `BIT(1)`** antes de llamar: el `_DSM` puede
existir solo para la función 2 y devolver `AE_OK` sin hacer nada; preguntar por
la función 1 evita parchear un controlador que no lo necesita.
- **El `_DSM` va por `acpi_handle` del dispositivo del controlador**, no por
`_HID`: funciona igual si el ID entró por tabla de match o por `_CID`.
- **Después del `*_reset()`**, no en `probe`: el reset es lo que apaga el modo
host, y `resume` vuelve a pasar por ahí.
- Cuidado con el orden de las funciones en el archivo: `ehci-platform.c` ya
tiene un `ehci_platform_reset()` y un `ehci_platform_power_on()`; el `_DSM` va
en el primero, y su resultado se registra con `dev_info` para poder confirmarlo
por SSH (`ACPI _DSM post-reset processing (host mode) applied`).

Para saber **qué** controlador está mudo, la topología de Windows es la fuente:
la cadena de padres sale de `Get-PnpDevice` +
`Get-PnpDeviceProperty -KeyName DEVPKEY_Device_Parent`, que da nombre,
`InstanceId` y padre (`ACPI\INT33B6` → `USB\ROOT_HUB20` → hub → dispositivo).
Cruzada con los `hub 1-0` / `hub 2-0` de dmesg, dice si el problema es de un bus
concreto o de todos, sin tocar nada en la tableta.

## 8. GPIO Intel Cloverview (`INT33B2`): mapa de registros verificado

El GPIO es la pieza raíz de esta plataforma: la tapa (`_LID`), el encendido del
WiFi (`QCA1._PS0` vía opregion), los botones y las interrupciones del táctil
colgando de otros buses. Se escribe contra el bloque `gpio-intel-mid` de la
variante Cloverview, no con `pinctrl-baytrail`.

**Mapa de registros (layout Langwell, 96 pines → 3 palabras por registro).**
`nreg = ngpio/32`; para el pin *n*: `reg_base + <offset> * nreg * 4 + (n/32) * 4`,
bit `n % 32`. En `GAFR` son **2 bits por pin** (6 palabras para 96 pines):

| Registro | Offset | Función |
|---|---|---|
| `GPLR` | `0x00` | nivel del pin (solo lectura) |
| `GPDR` | `0x0C` | dirección (1 = salida) |
| `GPSR` | `0x18` | poner a 1 |
| `GPCR` | `0x24` | poner a 0 |
| `GRER` | `0x30` | detección de flanco de subida |
| `GFER` | `0x3C` | detección de flanco de bajada |
| `GEDR` | `0x48` | estado de flanco detectado (se limpia escribiendo el bit) |
| `GAFR` | `0x54` | función alternativa, 2 bits/pin (`0x54`-`0x68`) |

**Dos bloques, dos IRQ** (de los `_CRS` del DSDT): `GPO0` AON en `0xFF119000`,
IRQ `0x70`, admite flanco y nivel; `GPO1` Corewell en `0xFF13F000`, IRQ `0x74`,
**solo flanco**. En `gpio-intel-mid` eso sale de la `ddata` (`cloverview_aon`
= edge|level, `cloverview_core` = edge).

**Verificar el mapa en la máquina antes de escribir código.** Desde el Linux ya
arrancado, con `busybox devmem`:

```sh
for base in 0xFF119000 0xFF13F000; do echo "== $base"; o=0
  while [ $o -lt 108 ]; do a=$(printf 0x%X $((base+o)));
    printf "%03X: %s\n" $o $(busybox devmem $a 32); o=$((o+4)); done; done
```

Salen las ocho zonas con valores plausibles (`GPDR` con pines ya configurados
como salida, `GAFR` con patrones de 2 bits), y con un pin conocido se valida el
desplazamiento: en la ElitePad 900 el sensor Hall es el pin 71 de `GPO0`,
entrada, y su `GPLR` cambia al abrir y cerrar la tapa. Ese cotejo —estado del
registro contra el estado físico— es lo que confirma el mapa; los valores por sí
solos no.

Cautelas al portar el driver:

- **`GAFR` no se toca a ciegas.** El `request` de `gpio-intel-mid` pone los dos
  bits del pin a `00` (función GPIO): si el firmware dejó ese pin en función
  alternativa para otro periférico, pedirlo lo rompe. Limpia `GAFR` solo en los
  pines que el driver va a usar de verdad.
- **El bloque Core no hace interrupciones por nivel.** Si un consumidor pide
  nivel bajo (habitual en `i2c-hid`/táctil), hay que emularlo con flancos o
  ponerlo en el AON, que sí lo soporta; comprueba en el `_CRS` de qué
  controlador cuelga antes de diseñar nada.
- **API actual**: en 6.x el `irq_chip` del `gpio_chip` es inmutable (los
  callbacks se fijan al registrarlo) y el dominio se crea con
  `GPIOCHIP_IRQ_RESOURCE_HELPERS` + `gpiochip_irqchip_add_domain()`. Modelos
  que leer antes de escribir: `drivers/gpio/gpio-tangier.c` y
  `drivers/pinctrl/intel/pinctrl-baytrail.c`; la referencia histórica del bloque
  es `gpio-intel-mid.c` de 4.15 (PCI `0x08eb` AON, `0x08f7` Core).

**Leer los pines del DSDT sin engañarte con el formato.** `iasl` imprime
`GpioInt (Edge, ActiveBoth, Exclusive, PullDefault, 0x0000, "\\_SB.GPO0", 0x00,
ResourceConsumer, ,)` y deja el número de pin en un comentario `// 0xNN` dentro
del bloque de la macro, con las líneas partidas según versión y longitud. Un
regex de una pasada sobre el `.dsl` entero devuelve vacío y hace concluir "aquí
no hay GPIO". Extrae primero el `Device` con el contador de llaves de §3 y lee
su `_CRS` en bloques (`grep -n -A4 'GpioInt\|GpioIo'`): lo que hace falta es, por
cada `GpioInt`/`GpioIo`, el controlador (`\\_SB.GPO0` o `\\_SB.GPO1`), el pin y
el tipo de disparo.

## 9. Audio: RT5640 + DSP SST

El códec y el DSP de audio no siguen este mapa de `_HID → driver`: el códec va
por I2C y el DSP por MMIO con firmware propio. Direcciones extraídas del driver
de Windows, registros del SHIM, formato `$SST$` y estado del port en
`audio-sst-cloverview.md`.

## 10. Portar GPIO, I2C y SDIO desde la referencia Android

La referencia es el kernel Android 3.4 de Clover Trail+ (`lenovo-k900`,
`android_kernel_lenovo_redhookbay`): `gpio-langwell.c`,
`i2c-designware-pcidrv.c` (variante `cloverview_N`), `sdhci-pci.c` y el SST.
Son los mismos bloques IP, pero anunciados por ACPI, así que se portan como
drivers ACPI. Tres trampas, una por bloque:

- **GPIO `INT33B2`**: `pinctrl-baytrail` también reclama ese HID y lo programaría
  con un layout equivocado; déjalo desactivado. Driver propio con gpiolib,
  `irq_chip` inmutable y handler colgado de la IRQ padre compartida;
  gpiolib-acpi solo registra el OpRegion y los `_AEI`.
- **I2C `INT33B1` (DesignWare 1.08)**: `IC_COMP_PARAM_1` lee 0, el driver calcula
  una FIFO de 1 y, como no hay hold-master, manda STOP tras cada byte: un HID
  devuelve el primer byte y luego ceros. Fija la FIFO (256) y los HCNT/LCNT de
  la referencia.
- **SDIO `INT33BB` uid 2**: el host solo anuncia 1,8 V y el chip WiFi contesta
  con OCR de 3,3 V (`no support for card's volts`). Hay que anunciar 3,3 V y
  alimentar a 1,8 V.
