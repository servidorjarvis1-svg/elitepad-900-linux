# Elegir distribución y kernel para tabletas x86 de 32 bits

Cuando el hardware necesita parches de kernel, la pregunta ya no es "qué
distribución instalo" sino **qué kernel voy a compilar y con qué base mínima lo
arranco**. Esta nota evita repetir el barrido de distros.

## Tabla de decisión (32 bits + UEFI IA32)

| Opción | ¿Sirve? | Por qué |
|---|---|---|
| Ubuntu 16.04 i386 + kernel HWE 4.15 | Solo como último recurso | Última LTS con instalador i386; kernel de 2018, sin soporte ni actualizaciones. Su instalador **no arranca en UEFI IA32** (Launchpad 1025555, *Won't Fix*): de ahí el rodeo con Wubi/`bootia32.efi` |
| Debian 12 (bookworm) i386 | **Sí, la base recomendada** | Última versión con kernel e **instalador i386 oficiales**, con `grub-efi-ia32`, `partman-efi` y `efibootmgr` en el netinst |
| Debian 13+ | **Sí para paquetes, no para instalador** | Ya no publica instalador ni kernel i386, pero los paquetes i386 siguen en el archivo: el rootfs se ensambla con `mmdebstrap --arch=i386` y el kernel lo pone el árbol propio (`debian-en-imagen-dentro-de-windows.md`) |
| Linuxium / isos "Atom" | No aplica | Solo Bay Trail y Cherry Trail, y de 64 bits |
| Alpine / antiX / MX | Posible | Arrancan en 32 bits, pero el instalador y el arranque UEFI IA32 dan más trabajo que el netinst de Debian 12 |

Regla: **la base se elige por el instalador que arranca y por el kernel que
puedes reemplazar, no por el escritorio.** Si hay que parchear drivers, se
compila un kernel propio (misma arquitectura `i386`, con los parches) y se
instala ese paquete sobre la base.

## Antes de invertir en parches: ¿alguien lo ha conseguido?

Comprobarlo cuesta cinco minutos y ahorra semanas de expectativas falsas:

- `linux-hardware.org` por el modelo exacto del chip (p. ej. `Z2760`): si no hay
  sondas, nadie ha reportado esa máquina funcionando.
- Buscar el caso gemelo en los foros (misma tableta o misma familia) y leer **en
  qué punto se quedó**, no si "dicen que va".
- Si el hilo que más se parece murió sin llegar al parámetro que tú ya has
  probado, vas por delante: no hay receta que copiar y hay que medirlo todo.

## Parámetros de kernel: los que hacen falta y los que son folclore

Verificado sobre el código (no sobre foros) para Clover Trail / Atom Z2760:

| Parámetro | Veredicto |
|---|---|
| `noefi` | **Necesario** si se cuelga justo tras `pid_max`: `efi_enter_virtual_mode()` sobre firmware IA32 buggy. No afecta a `efifb` (viene de `screen_info`/GOP) |
| `button.lid_init_state=open` | **Útil** cuando `_LID` miente. `ignore` también vale; `method` (default) publica lo que diga el firmware |
| `loglevel=4`, volcado de logs a la partición del otro sistema | **Sí**, mientras se depura |
| `earlyprintk=efi,keep` | Solo para ver los primeros segundos; luego fuera |
| `nomodeset`, `i915.modeset=0` | **Inútiles** aquí: no hay KMS que desactivar (el GMA500 del Z2760, `8086:08cf`, no está en `gma500`) |
| `idle=poll` | Solo como discriminador: saca a la CPU del reposo por completo, así que un "aguanta más" **no** prueba fallo de C-states, y quema CPU (con la tapa suspensa, bucle) |
| `intel_idle.max_cstate`, `processor.max_cstate` | **Inútiles** aquí: `intel_idle` no se engancha al modelo 0x35, no hay C-states que limitar por esa vía |
| `acpi_osi=*` | Ruido; solo si un driver concreto comprueba la OSI |
| `hpet=disable` | Solo como discriminador de una hipótesis, no como arreglo |

## Qué hardware de esta plataforma no tiene driver en ningún kernel

Barrido del árbol completo (grep, no memoria de foros):

- **Gráficos**: `8086:08cf` = PowerVR SGX545, sin driver mainline. Funciona el
  framebuffer (`efifb`/`fbdev`) sin aceleración.
- **Audio**: `sst` solo cubre Merrifield/Edison y Bay/Cherry Trail.
- **Cámaras**: los sensores OVxxxx solo existen como `ov2722` de `atomisp`, que
  es Bay/Cherry; y `atomisp` se rompió en 6.2+.
- **WiFi**: `ath6kl_sdio` sí existe (AR6004 por SDIO); el riesgo es el firmware
  `hw3.0` y la tormenta de IRQ del bus SDIO.
- **Nada nuevo se añadió entre 4.15 y 6.x** para Cloverview: las únicas
  menciones al modelo son la definición del modelo, `NONSTOP_TSC_S3`, la tabla
  TSC y `coretemp`. Un kernel nuevo **no** trae soporte de regalo; solo trae
  base moderna y mantenida sobre la que parchear.

## Suspensión en hardware sin S3

`/sys/power/mem_sleep` mostrando solo `[s2idle]` es lo **esperado**, no un
fallo: sin S3 en el FADT, `deep` no se ofrece y escribir `mem` acaba en s2idle.
El intento solo falla si el *freezer* no puede congelar tareas
(`Freezing of tasks failed ... tasks refusing to freeze`); con la raíz sobre
FUSE (`ntfs-3g` de Wubi) eso no se arregla, solo se desactiva la suspensión.
Ojo: con `idle=poll` un "s2idle" quema CPU en vez de ahorrar.
