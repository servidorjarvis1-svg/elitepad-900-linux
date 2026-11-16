# Mesa `sgx` sobre simpledrm en i386 — qué construir y qué instalar (no ejecutado)

Documento de preparación para la fase F3 del plan: GLES2 en el panel de la ElitePad
(1280x800) con el render node de `powervr_sgx` y `simpledrm` como dispositivo de
presentación. **No se ha construido nada**: los pasos están contrastados con los scripts
del repo (`mesa/build.sh`, `mesa/patches/0004`), con `docs/porting/mesa.md` §7 y con el
archivo de Debian, pero no se han ejecutado.

Etiquetas: **V** verificado leyendo el repo o el archivo de paquetes · **G** a confirmar
en la tableta.

## 1. La cadena, en una imagen

```
aplicación GLES2
  └─ libEGL (Mesa del repo, i386) ── kmsro ──┬─ render:  /dev/dri/renderD128  (powervr_sgx)
                                             └─ display: /dev/dri/card0       (simpledrm)
                                                        └─ framebuffer EFI 0x7f000000, 1280x800x32
```

- El driver gallium `sgx` no puede escanear: `bo_wrap` no está implementado en el winsys
  de `powervr_sgx` (`sgx_frame.c` responde `-ENOTSUP`), así que EGL fbdev no puede
  envolver `/dev/fb0`. **V**
- kmsro sí: se renderiza a un BO nuestro, se exporta como dma-buf y lo escanea el
  dispositivo KMS. El parche `mesa/patches/0004-kmsro-dril-sgx-render-only.patch` ya
  incluye `simpledrm` en la lista de displays y toma como render node el de un
  dispositivo PCI cuyo driver es `powervr_sgx` — que es exactamente nuestro caso
  (simpledrm es platform, la GPU es PCI 00:02.0). **V**
- El stride que impone el winsys es múltiplo de 128: 1280 × 4 = 5120 = 40 × 128. **V**
- El framebuffer que deja el firmware es 1280x800x32 con `linelength=5120` en
  `0x7f000000`, 4032 KiB (dmesg de la tableta). **V**

## 2. Kernel: lo que tiene que estar

Fragmento nuevo del repo, `drm/ci/clovertrail.fragment`:

```
CONFIG_DRM=y
CONFIG_DRM_POWERVR_SGX=m
CONFIG_DRM_SIMPLEDRM=y
CONFIG_SYSFB=y
CONFIG_SYSFB_SIMPLEFB=y
CONFIG_DRM_FBDEV_EMULATION=y
CONFIG_DEBUG_FS=y
CONFIG_FW_LOADER=y
# CONFIG_DRM_GMA500 is not set
```

`FB_EFI` puede quedarse: `sysfb_init()` crea el dispositivo `simple-framebuffer` cuando
`SYSFB_SIMPLEFB=y`, y `simpledrm` casa con ese nombre. Si `simpledrm` no aparece en
`/dev/dri`, entonces sí hay que poner `# CONFIG_FB_EFI is not set` (y se pierde `fbcon`;
por eso `DRM_FBDEV_EMULATION=y` no es opcional). **V** (código de 6.12.117)

Lo que hay que ver antes de tocar Mesa:

```sh
ls -l /dev/dri/                     # card0 (simpledrm) y renderD128 (powervr_sgx)
cat /sys/class/drm/card0/device/uevent
dmesg | grep -i -e simpledrm -e powervr_sgx
```

## 3. Host de construcción (Debian 12 bookworm, x86_64)

`mesa/build.sh` construye con **zig cc** para `x86-linux-gnu.2.36`, `cpu=i686`
(`mesa/build.sh:26-33`): **no hacen falta paquetes `:i386` ni una libc de 32 bits en el
host**. **V**

