# Clover Trail (Z2760): coste y veredicto de cada pieza

Cuando alguien pregunta "¿cuánto falta?" en una tableta de esta familia, la
respuesta se da **por pieza**, con la fuente de la que sale el código y el
riesgo dominante de cada una. Resumen de lo investigado, para no repetirlo:

| Pieza | Estado | Coste honesto | Riesgo dominante |
|---|---|---|---|
| GPIO `INT33B2`, I2C `INT33B1`, SDIO `INT33BB`, reset por SCU | **hecho y verificado** | — | `pinctrl-baytrail` reclama `INT33B2`: desactívalo |
| Táctil `ATML1000`, WiFi `AR6004` | **hecho y verificado** | — | firmware del WiFi: `firmware-atheros` (hw1.3), no el del driver Windows |
| Códec RT5640 + DSP SST | **el códec responde por I2C**; el DSP sigue sin RAM | días | encendido de la RAM del DSP (ver `audio-sst-cloverview.md`) |
| GPU PowerVR SGX545 (`8086:08cf`) | **funciona: dibuja, presenta en pantalla y reproduce vídeo** | semanas para Mesa usable | rendimiento de Mesa; sin GLES 3.0 no hay navegador acelerado |
| Cámaras OV8830 / OV2720 | proyecto aparte | 200-390 h, 40-60 % de éxito | **el firmware del ISP no está en Linux** |

## GPU: `powervr_sgx` (SGX545)

Existe un stack abierto completo para este mismo núcleo: driver DRM, microkernel
en ensamblador USSE y driver Mesa (`The1TrueJoe/powervr_sgx`). Soporta la SGX545
de Cedarview y CE5300; Clover Trail aparece como "fuera de alcance" solo por la
pantalla, no por la GPU.

**Estado medido en la tableta: el microkernel arranca y dibuja.** Con el kernel
7.x y el driver como módulo, el probe termina y hay `/dev/dri/renderD128`; en
debugfs, `firmware running: 1`, `BIF_FAULT 0`. Con las pruebas de la uAPI
compiladas para i386: **40/40 cortas**, trabajo nulo en ~539 µs, **primer frame
3D con los píxeles verificados** (1,7 ms), 100 frames seguidos en ~1 s, 20 con
tres contextos, blits correctos y recuperación de los cuelgues provocados. Los
dos riesgos reales de esta pieza —que el microkernel no corriera en este stepping
y que la interrupción no llegara— están cerrados; lo que queda es Mesa.

Orden de trabajo que funcionó:

1. Suscitar el firmware propio: el microkernel abierto se **ensambla** en el
   repo (`ukernel/build.py sgx545`) y se envuelve en el contenedor que carga el
   driver (`drm/tools/mkukfw.py --manifest`, imprime `features` y CRC). Sin este
   paso el driver abre el firmware y se queda sin nada que ejecutar.
2. Kernel 7.3.4 con `DRM_POWERVR_SGX=m` más `DRM_EXEC`, `DRM_GPUVM` y
   `GPU_SCHED` (van como módulos y se cargan antes, en ese orden). El árbol
   necesita los mismos parches de plataforma de siempre.
3. Los módulos **no están en el initramfs**: tras cada arranque hay que subirlos
   por `tar`+`ssh` con el firmware a `/lib/firmware/powervr_sgx/` y hacer
   `insmod` de la cadena. Automatízalo o cada prueba cuesta un arranque entero.
3-bis. Un script por arranque que suba módulos, firmware y pruebas e hiciera el
   `insmod` en orden: sin él la iteración no avanza. Los binarios de prueba se
   compilan i386 estáticos contra un sysroot sacado de los `.deb` `:i386` (ver
   SKILL.md, "Herramientas de prueba de 32 bits").
4. Si el probe falla con `-22`, es la interrupción: pin 0 en config space. **La
   GSI del `_PRT` no sirve** —registra el handler y no llega nada—: pide MSI y
   abre el bit 18 de los registros del display en el mismo BAR0 (ver SKILL.md).

Comprobaciones útiles en debugfs (`/sys/kernel/debug/dri/<minor>/`): `status`
(`firmware running`, `lost`, `resets`, `irqs`, `hostctl`, `powered`), `regs`
(`CORE_ID`, `EVENT_STATUS*`, `BIF_INT_STAT`, `BIF_DIR_LIST_BASE0/15`) y
`clients`. Un `resets: 0` con `firmware running: 1` después de unos minutos es
la señal de que el microkernel vive y atiende, no solo de que cargó.

- **i386 no es el bloqueo**: Mesa se compila para 32 bits y la uAPI es idéntica
  en 32 y 64 bits.
