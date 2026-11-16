# Preparación de Clover Trail en `powervr_sgx` — estado y qué falta medir

**Fecha:** 2026-11-13 · **Rama local:** `clovertrail` en `$HOME/src/powervr_sgx`
(desde `main` @ `25022a5`), **sin push**. · **Tableta: no se ha tocado.**

Todo lo de este documento es preparación: código que compila, una herramienta que solo
lee, y documentación. Lo que no hay es una sola lectura de los registros de la GPU.

---

## 1. Lo que se ha hecho (y se puede ver en git)

```
$ git log --oneline main..clovertrail
0436cdd docs: kernel.md names the parts table for the PCI pattern
359ead6 docs: Clover Trail platform notes and a test-kernel fragment
ecf1ef9 drm/powervr_sgx: support the SGX545 of Intel Clover Trail (8086:08cf)

$ git diff --stat main..clovertrail
 docs/porting/README.md                   |   5 +
 docs/porting/cores/clovertrail.md        | 215 +++++++++++++++++++++++++++++++
 docs/porting/kernel.md                   |   7 +-
 drm/ci/clovertrail.fragment              |  22 ++++
 drm/powervr_sgx/Kconfig                  |  15 ++-
 drm/powervr_sgx/pvrsgx_core.c            |  44 ++++++-
 drm/powervr_sgx/pvrsgx_core.h            |  36 +++++-
 drm/powervr_sgx/pvrsgx_device.h          |   2 +
 drm/powervr_sgx/pvrsgx_drv.c             |  55 ++++++++-
 drm/powervr_sgx/pvrsgx_drv.h             |   9 +
 drm/powervr_sgx/pvrsgx_pm.c              |  42 ++++++-
 drm/powervr_sgx/tests/pvrsgx_core_test.c |  17 ++
 12 files changed, 454 insertions(+), 15 deletions(-)
```

### El diseño, en cuatro piezas

**a) Una "part" es dato, no un driver nuevo.** `pvrsgx_parts[]` (en `pvrsgx_drv.c`)
lleva número de core, offset de la ventana dentro de BAR 0 y flags de energía; el
`driver_data` de la tabla de ids PCI indexa esa tabla:

| PCI id | core | `regs_off` | flags |
|---|---|---|---|
| `8086:089b` (CE5300) | 545 | 0 | — |
| `8086:08cf` (Clover Trail) | 545 | `0x80000` | `PVRSGX_PART_ISLAND_ALWAYS_ON` |

`pvrsgx_probe()` mapea BAR 0 y suma el offset; comprueba que
`pci_resource_len(0) >= regs_off + PVRSGX_REGS_MIN`. Es un driver **PCI directo**, no
auxiliar de gma500, porque para Cloverview no hay gma500: el mismo patrón que CE5300,
con un offset. **No** se llama a
`drm_aperture_remove_conflicting_pci_framebuffers()`: el framebuffer del firmware y el
`simpledrm` que se construirá sobre él tienen que sobrevivir.

**b) Tabla de core con revisión pendiente.** Entrada
`"Intel Clover Trail (SGX545 1.0.xx)"`, `clock_hz = 533000000`,
`core_rev = PVRSGX_CLV_CORE_REV` = **`0`**, con un `TODO(clovertrail)` que dice de dónde
sale el valor. `0` no puede casar: `pvrsgx_core_lookup()` rechaza `0` y `~0` (lo que lee
una ventana sin core detrás), así que en la primera prueba el driver **registra los dos
valores y no toca la GPU** en vez de arrancar a ciegas. Ese es el resultado esperado del
primer arranque, no un fallo.

**c) Energía conservadora.** La isla gráfica la gobierna el P-Unit (bloque APM); ACPI no
la enciende (`GFX0._PS0` solo escribe `GDDS`). Sin hand-over APM:

| Comportamiento | Dónde |
|---|---|
| Referencia permanente: nunca hay runtime suspend ni parada del microkernel | `pvrsgx_power_init()` / `_fini()` |
| `runtime_suspend` devuelve `-EBUSY` si alguna vez se alcanza | `pvrsgx_runtime_suspend()` |
| Suspensión del sistema **rechazada** con aviso (sin APM no se puede volver) | `pvrsgx_suspend()` |