| Paquete (bookworm) | Para qué |
|---|---|
| `build-essential`, `pkg-config` | compilador del host y detección |
| `meson` (≥ 1.3), `ninja-build` | sistema de build |
| `python3-mako`, `python3-yaml` | generadores de Mesa |
| `bison`, `flex` | parser GLSL/NIR |
| `curl`, `xz-utils`, `ca-certificates` | descarga del tarball de Mesa 26.2.5 y del wrap de libdrm |
| `patch`, `perl` (`shasum`) | serie de parches y comprobación del sha256 |
| **`zig` 0.14+** — **no está en Debian**: tarball de ziglang.org descomprimido en `~/.local/zig` y en `PATH` | compilador cruzado y su libc para i386 |

Detalle que importa: `mesa/build.sh` comprueba el sha256 del tarball contra
`mesa/VERSION` y aborta si no cuadra; si hay red de por medio, el primer paso es esa
descarga.

## 4. Construcción (los comandos, sin ejecutar)

```sh
cd ~/src/powervr_sgx
./mesa/build.sh i386            # solo i386; sin argumentos hace x86_64 e i386
```

Lo que hace, en orden (`mesa/build.sh`): descarga y verifica el tarball, descomprime en
`build/mesa/mesa-26.2.5`, aplica `mesa/patches/*.patch` y `mesa/patches/pvrsrvkm/*`, copia
el overlay `mesa/src` encima, copia el uAPI (`drm/powervr_sgx/include/uapi/drm/
powervr_sgx_drm.h`) y el XML de streams, configura meson con el cross-file de zig
(`--cross-file build/mesa/i386/cross.ini`, `-Dplatforms=fbdev`,
`-Degl-native-platform=fbdev`, `-Dglx=disabled`, `-Dgallium-drivers=sgx`,
`-Dgbm=enabled`, `-Dllvm=disabled`, `-Dlibdrm` desde el wrap) y hace `ninja` +
`meson install` con `DESTDIR`.

Salida: `build/mesa/i386/install/usr/lib/` con `libEGL.so.1`, `libGLESv2.so.2`,
`libgallium-26.2.5.so`, `libgbm.so.1` y los symlinks de `dri/`. **V** (según el script)

Coste aproximado: 5–15 min en el host; el tarball son ~30 MB y el árbol compilado, cientos
de MB.

**G — lo único que puede fallar aquí y hay que mirar antes de seguir:** que la build de
i386 incluya la plataforma EGL de GBM/DRM. El script pide `-Dplatforms=fbdev`, que es lo
que usan en la placa CE5300 con EGL fbdev. Para kmsro por GBM hace falta además la
plataforma `drm`/`surfaceless`. Comprobación barata tras construir:

```sh
strings build/mesa/i386/install/usr/lib/libEGL.so.1 | grep -i -e EGL_PLATFORM_GBM -e EGL_PLATFORM_SURFACELESS
```

Si no aparecen, añadir `drm,surfaceless` a `-Dplatforms` en `mesa/build.sh` (una línea,
solo para el target i386) y reconstruir. **No se ha tocado el script**: es una decisión
para cuando se vea la salida real.

## 5. Despliegue en la tableta (Debian 12 i386)

Nada de esto está hecho. La raíz i386 de la tableta es bookworm (la misma que usa el
runtime de Minecraft, `mesa/build.sh:29`). **V**

```sh
# en el host
scp -r build/mesa/i386/install/usr/lib root@elitepad:/opt/sgx/
# en la tableta
echo /opt/sgx/lib > /etc/ld.so.conf.d/sgx.conf && ldconfig   # o LD_LIBRARY_PATH
```

`/opt/sgx/lib` tiene que ir **antes** que las libs de Debian: `libEGL.so.1` y
`libgbm.so.1` nuestras sustituyen a las de glvnd/Mesa del sistema (es lo que hace el
paquete `debian` del repo, prefijo `/opt/sgx`).

### Paquetes i386 necesarios

`dpkg --add-architecture i386 && apt update`, y luego:

| Paquete | Por qué | Tamaño |
|---|---|---|
| `libc6:i386` | glibc 2.36, la ABI contra la que zig enlaza (`x86-linux-gnu.2.36`) | ~2 MB |
| `libdrm2:i386` + `libdrm-common` | el loader y kmsro hablan con el DRM del kernel; `build.sh` trae libdrm como wrap, pero el runtime del sistema lo necesita para `drmGetDevices2` | ~120 KB |
| `libgbm1:i386` | solo si no se despliega el `libgbm.so.1` del repo; glmark2 enlaza contra él | ~50 KB |
| `libstdc++6:i386`, `libgcc-s1:i386` | glmark2 y kmscube son C++ | ~2 MB |
| `libpng16-16:i386`, `libjpeg62-turbo:i386`, `libudev1:i386` | dependencias de `glmark2-es2-drm` (según su `Depends` en el archivo) | ~600 KB |
| `glmark2-es2-drm:i386` + `glmark2-data` | banco de pruebas GLES2 sobre KMS/GBM, existe en Debian (`2023.01+dfsg-2` en bookworm) | ~2 MB |
| `kmscube:i386` | la prueba mínima de KMS+GBM+EGL; existe en Debian | ~50 KB |
| `mesa-utils-bin:i386` | `eglinfo`, `es2_info` y `es2gears_wayland`/`_x11` (no hay `es2gears` "pelado": para KMS están kmscube y glmark2). Contenido comprobado en el paquete de Debian | ~200 KB |
| `cage:i386` (0.2.0 en bookworm) o `weston:i386` | fase F4, compositor Wayland; ambos están en el archivo | ~1 MB |

`glmark2-es2-drm` enlaza `libgles2` y `libgbm1`: si nuestras libs van por delante en
`/etc/ld.so.conf.d/`, usa las del repo sin tocar el paquete. Si no, hay que instalar
`libgles2:i386` de Debian y aceptar que el benchmark mida llvmpipe — no sirve.

## 6. Pruebas, en orden

1. `eglinfo -B` → dos EGLDevices: `simpledrm` (display) y `PowerVR SGX545` (render). **G**
2. `kmscube` → primer frame en el panel (cubo girando, GLES2, sin ventanas). **G**
3. `glmark2-es2-drm --off-screen=0` → puntuación; comparar con la CE5300 solo como orden
   de magnitud (Atom de 2 núcleos in-order, 533 MHz de GPU).
4. `cage` (F4) → compositor wlroots con GLES2 sobre kmsro; dentro, `es2gears_wayland`.

## 7. Riesgos concretos de esta ruta

| Riesgo | Qué lo delata | Mitigación |
|---|---|---|
| `simpledrm` no aparece (modo EFI no convertible a simplefb) | no hay `card0` con driver `simpledrm` | `# CONFIG_FB_EFI is not set` en el fragmento |
| La build i386 no trae la plataforma EGL GBM | `eglinfo` sin `EGL_PLATFORM_GBM_KHR` | añadir `drm,surfaceless` a `-Dplatforms` |
| Importar el dumb buffer de simpledrm en la SGX falla en `AddFB`/attach | error en el primer `kmscube` | es el mismo camino PRIME que ya se ejercita en la CE5300 (gma500 `0002`); si falla, es del kernel, no de Mesa |
| `DIRTYFB` bloqueante: X se queda detrás de la cola de render | lag al mover ventanas | parche local `drm/sysfb/0001` solo para kernels de prueba (`docs/porting/kernel.md` §11) |
| Modificadores/atomic que simpledrm no acepta (compositor) | `cage` falla al crear el `gbm_surface` | Xorg + glamor como alternativa |
| 2 GB de RAM y `HIGHMEM4G`: los BO tienen que quedar bajo 4 GB | `-ENOMEM` en `CREATE_BO` | el driver ya usa `__GFP_DMA32` (`pvrsgx_device.c:329`) |

## 8. Lo que este documento no afirma

- No se ha compilado Mesa ni se ha ejecutado ninguno de los comandos.
- No se ha comprobado en hardware que simpledrm y el render node de la SGX se emparejen:
  eso depende del parche `0004` del repo, que sí lista `simpledrm`, pero que solo se ha
  probado en la placa CE5300 y en Cedarview.
- Los tamaños de paquete son orientativos; los nombres y la existencia de
  `glmark2-es2-drm` y `kmscube` están verificados contra el archivo de Debian.