- **Sí lo es la versión del kernel**: el driver apunta a Linux 7.3
  (`kzalloc_obj`, `pcim_iomap_region`, `drm_sched_job_init` de 5 argumentos).
  Hay dos caminos: subir el kernel propio a 7.x arrastrando los parches locales,
  o llevar ~6-10 shims de compatibilidad a 6.12.
- **La pantalla es aparte**: el backend no implementa `bo_wrap`, así que no hay
  presentación por fbdev propia. La ruta que sí funciona es `simpledrm`
  (SYSFB_SIMPLEFB + DRM_SIMPLEDRM + DRM_FBDEV_EMULATION) con kmsro (ver la
  sección siguiente). Chromium sigue fuera de alcance (ANGLE pide GLES 3.0 y la
  SGX545 da 2.0, así que dibuja por CPU), pero **WebKit sobre GTK 3 sí acelera**:
  ver «Navegador acelerado con GLES 2».
- **Antes de prometer nada**, mide el núcleo: `CORE_ID` en `BAR0+0x80000+0x1C` y
  `CORE_REVISION` en `+0x20` (lectura sola; la isla suele estar encendida porque
  el GOP usa la pantalla). Si esos dos registros no dan un valor con sentido, la
  ventana del SGX no está donde se cree y todo lo demás sobra.
- **Medido en la tableta, solo lectura:** ventana `BAR0+0x80000` =
  `0xFF280000` (la que espera el driver, confirmada), `CORE_ID` `0x01150000`
  (SGX545), `CORE_REVISION` `0x0001000e` = 1.0.14, `CLKGATESTATUS` 0 (solo
  `DPM_CLKS` apagado, normal sin driver), `BIF_CTRL` `0x0000ff00`, PCI revisión
  `0x05`, comando `0x0007`. La isla está encendida y la GPU responde desde el
  primer arranque: el direccionado nunca fue el riesgo.
- **La revisión 1.0.14 es la misma que la del CE5300, y la tabla del driver busca
  por `(familia, revisión)`.** Escribir `0x0001000e` en el `#define` del Clover
  Trail **no activa su entrada**: la búsqueda cae en la del CE5300 (400 MHz) y
  aplica sus parámetros sin avisar. La entrada de Clover Trail es código muerto
  hasta que se discrimine por PCI ID (`8086:08cf`) o por part. El comentario del
  driver lo deja a 0 a propósito para no conducir a ciegas: no lo rellenes sin
  resolver antes qué entrada gana.

### Presentación en pantalla: cerrada con `simpledrm` + `kmsro`

Con el kernel 7.x, `simpledrm` de consola y Mesa `sgx` instalado, se presenta en
la pantalla real: `kmscube` y `glmark2` pintan (87 FPS build, 112 texture, 60
shading phong) y `mpv` reproduce vídeo a pantalla completa (YouTube 480p30,
45 s, **1 fotograma perdido**, 28 % de CPU total). No hace falta `bo_wrap` ni
fbdev propio: lo que faltaba era la interfaz de winsys para clientes GBM.

- **`glmark2` necesita `--visual-config a=0`**: sin eso pide un config EGL con
  canal alpha y acumula ~89 rechazos hasta dar con uno; con `a=0` no rechaza
  ninguno y arranca a la primera.
- **Los modificadores de dmabuf**: `mpv` (y cualquier cliente que llame a
  `gbm_surface_create_with_modifiers`) falla con `Failed to create GBM surface`,
  `Failed to setup GBM` y `Failed initializing any suitable GPU context` si el
  screen no los expone. Se registran con el resto en `..._screen_init()`:

  | Punto de entrada | Qué devuelve |
  |---|---|
  | `resource_create_with_modifiers` | el recurso si la lista pide `LINEAR` o `INVALID`; `NULL` si no |
  | `query_dmabuf_modifiers` | `count = 1`, `modifiers[0] = LINEAR`, `external_only[0] = 0` |
  | `is_dmabuf_modifier_supported` | `true` solo para `LINEAR` |

  Como los búferes lineales ya existen, los tres son triviales; sin ellos, GBM
  no llega a crear la superficie y el síntoma se lee como "no hay GPU".
- **Diagnóstico que lo separa de un fallo de vídeo**: `mpv -v` con una fuente
  local (`av://lavfi:testsrc2=size=1280x720:rate=30`). Si el log dice
  `Driver: simpledrm`, `Supported modifier: 0x0` y muere en `Creating GBM
  device` / `Failed to create GBM surface`, es el screen; si ni siquiera abre el
  DRM, es el kernel o el nodo.