Coste explícito: mientras el módulo esté cargado, la tableta no puede dormir. Es lo
primero que hay que quitar cuando exista soporte APM (`rmmod powervr_sgx` para dormir,
documentado en Kconfig y en la nota del core).

**d) Dos cambios de tabla que hacían falta para partir un core en dos partes.**
`CORE_ID` se compara por su número de core (`GENMASK(31,16)`): los 16 bits bajos son
CONFIG, del integrador. Y una revisión `0`/`~0` se rechaza. Los dos tienen caso KUnit
nuevo en `tests/pvrsgx_core_test.c`.

---

## 2. La herramienta de identificación

**Ruta:** `~/elitepad-dev/tools/sgx-ident/` — `sgx-ident.c`, `Makefile`, `README.md` y el
binario `sgx-ident` (12.484 bytes).

- **Qué es:** ELF 32-bit i386, `-static -nostdlib -fno-pic`, enlazado contra el **nolibc**
  del kernel (`linux-6.12.117/tools/include/nolibc`), sin libc de 32 bits. Sin
  intérprete, sin símbolos indefinidos (`nm -u` vacío). Compila y enlaza en este host,
  que no tiene libc i386: **verificado**.
- **Qué lee:** `0000:00:02.0` config space (vendor, device, BAR 0: 8 bytes, solo lectura)
  y, con **una** `mmap` de **una** página `PROT_READ` sobre `/dev/mem`, los ocho registros
  de la lista blanca: `CLKGATECTL` 0x0000, `CLKGATESTATUS` 0x0008, `CORE_ID` 0x001c,
  `CORE_REVISION` 0x0020, `SOFT_RESET` 0x0080, `EVENT_STATUS` 0x012c,
  `EVENT_HOST_ENABLE` 0x0130, `BIF_CTRL` 0x0c00, desde la ventana `0xFF280000`.
- **Qué no hace:** ninguna escritura — ni a la GPU, ni al config space, ni al BAR; no hay
  barridos. Se niega a ejecutarse si el dispositivo no es `8086:08cf` (salvo `--force`).
  `--dry-run` imprime lo que leería sin mapear nada.
- **Cómo se ejecuta:** en la tableta, como root, desde el initramfs:
  `sgx-ident --dry-run` y luego `sgx-ident`. `build-initramfs.sh` ya lo copia a
  `/usr/bin/sgx-ident` si el binario existe (3 líneas añadidas).
- **Salida:** los ocho valores, y un veredicto que además imprime la línea exacta para
  `pvrsgx_core.c` (`.core_rev = 0x…`), la revisión en `major.minor.maint`, y si
  `CLKGATESTATUS` tiene `DPM_CLKS` (bit 5).
- **Códigos de salida:** 0 SGX545 confirmado · 2 la ventana no responde como SGX545 ·
  3 no es `8086:08cf` · 4 `/dev/mem` o `mmap` fallan · 1 argumentos.
- **Probado:** `make check` (config space y ventana simuladas → veredicto correcto,
  revisión 1.0.15 desconocida, CONFIG extraído), `--dry-run` y `--help` en este host.
  Los caminos de error (identidad ajena → rc 3; ventana vacía → rc 2) también.

---

## 3. Hallazgo que cambia una decisión del plan: el kernel

El plan decía "el driver necesita Linux 7.3; en 6.12 hacen falta ~6-10 shims". Medido
hoy compilando la rama contra **6.12.117** (el kernel que ya arranca en la tableta), con
`make -k M=… modules`:

- `kzalloc_obj()` y `pcim_iomap_region()` **sí existen** en 6.12.117 (`slab.h:978`,
  `pci.h:2338`), y `drm_sched_job_init()` ya tiene los 5 argumentos. El plan se
  equivocaba en esas tres.
- Compilan limpios `pvrsgx_ccb.c`, `pvrsgx_core.c`, `pvrsgx_device.c` y `pvrsgx_drv.c`
  — los tres últimos incluyen lo que he tocado (tabla, `sdev->part`, sonda PCI).
- Lo que falta, completo (ficheros que **no** he tocado):