## Navegador acelerado con GLES 2 (medido en la tableta)

El nivel de GL que da Mesa (`OpenGL ES 2.0 Mesa 26.2.5`) no cierra la puerta a
un navegador acelerado: lo que decide es lo que pide cada toolkit.

| Navegador | Toolkit | Veredicto en `webkit://gpu` |
|---|---|---|
| Chromium | ANGLE, exige GLES 3.0 | software |
| Epiphany / GNOME Web | WebKitGTK sobre GTK 4.18 | `Policy: never`; en consola «Disabled hardware acceleration because GTK failed to initialize GL: No hay ninguna configuración de EGL disponible» |
| `surf`, `luakit`, `vimb` | WebKitGTK sobre GTK 3 | `Policy: always`; `Renderer DMAbuf (Hardware, Shared Memory)`; `Platform GBM`; `GL_RENDERER PowerVR SGX545`; `Threaded rendering GPU (2 threads)`; `2D canvas Accelerated` |

Campos que hay que leer: **Policy** (si dice `never`, ese toolkit no acelera y
no hay flag que lo cambie), **Renderer**, **API**, **Platform**, **DRM version**
(tiene que nombrar el driver propio, p. ej. `powervr_sgx`), **GL_RENDERER** /
**GL_VERSION** y **Supported buffers** (los formatos `NONE_LINEAR` son los que
da un winsys sin tiling).

- **`WebGL enabled` no mide aceleración**: puede estar a `Yes` en Epiphany con
  `Policy: never`, y a `No` en `surf` con la GPU funcionando.
- **El sandbox de WebKit no ve `/opt`**: con Mesa en `/opt/sgx/lib` el navegador
  solo arranca con `WEBKIT_DISABLE_SANDBOX_THIS_IS_DANGEROUS=1`, válido para
  medir pero no para entregar. Para dejarlo instalado, la pila va a una ruta que
  el sandbox monte (`/usr/local/lib`) y se repite la medida **sin** la variable.
- **Que use la GPU no prueba que vaya más rápido** en un Atom: mide scroll y
  carga reales antes de cambiar el navegador por defecto del equipo.

Cómo leer `webkit://gpu` sin estar delante: en Epiphany un modal («¿Establecer
como su navegador predeterminado?») tapa la página y «Print in stdout» no vuelca
nada al log del proceso. El camino fiable es abrir la misma página con un
navegador GTK 3 (`apt-get install surf`), alejar el zoom tres veces
(`ctrl+minus`), bajar con `Page_Down` y capturar con `xwd -root` → `ffmpeg` para
leerla con visión.

## Cámaras: ISP2300 (CSS 1.5), no el atomisp de mainline

- El ISP es **PCI `8086:08d0`** en `00:03.0` (visto en el arranque real),
  `CONFIG_ISP2300` / CSS 1.5 en la referencia Android. El `atomisp` de
  `drivers/staging` solo cubre ISP2400/2401 (Bay Trail / Cherry Trail): **no
  sirve**.
- Los sensores ya enumeran como dispositivos I2C (`INTCF2A` OV8830, `INTCF0B`
  OV2720, `INTCF1C` flash LM3554) pero **no tienen `_PS0` en el DSDT**: el AML no
  enciende los raíles, todo el encendido es del driver (VPROG1 del PMIC por SCU
  IPC, GPIO de reset, MCLK de 19,2 MHz).
- **Punto de no retorno: el firmware `shisp_css15.bin`** no está en
  `linux-firmware` (allí solo hay los de 2400/2401), no es recompilable y hay
  que sacarlo del DriverStore de la propia máquina. Sin él, el port no pasa de
  la fase 2: compruébalo **antes** de estimar semanas.
- El grueso del trabajo es `videobuf` → `vb2` en el driver de cámara.
- Alternativa para vídeo de vigilancia sin este port: cámara USB (UVC) en el
  dock, coste cero de software. Y para el botón de apagar de verdad: cortar en
  cascada (stream → MCLK → GPIO de reset → raíl), no solo el stream.

## Cómo se comunica esto

- El plazo va **por pieza**, con la fuente de la que sale el código, no por el
  conjunto ("el códec, días; el DSP, días; la GPU, meses").
- "Meses" se justifica con un número (horas, probabilidad) sacado de leer el
  código de referencia, no de la intuición. Y se comprueba antes si el mismo IP
  vive en el kernel Android del SoC: eso convierte "meses" en "portar".
- Antes de aceptar un proyecto largo, ofrece la ruta barata que consigue el
  objetivo de hoy (webcam USB para Frigate, presentación por CPU para el panel)
  y deja el proyecto largo como aparte.