| Fichero | Qué falta | Tipo |
|---|---|---|
| `pvrsgx_dump.c:137` | `field_get()` | helper nuevo de bitfields |
| `pvrsgx_fw.c:492` | `field_prep()` | helper nuevo de bitfields |
| `pvrsgx_job.c:336-339` | `drm_sched_start()` con un argumento más y `DRM_GPU_SCHED_STAT_RESET` | API nueva |
| `pvrsgx_validate.c:173,177` | `drm_gem_shmem_vmap_locked()` / `_vunmap_locked()` | renombres |
| `pvrsgx_vm.c:434` | `drm_gpuvm_bo_obtain_locked()` | renombre (`drm_gpuvm_bo_obtain`) |

Es decir: **cinco sitios, no una capa de compatibilidad**, y ninguno en el código de
plataforma. Eso abre una opción que el plan no contemplaba: probar F1 (driver enlazado +
microkernel) sobre el 6.12.117 que ya arranca, con esos cinco arreglos locales, sin
esperar a un 7.3 i386. No lo he hecho: son cambios funcionales (semántica de locks y de
`drm_sched_start`) y merecen su propia sesión y revisión. Queda anotado como opción B,
medida.

---

## 4. Verificación hecha (y la que no)

| Comprobación | Resultado |
|---|---|
| `checkpatch.pl` sobre el diff completo | **0 errores, 0 warnings**, 358 líneas |
| `pvrsgx_core.c` compilado contra 6.12.117 | OK, sin warnings (con `-Werror` del kernel) |
| `pvrsgx_drv.c` + `pvrsgx_pm.c` compilados contra 6.12.117 | OK, sin warnings |
| Módulo completo contra 6.12.117 | Falla en 5 sitios de arriba, ninguno mío |
| Módulo completo contra 7.3 | **No**: no hay árbol 7.3 en el host y no se descarga/compila |
| KUnit `powervr_sgx_core` | **No ejecutado**: necesita kernel con KUnit; los casos nuevos están escritos y compilan |
| `sgx-ident` | Compilado, `make check` y pruebas de los caminos de error |
| `sgx-ident` en la tableta | **No**: no se ha tocado la tableta |

Nada de esto demuestra que la SGX545 de esta tableta arranque. Demuestra que el código de
plataforma es coherente y que la primera medición está lista para hacerse.

---

## 5. Qué medir en hardware, y en qué orden

Recuperación preparada de antemano: USB con el kernel 6.12.117 + initramfs conocido;
arrancar kernels nuevos por USB/RAM, nunca flashear; si se cuelga, pulsación larga de 10 s.

| # | Paso | Comando | Éxito | Si falla |
|---|---|---|---|---|
| 0 | Nada | `sgx-ident --dry-run` | `pci 0000:00:02.0: vendor 8086 device 08cf, BAR 0 0xff200000` y las 8 direcciones | si el BAR no es `0xff200000`, parar y revisar el `_CRS`/DSDT |
| 1 | Ventana | `sgx-ident` | `CORE_ID 0x0115xxxx`, `CORE_REVISION 0x000100xx` | `0`/`0xffffffff` → la ventana no está en +0x80000 **o** la isla está apagada. Paso 1b |
| 1b | Isla (sin MMIO de GPU) | `setpci -s 00:00.0 0xd0.l=0x10047af0; setpci -s 00:00.0 0xd4.l` y lo mismo con `0x100478f0` → bases APM/OSPM; `APM_STS` = base+4, bits 1:0 | `00` = isla encendida | si `11` (D0I3), la isla está apagada: hay que escribir el LSS 0 del APM (fuera del alcance de esta preparación) |
| 2 | Revisión en la tabla | editar `PVRSGX_CLV_CORE_REV`, reconstruir el módulo | `dmesg`: `SGX core id 0x0115xxxx revision 0x000100xx: Intel Clover Trail (SGX545 1.0.xx)` | si la revisión no es 1000d/1000e, revisar erratas antes de seguir |
| 3 | Microkernel | cargar `powervr_sgx`, firmware `sgx545_ukernel.bin` | `microkernel started`; `/sys/kernel/debug/dri/N/status` sin faults | recoger `INIT_STATUS`, `EVENT_STATUS`, faults BIF. **Es el riesgo grande** |
| 4 | Primer trabajo | `powervr_sgx_test submit-null-job`, `powervr_sgx_frame -n 1 -v`, `powervr_sgx_blit -n 10` | frames y blit correctos | palabras de estado 3D, timer a 533 MHz |
| 5 | Recuperación | `powervr_sgx_hang -n 5` | 5/5 recuperan, devcoredump por cuelgue | |
| 6 | Pantalla | `simpledrm` + kmsro: `kmscube`, `glmark2-es2-drm` | primer frame en el panel 1280x800 | ver `sgx-mesa-i386-clovertrail.md` §7 |

Guardar como evidencia: `lspci -vv -s 00:02.0`, la salida de `sgx-ident`, `dmesg`
completo del arranque, y los devcoredumps. Con eso el cambio deja de ser local y se puede
proponer al proyecto.

---

## 6. Riesgos, en orden de gravedad

1. **El microkernel no arranca** por una diferencia de stepping de Clover Trail. Mismo
   core, mismo firmware, pero es otro SoC. Sin lectura en hardware no se puede descartar.
2. **La ventana no está en +0x80000.** El offset viene de Medfield/Cedarview, no de esta
   tableta. Mitigación: `sgx-ident` lee una sola dirección y se para; prohibido barrer.
3. **Un cuelgue del bus** por una lectura desafortunada: la salida es un ciclo de
   encendido, no un ladrillo (no hay consola serie).
4. **La isla se apaga** si algo pone el dispositivo en D3: mitigado con la referencia
   permanente y sin `pci_set_power_state()`; el precio es que la tableta no duerme.
5. **IRQ 16 compartida con el display**: el handler devuelve `IRQ_NONE` si no ve
   `SW_EVENT`; si hay tormenta, arrancar sin reclamar la línea (modo polling de debug).
6. **Mesa i386 sin plataforma EGL GBM**: se detecta con `strings libEGL.so.1 | grep GBM`
   y se arregla con `-Dplatforms=…,drm` (una línea, sin ejecutar).
7. **simpledrm no aparece** (modo EFI no convertible): `# CONFIG_FB_EFI is not set`.

---

## 7. Verificado / inferido / sin hacer

| Afirmación | Estado |
|---|---|
| BAR 0 = `0xff200000`, 1 MiB; IRQ GSI 16; `8086:08cf`; CPU model 0x35 | **Verificado** (dmesg y DSDT de la tableta) |
| `GFX0._PS0/_PS3` no encienden ni apagan nada: solo escriben `GDDS` | **Verificado** (DSDT descompilado) |
| La SGX de Clover Trail es el mismo SGX545 (features, ISA, microkernel) | **Verificado** en la documentación del repo (`docs/UKERNEL.md`) |
| La ventana está en BAR 0 + `0x80000` | **Inferido** (offset de Medfield/Cedarview). Se mide en el paso 1 |
| `CORE_REVISION` de esta tableta | **Desconocido**. Placeholder `0` en la tabla |
| La isla está encendida tras el GOP | **Inferido** (display vivo). Se confirma en 1/1b |
| 533 MHz de reloj | **Inferido** de una fuente pública (notebookcheck) |
| El driver compila en i386 | **Verificado** para los ficheros de plataforma contra 6.12.117; el módulo completo no |
| El driver compila en 7.3 i386 | **No verificado** (no hay árbol 7.3 en el host) |
| Los cinco huecos de 6.12 son solo esos | **Verificado** con `make -k` en 6.12.117, sin tocar nada más |
| `sgx-ident` funciona en la tableta | **No probado**: solo con ventana y config space simulados |
| Mesa sobre simpledrm+kmsro | **Inferido** del parche `0004` del repo; no construido |
| Push a remoto | **No se ha hecho**, por indicación expresa |

---

## 8. Rutas

| Qué | Dónde |
|---|---|
| Rama | `$HOME/src/powervr_sgx`, `clovertrail` (`ecf1ef9`, `359ead6`) |
| Nota de plataforma (repo) | `docs/porting/cores/clovertrail.md` |
| Fragmento de kernel (repo) | `drm/ci/clovertrail.fragment` |
| Herramienta + binario | `~/elitepad-dev/tools/sgx-ident/{sgx-ident.c,sgx-ident,Makefile,README.md}` |
| Mesa i386: build y paquetes | `~/elitepad-dev/ref/sgx-mesa-i386-clovertrail.md` |
| Plan original | `~/elitepad-dev/ref/plan-sgx545-clovertrail.md` |
| Initramfs (3 líneas nuevas) | `~/elitepad-dev/build-initramfs.sh` |
| Restos de compilación (borrables) | `~/.hermes/cache/scratch/sgxdrv`, `~/.hermes/cache/scratch/sgx-syntax*` |
