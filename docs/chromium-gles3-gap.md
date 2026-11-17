# El hueco OpenGL ES 3.0 entre Chromium/ANGLE y el SGX545

Qué exige exactamente Chromium actual (2026) al contexto GL en Linux/X11 y Ozone,
qué de eso comprueba ANGLE y con qué condición de código, qué dice la
documentación del driver abierto (`docs/GL3.md`, `COMPILER-GL3.md`, `TEX.md`,
`STATE.md`, `PIGLIT.md`, rama `clovertrail-v0.2` = `origin/dev` para `GL3.md`,
sin diferencias) del SGX545 para cada pieza, y cuál es el camino más corto hasta
que la tableta tenga aceleración otra vez.

Medido en la tableta: Chromium 150 → *"ES version fallback is disabled"*, ANGLE
con backend GL no crea contexto sobre GL 2.1, `MESA_GLES_VERSION_OVERRIDE=3.0` no
lo engaña, todo por software. Este documento explica por qué, y qué habría que
tocar — y qué **no** hace falta tocar.

---

## 0. Estado (2026-11-17)

- Con `MESA_GLES_VERSION_OVERRIDE=3.0` y `--use-angle=gles`, Chromium 150 **arranca
  el proceso GPU y pinta en hardware**: WebGL por GPU, CSS 13,2 FPS (software 8,3).
- Lo que lo hizo posible, en orden: `gl_VertexID` (PR #20), offsets enteros en los
  uniforms indexados (PR #19), **vertex texture fetch real** (PR #21: los programas
  de Skia ya no fallan por `MAX_VERTEX_TEXTURE_IMAGE_UNITS(0)`), y un experimento
  local con render a sRGB (todavía en lineal) y profundidad D32F/D32F_S8.
- La composición lenta (~1 FPS) no era la GPU sino el vblank falso de `simpledrm`:
  arreglado con el parche de kernel 0010.
- Tarde del 2026-11-17, rama [`wip/es3-formats-arrays`](https://github.com/servidorjarvis1-svg/powervr_sgx/tree/wip/es3-formats-arrays)
  (local, sin PR): sRGB codificado de verdad (blend en lineal en el programa), los
  formatos de ES 3.0 (texture LOD en fragmento, D32F/D32F_S8, float 32F/16F,
  11F11F10F, RGB9E5, RGB10A2, snorm) y texturas array 2D. Medido con glxinfo: de las
  condiciones de `compute_version_es2` **solo falta `EXT_transform_feedback`**
  (hipótesis H4 de `GL3.md`, sin probar en hardware). Detalle y sondas:
  `results/es3-srgb-formats-arrays-2026-11-17.txt`.
- Falta para que sea usable de verdad: transform feedback (para quitar el override),
  mipmaps en texturas float (hoy planos F32 de un nivel) y dEQP-GLES3.

## 1. Resumen en cinco frases

1. Chromium **exige un contexto OpenGL ES ≥ 3.0** para arrancar el proceso GPU:
   ya no hay caída a ES2, y sin proceso GPU no hay composición ni WebGL
   acelerados (todo SwiftShader/software).
2. El requisito no es "GLES 3.0 conforme", es **que el driver diga que es
   GLES 3.0** (`glGetString(GL_VERSION)`) y que las consultas de capacidades no
   contradigan esa versión. Casi todas las puertas de ANGLE son
   `isAtLeastGLES(3,0)`, no una lista de features del hardware.
3. Por eso el trabajo real no está en ANGLE sino en **Mesa**: `compute_version_es2`
   exige 24 condiciones (extensiones + `MaxColorAttachments >= 4`) para escribir
   "OpenGL ES 3.0". Hoy el driver declara `essl_feature_level = 100` y no cumple
   varias.
4. Los dos caminos de ANGLE no son equivalentes: **`angle=gles` (ES nativo) pide
   ES 3.0**; **`angle=gl` (GL de escritorio) pide GL ≥ 3.2** (`renderergl_utils.cpp`:
   *"Desktop GL below 3.2 is not supported"* → versión 0.0). El objetivo GL 3.1
   del upstream **no sirve** para ANGLE por la vía de escritorio.
5. Lo que el upstream marca como el eslabón más débil (occlusion queries, H5) y
   el MRT real (H1) **no son puertas de ANGLE para ES 3.0**: el MRT emulado
   pasada-por-buffer ya da `GL_MAX_DRAW_BUFFERS = 4`, y las occlusion queries no
   las pide ni ANGLE ni Mesa para ES3. El camino crítico es otro: **texturas
   array, transform feedback y los formatos "raros"** (float/entero/sRGB/snorm).

---

## 2. La cadena exacta que decide (y dónde se corta)

### 2.1 Chromium: `allow_es_version_fallback = false`

`gpu/config/gpu_info_collector.cc` — la **recolección de información de GPU**, que
ocurre antes que todo lo demás:

```cc
scoped_refptr<gl::GLContext> InitializeGLContext(gl::GLSurface* surface) {
  gl::GLContextAttribs attribs;
  attribs.allow_es_version_fallback = false;      // <-- incondicional
  scoped_refptr<gl::GLContext> context(
      gl::init::CreateGLContext(nullptr, surface, attribs));
  if (!context.get()) { LOG(ERROR) << "gl::init::CreateGLContext failed"; ... }
```

Los valores por defecto de `gl::GLContextAttribs` (`ui/gl/gl_context.h`) son
`client_major_es_version = 3`, `client_minor_es_version = 0`,
`allow_es_version_fallback = true`; el recolector es quien apaga la caída.

Y en `ui/gl/gl_context_egl.cc` los dos sitios donde se ve el mensaje:

```cc
    // If the requested context is ES3 but the config cannot support ES3,
    // request ES2 instead.
    if ((config_renderable_type & EGL_OPENGL_ES3_BIT) == 0 &&
        context_client_major_version >= 3) {
      if (attribs.allow_es_version_fallback) { ... = 2; ... }
      else { LOG(ERROR) << "GLES3 is unsupported and ES version fallback is disabled";
             return false; }
    }
...
  } else if (!attribs.allow_es_version_fallback) {
    LOG(ERROR) << "eglCreateContext ES " << ... << ". ES version fallback is disabled.";
    return false;
  }
```

Con el contexto nulo, `viz_main_impl.cc` hace *"Exiting GPU process due to errors
during initialization"* — exactamente el log de la tableta y el de los reportes de
2026 en otras plataformas.

**Cuándo desapareció el ES2.** El interruptor era la feature
`kFallbackToSWIfGLES3NotSupported`, y su función
`ShouldFallbackToSWIfGLES3NotSupported()` tenía esta forma:

```cc
bool ShouldFallbackToSWIfGLES3NotSupported() {
#if BUILDFLAG(IS_WIN) || BUILDFLAG(IS_CHROMEOS)
  return base::FeatureList::IsEnabled(kFallbackToSWIfGLES3NotSupported);
#else   // <-- Linux, macOS, etc.
  return true;
#endif
}
```

y los dos sitios hacían `attribs.allow_es_version_fallback = !ShouldFallback...()`.
En Linux eso ya valía `false` **antes** del cambio: en Linux la caída a ES2 estaba
cerrada desde que existe la feature. El CL
[8461946](https://chromium-review.googlesource.com/c/chromium/src/+/8461946)
(`1677f13a`, *"Deprecate expired fallback-to-sw-if-gles3-not-supported"*,
25-sep-2026, `main@{#1705085}`) sólo borró la feature, el flag de `about:flags`
(`expiry_milestone: 155`) y la rama de Windows/ChromeOS, dejando `= false`
incondicional en `gpu_info_collector.cc` y en
`gpu/command_buffer/service/service_utils.cc`. Conclusión práctica: **no hay
ventana temporal que recuperar**; en Linux el ES2 lleva cerrado desde antes de
Chromium 150, y el flag del CL ya no existiría en 155+.

Tampoco queda atajo por la vía "GL de escritorio directo": en
`ui/gl/gl_implementation.cc` sólo existen `egl-angle` + (`opengl`, `opengles`,
`vulkan`, `null`, `swiftshader`, `metal`, `d3d11`); no hay OSMesa ni
`kGLImplementationDesktopGL`. **Todo pasa por ANGLE.** Y `--disable-es3-gl-context`
no aparece en `ui/gl/gl_switches.cc` (sólo en comentarios que mencionan ES3), así
que hoy es un no-op: coincide con la medición en la tableta.

### 2.2 ANGLE: el techo de versión sale de las capacidades, no del string

- `src/libANGLE/validationEGL.cpp` (~línea 3066): al crear contexto, si el config
  no tiene `EGL_OPENGL_ES3_BIT` → `EGL_BAD_MATCH "Invalid config, need
  EGL_OPENGL_ES3_BIT"`; y si
  `display->getMaxSupportedESVersion() < requested` → `EGL_BAD_MATCH "Requested
  GLES version (3.0) is greater than max supported (2.0)"`.
- `DisplayGL::getMaxConformantESVersion()` = `min(getMaxSupportedESVersion(), 3.0)`
  (`src/libANGLE/renderer/gl/DisplayGL.cpp`).
- `RendererGL::getMaxSupportedESVersion()` → `nativegl::GenerateCaps(...)`
  (`src/libANGLE/renderer/gl/RendererGL.cpp`), es decir
  `src/libANGLE/renderer/gl/renderergl_utils.cpp`, `GenerateCaps()`.
- `FunctionsGL::initialize` (`.../gl/FunctionsGL.cpp`, líneas 24-40 y 148) parsea
  `glGetString(GL_VERSION)`; `isAtLeastGLES(v)` = "el string dice OpenGL ES" **y**
  versión ≥ v. De ahí que `isAtLeastGLES(3,0)` valga lo mismo que "Mesa dice ES
  3.0".

`GenerateCaps()` empieza así:

```cc
    // Start by assuming ES3.1 support and work down
    *maxSupportedESVersion = gl::Version(3, 1);

    // Desktop GL below 3.2 is not supported
    if (functions->standard == STANDARD_GL_DESKTOP && !functions->isAtLeastGL(gl::Version(3, 2)))
        LimitVersion(maxSupportedESVersion, gl::Version(0, 0));
```

Es decir: **con `angle=gl` y GL de escritorio < 3.2 ANGLE no da ni ES2**. Nuestro
GL 2.1 actual (y el objetivo 3.1 del upstream) quedan fuera por definición. La
vía viable es **`--use-angle=gles`** con un driver que reporte *OpenGL ES 3.0*.

Eso no es un detalle: el backend por defecto de ANGLE en Linux es el GL de
escritorio, no el ES. `src/libANGLE/Display.cpp:506-512`:

```cc
#elif defined(ANGLE_ENABLE_OPENGL)
#    if defined(ANGLE_PLATFORM_ANDROID) || defined(ANGLE_USE_GBM)
    return EGL_PLATFORM_ANGLE_TYPE_OPENGLES_ANGLE;
#    else
    return EGL_PLATFORM_ANGLE_TYPE_OPENGL_ANGLE;      // Linux/X11: GL de escritorio
```

Chromium pide `ANGLEImplementation::kDefault` cuando no se pasa `--use-angle`, y
`kDefault` se resuelve dentro de ANGLE a ese valor. Es decir: **la tableta estaba
atacando el camino caro (GL ≥ 3.2) sin haber probado el barato (ES ≥ 3.0)**.


### 2.3 Por qué `MESA_GLES_VERSION_OVERRIDE=3.0` no engaña a nadie

`src/mesa/main/version.c` aplica el override en `_mesa_override_gl_version()`,
es decir **al construir el contexto**, y `_mesa_get_version(API_OPENGLES2)` sigue
devolviendo lo que diga `compute_version_es2()`. Mesa sólo ofrece configs con
`EGL_OPENGL_ES3_BIT` y sólo acepta `EGL_CONTEXT_MAJOR_VERSION = 3` cuando el
conjunto de extensiones da ES3; el override no añade extensiones ni capacidades.
Y aunque el string cambiara, `GenerateCaps` no se cree sólo el string: consulta
`GL_MAX_3D_TEXTURE_SIZE`, `GL_MAX_ARRAY_TEXTURE_LAYERS`,
`GL_MAX_VERTEX_OUTPUT_COMPONENTS`, `GL_MAX_SAMPLES`, y por formato
`glGetInternalformativ(GL_SAMPLES)` (`GenerateTextureFormatCaps`). Eso es
literalmente "mira capacidades", como se midió.

---

## 3. Matriz 1 — Puertas de ANGLE para conceder ES 3.0

Todas están en `renderergl_utils.cpp` / `GenerateCaps` salvo donde se indique.
"Limita" = a qué versión baja si la condición falla. En un driver que se declara
*GLES 3.0* **todas pasan de golpe** (la condición es `isAtLeastGLES(3,0)`); en un
driver ES2 fallan todas y el techo queda en 2.0 (o 0.0).

| # | Puerta | Condición exacta en ANGLE | Si falla | Estado SGX545 hoy | Fuente |
|---|---|---|---|---|---|
| 1 | Versión del host | `STANDARD_GL_ES` y `version ≥ 3.0`; escritorio exige `≥ 3.2` | 2.0 / **0.0** | Mesa dice ES 2.0 (`essl_feature_level = 100`) | `renderergl_utils.cpp:803+`, `FunctionsGL.cpp:148`, `sgx_screen.c` |
| 2 | Texturas 3D | `GL_MAX_3D_TEXTURE_SIZE`, ES3 core u `OES_texture_3D` | 2.0 | Sólo 1 nivel 3D (`max_texture_3d_levels = 1`); layout de volumen no es del driver; el DDK GL *sí* lista `EXT_texture3D` → hay camino de hardware | `sgx_screen.c:215`, `TEX.md §14`, `PIGLIT.md` |
| 3 | Texturas array | `GL_MAX_ARRAY_TEXTURE_LAYERS`, ES3 o `EXT_texture_array` | 2.0 | **No hay array targets** (`is_format_supported` rechaza `PIPE_TEXTURE_2D_ARRAY`); sin campo de capa en T0-T3 → path "una textura por capa + `smp` dependiente" | `TEX.md §5`, `GL3.md` fila texture arrays |
| 4 | LOD bias | `GL_MAX_TEXTURE_LOD_BIAS` | 2.0 | El cap existe (16) pero el bias no se aplica (fallo conocido en piglit) | `sgx_screen.c`, `GL3.md` "Status" |
| 5 | Draw buffers | `GL_MAX_DRAW_BUFFERS` (o `ARB_draw_buffers`) | 2.0 | 4, por la emulación pasada-por-buffer (`max_render_targets = 4`) | `GL3.md` run 19, `sgx_screen.c` |
| 6 | Texel offset | `GL_MIN/MAX_PROGRAM_TEXEL_OFFSET` | 2.0 | `smp` con offset en el compilador (`sgx_lower_tex`); límite no medido | `COMPILER-GL3.md` |
| 7 | UBO | `SupportsUniformBufferObjects` (`GL_MAX_*_UNIFORM_BLOCKS`) | 2.0 | **Sí, en hardware** vía `ld.a.d` desde `SGX_K_UBO+n`; hoy detrás de `SGX_DEBUG=ubo,glsl130`; 315/316 tests de piglit bajo override GL3.1 | `GL3.md` "Uniform blocks", `COMPILER-GL3.md` |
| 8 | Sync | `GL_MAX_SERVER_WAIT_TIMEOUT` | 2.0 | Fences sobre la finalización de un kick (`ARB_sync`) | `GL3.md` GL 3.2 tabla |
| 9 | Varyings | `GL_MAX_VARYING_COMPONENTS` y `GL_MAX_VERTEX_OUTPUT_COMPONENTS` / `..._FRAGMENT_INPUT_COMPONENTS` | 2.0 | 10 juegos de coordenadas en el SGX545; `max_tex_indirections = 8`. El valor exacto no llega a los 64 de ES3: **no lo comprueba ANGLE**, lo notará dEQP | `sgx_screen.c:139`, `ISA.md` |
| 10 | Transform feedback | `GL_MAX_TRANSFORM_FEEDBACK_*` + `CanMapBufferForRead()` | 2.0 | **Desconocido (H4)**: no hay unidad de stream-out; path `st` desde un vertex program, o el módulo `draw` en CPU | `GL3.md` fila transform feedback / H4 |
| 11 | MSAA | `GL_MAX_SAMPLES` **y**, por cada formato de renderbuffer requerido por ES3 no entero, `sampleCounts.getMaxSamples() >= 4` (`GenerateTextureFormatCaps`) | 2.0 | 4× real en hardware (PBE resuelve 2×2); el driver sólo lo da para RT/DS 2D y no expone RGB565/RGBA4/etc., que quedan fuera del chequeo por no ser renderables | `renderergl_utils.cpp` `GenerateTextureFormatCaps`, `GL3.md` "MAX_SAMPLES ≥ 4", `formatutils.cpp:421` |
| 12 | Sampler objects | `SupportsSamplerObjects` | 2.0 | st/galega genérico; sin trabajo de driver | `GL3.md` |
| 13 | Texture swizzle | `GL 3.3` / `ARB_texture_swizzle` / ES3 | 2.0 | **Sí**: swizzle de sampler view en el fragment shader | `sgx_screen.c` (`texture_swizzle = true`) |
| 14 | Builtins de empaquetado GLSL | `packHalf2x16`, `unpackUnorm4x8`, … (GL 4.2 / `ARB_shading_language_packing` / ES3) | 2.0 | ALU entera y `pck.f32.s16/u16` en hardware; conversión f16 existe (F16 del DDK) | `COMPILER-GL3.md` tabla GLSL |
| 15 | `layout(location=)` | `GL 3.3` / `ARB_explicit_attrib_location` / ES3 | 2.0 | NIR resuelve las localizaciones explícitas; el driver mapea por índice | `GL3.md` "Order of work" |
| 16 | `highp` en fragment | `PrecisionMeetsSpecForHighpFloat(fragmentHighpFloat)` | **0.0** | F32 en el fragment shader | `COMPILER-GL3.md` |
| 17 | Base ES2 | FBO/renderbuffer, atributos, uniforms, unidades de textura | **0.0** | Todo presente (dEQP-GLES2: 78 F / 16 638 P) | `GL3.md` "Status" |

**Lección de la tabla:** ninguna puerta pide una capacidad que el SGX545 no tenga
ya documentada; y 11 de 17 son "el driver se declara ES3". Las tres que sí piden
trabajo de verdad son **array textures (#3)**, **transform feedback (#10)** y
**formatos de renderbuffer con 4 samples (#11)**.

---

## 4. Matriz 2 — Puertas de *Mesa* para escribir "OpenGL ES 3.0"

Ésta es la lista que manda, porque `compute_version_es2` decide el string y el
string decide todo lo anterior. Fuente: `src/mesa/main/version.c` de **Mesa
26.2.5** (el del árbol local, `build/mesa/mesa-26.2.5`), líneas 478-511.

`ver_3_0 =` las 24 condiciones siguientes **y** `MaxColorAttachments >= 4`:

| Extensión que Mesa exige | Qué es en ES3 | Estado en el driver sgx (docs upstream) | Confianza | Trabajo |
|---|---|---|---|---|
| `ARB_half_float_vertex` | atributos half | El draw recolecta en CPU y convierte | **alta** | gratis |
| `ARB_map_buffer_range` | `glMapBufferRange` | gallium genérico | **alta** | gratis |
| `ARB_texture_non_power_of_two` | NPOT | `npot_textures = true` | **alta** | gratis |
| `EXT_blend_equation_separate` | blend por canal | blending es shader code | **alta** | gratis |
| `ARB_texture_rg` | R8/RG8/R32F… | R8/RG8 como L8/LA88 con swizzle; float por `0x12` | **alta** (8 bits) / media (float) | chico |
| `ARB_framebuffer_object` | FBO | `mixed_framebuffer_sizes` encendido | **alta** | gratis |
| `ARB_draw_instanced`, `ARB_instanced_arrays` | instancing | un draw por instancia, `gl_InstanceID` por constante | **alta** | gratis |
| `NV_primitive_restart` / `PrimitiveRestartFixedIndex` | restart | split en CPU | **alta** | gratis |
| `MaxColorAttachments >= 4` | MRT | 4 por pasada-por-buffer (no MRT real) | **alta** (emulado) | gratis |
| `ARB_uniform_buffer_object` | UBO | hardware `ld.a.d`; hoy tras `SGX_DEBUG=ubo` | **alta** | encender |
| `ARB_shader_texture_lod` | `textureLod`/`Grad` | `smp` con `.lod`/`.grad` | media | compilador |
| `ARB_internalformat_query` | `glGetInternalformativ` | No implementado (`screen->query_internal_format`) | media | chico |
| `EXT_texture_sRGB` | muestrear sRGB | Sí (es lo que da GL 2.1 hoy, según PIGLIT.md) | **alta** | gratis |
| `EXT_sRGB` (ES) | renderbuffer sRGB8_A8 | Se decodifica/codifica en el shader; no hay formato TPU/PBE sRGB | **alta** (shader) | chico |
| `EXT_texture_snorm` | formatos snorm | muestrear unorm y convertir `2x-1` en el shader | **alta** | chico |
| `EXT_texture_type_2_10_10_10_REV` | RGB10_A2 | `0x0e` devuelve RGB10_A2 desplegado; render empaquetando | **alta** | chico |
| `OES_texture_float` | R32F/RGBA32F/RGBA16F | `0x12` devuelve el word crudo (H2: 7/7 exacto) | **alta** (R32F) | chico |
| `OES_texture_half_float`, `..._half_float_linear` | F16 | No hay código de sampler F16 en el barrido 0x00-0x1f; el DDK los tiene (`lf16`, `rgbaf16`) | media | captura + conversión |
| `EXT_packed_float` (R11G11B10F) | formato empaquetado | Sin código de sampler; desplegar en el shader (`nir_format_unpack_11f11f10f`) | media | chico |
| `EXT_texture_shared_exponent` (RGB9E5) | idem | Idem (`nir_format_unpack_rgb9e5`) | media | chico |
| `ARB_depth_buffer_float` | D32F / D32F_S8 | Precisión F32 interna del ISP es **conjetura**; store/load va por ZLS (H9 pasó) | media | medio |
| `OES_depth_texture_cube_map` | muestrear profundidad en cubo | No hay formato de profundidad muestreable en cubo; `sgx_tex_format` sólo tiene 5 códigos 8-bit | baja/media | medio |
| `EXT_texture_array` | **texturas array** | Sin campo de capa en T0-T3 → una textura por capa + `smp` dependiente | media | **grande** |
| `EXT_transform_feedback` | **stream out** | Sin unidad conocida; `st` desde vertex program (H4) o `draw` en CPU | media/baja | **grande** |

(En `main` la lista ha crecido con `OES_depth_texture_cube_map`,
`EXT_texture_type_2_10_10_10_REV` y `MaxColorAttachments >= 4`; en 26.2.5 ya
están. `ARB_texture_non_power_of_two` se movió a `ver_2_0`.)

### El detalle del MSAA que muerde

`GenerateTextureFormatCaps()` baja la versión si **algún** formato de renderbuffer
requerido por ES 3.0 y no entero tiene menos de 4 samples:

```cc
    if (textureCaps.renderbuffer && !glFormatInfo.isInt() &&
        glFormatInfo.isRequiredRenderbufferFormat(gl::Version(3, 0)) &&
        textureCaps.sampleCounts.getMaxSamples() < 4)
        LimitVersion(maxSupportedESVersion, gl::Version(2, 0));
```

`isRequiredRenderbufferFormat(ES3)` (`src/libANGLE/formatutils.cpp:421`) incluye
D16, D24, D32F, D24S8, D32FS8, S8, **todos los UNORM salvo SRGB8** (R8, RG8,
RGB8, RGBA8, RGBA4, RGB5_A1, RGB565, RGB10_A2, SRGB8_ALPHA8, …) y todos los
enteros R/RG/RGBA (los enteros quedan exentos del chequeo de samples). Es el
mismo mecanismo que tumbó a virgl en el issue de UTM: *"ANGLE's GL backend lowers
the maximum to ES 2.0 when a required renderbuffer format supports fewer than 4
samples"*.

Consecuencia útil: **el chequeo sólo mira los formatos que el driver declara
renderables**. Ocultar RGB565/RGBA4/RGB5_A1/RGB10_A2 como render targets (hoy ya
es el caso) evita tener que darles 4×; los que sí se declaran (RGBA8, R8, RG8,
D16, D24, D24S8) ya aceptan 4 en `sgx_is_format_supported`, y `MaxSamples` de st
se calcula sondeando exactamente esos formatos. Es decir: **en el driver actual
esta puerta probablemente ya pasa**; el techo de 2.0 viene del string de versión
(ES2), no del MSAA. Merece una medición antes de tocar nada (§7).

---

## 5. Matriz 3 — ES3 que ANGLE **no** comprueba (y que igual hará falta)

Esto es lo que separa "Chromium arranca acelerado" de "WebGL2 no se rompe" y de
"dEQP-GLES3 pasa". Ninguna de estas filas está en las matrices 1 ni 2:

| Función ES 3.0 | ¿Puerta de ANGLE/Mesa? | Estado SGX545 | Confianza | Fuente |
|---|---|---|---|---|
| Occlusion queries (`ANY_SAMPLES_PASSED`) | **no** | **H5: sin camino conocido** (sólo listado en el ICD y el DDK GL); se puede falsear con un store bajo un pass translúcido | **baja** | `GL3.md` H5 |
| Conditional render | no | depende de queries; sin ellas se puede hacer en CPU (`render_condition`) | baja | `GL3.md` |
| Vertex texture fetch (16 unidades) | no | `smp` en vertex program existe (corpus), el driver no tiene sampler views de vértice | media | `GL3.md` GL 3.1 |
| Texture buffer objects | no | textura 1D lineal + `texelFetch` por `ld` | media | `GL3.md` |
| Integer textures / render targets | indirecta (vía `EXT_texture_integer`, no en la lista de Mesa) | ≤32 bits: `sgx_inttex` pasa todo; planes R32 para RG32/RGBA32 | **alta** | `GL3.md` run 14 |
| Float render targets > 32 bits | no | requiere H1 (dos outputs por píxel); ≤32 bits por empaquetado en shader | media | `GL3.md` |
| `gl_FragDepth` | no | Se escribe ya (`depthf`, tipo 5) | **alta** | `GL3.md` runs 4-5 |
| Varyings planos (`flat`) | no (pero sí para dEQP) | Sólo el color source itera plano; el resto por replicación del provoking vertex | media | `GL3.md` "Flat varyings" |
| 8 clip distances | no | 6 planos en el TA; 7-8 a `discard` | **alta** | `GL3.md` |
| MRT real (o1, o2…) | no (basta `GL_MAX_DRAW_BUFFERS`) | **H1**: un segundo emit del end-of-tile cuelga la GPU; el fallback pasada-por-buffer funciona | media | `GL3.md` H1/run 19 |
| MSAA con FBO + resolve | no (basta `GL_MAX_SAMPLES`) | 4× en hardware; resolve por blit como copias; MSAA FBO capturado sólo en parte (H6) | media | `GL3.md` |
| `ARB_texture_multisample` (tex MS) | no | requiere layout ZLS por sample | media | `GL3.md` |
| Geometry shaders, seamless cube, depth clamp | no | 3.2, no planificado | — | `GL3.md` "Verdict" |

Lo importante: **el veredicto del upstream ("occlusion queries son el eslabón más
débil") es del objetivo GL 3.0 de escritorio, no del objetivo Chromium.** Para
Chromium/WebGL2 no hacen falta H1, H5, ni H6 completo.

---

## 6. El camino mínimo

### Fase 0 — medir (cero líneas de código)

1. `--use-angle=gles` explícito (hoy va por `angle=gl` → 0.0 por GL < 3.2).
2. `--enable-logging=stderr --v=1` y buscar en el log: *"Invalid config, need
   EGL_OPENGL_ES3_BIT"* / *"Requested GLES version (3.0) is greater than max
   supported (2.0)"* / *"GLES3 is unsupported and ES version fallback is
   disabled"*. Las tres frases dicen en qué eslabón se corta.
3. En la tableta, sin Chromium: `eglinfo -B` / `es2_info` para ver si las configs
   EGL llevan `EGL_OPENGL_ES3_BIT` (no) y qué dan `GL_MAX_SAMPLES`,
   `GL_MAX_3D_TEXTURE_SIZE`, `GL_MAX_ARRAY_TEXTURE_LAYERS`,
   `GL_MAX_VERTEX_OUTPUT_COMPONENTS` con el driver actual. Eso convierte las
   celdas "media" de la matriz 2 en hechos.

### Fase 1 — encender lo que ya existe (días, sin hardware nuevo)

`SGX_DEBUG=ubo,glsl130` por defecto + MRT pasada-por-buffer por defecto + ESSL 300
en `caps->essl_feature_level`. Con eso el driver pasa de "ES2 estricto" a "ES2 con
todas las piezas de GL 3.1 emuladas", que es el 60 % de la lista de Mesa. Riesgo:
`native_integers` es screen-wide y hoy está atado a `glsl130` porque dEQP-GLES2
debe seguir pixel-exacto (`GL3.md`, "Crossing the driver/compiler line").

### Fase 2 — las condiciones baratas de Mesa (semanas)

`ARB_internalformat_query`, `EXT_texture_snorm`, `EXT_texture_type_2_10_10_10_REV`,
`EXT_packed_float`, `EXT_texture_shared_exponent`, `EXT_sRGB` (renderbuffer sRGB),
`OES_texture_float`/`half_float(_linear)`: todas son **almacenar en RGBA8/R32 y
deshacer en el shader**, exactamente lo que el driver ya hace para sRGB, RGTC,
R11G11B10F y los enteros. Ya está escrito en `GL3.md` ("What's emulated, in one
list"). Aquí no hay ninguna incógnita de hardware.

### Fase 3 — las dos caras (semanas/meses)

- **`EXT_texture_array`**: una textura por capa a *layer stride*, con `smp`
  dependiente para leer la capa (el estado viene de registros). Toca compilador
  (`COMPILER-GL3.md`: "texture arrays (GL3.md's layer-address path)" sigue
  pendiente) y driver. Es la pieza más grande con diferencia.
- **`EXT_transform_feedback`**: el path `st` desde un vertex program (H4, sin
  verificar) o el módulo `draw` de gallium en CPU como respaldo. El respaldo es
  correcto y lento, y es lo que hacen softpipe e i915g.

### Fase 4 — la prueba de fuego

Cuando `eglinfo` diga *OpenGL ES 3.0 Mesa …*, ANGLE debería conceder ES 3.0 en la
primera consulta (todas las puertas de la matriz 1 son `isAtLeastGLES(3,0)`), y
Chromium debería arrancar el proceso GPU. A partir de ahí, `chrome://gpu` y
`webglreport` dicen qué falta de verdad; y dEQP-GLES3 (no dEQP-GLES2) es la lista
de trabajo restante, sin relación con las puertas.

### Lo que **no** hay que hacer

- No perseguir GL 3.2 de escritorio: ANGLE pide **≥ 3.2** por esa vía y además
  `ARB_texture_swizzle` (3.3), `ARB_shader_bit_encoding` (3.2) y
  `ARB_explicit_attrib_location` (3.3). El objetivo GL 3.1 del upstream es
  irrelevante para Chromium aunque se alcance.
- No tocar H1 (MRT real) ni H5 (occlusion queries) para este objetivo.
- No buscar un "modo ES2" en Chromium: no existe desde antes de la 150, y el flag
  que quedaba se borró en `main@{#1705085}` (expiry 155).
- No confiar en `MESA_GLES_VERSION_OVERRIDE` ni en `--disable-es3-gl-context`: el
  primero no cambia capacidades ni configs EGL, el segundo ya no existe.
- Como mucho, para *medir* cuánto falta, `--enable-angle-features=` con la feature
  de pruebas que salta los caps de versión (reportada como
  `exposeES32ForTesting` en el issue de UTM). No es una vía de entrega: al saltar
  los caps, el proceso sigue y falla más tarde.

---

## 7. Incógnitas que este documento no cierra

1. Qué reporta exactamente el driver hoy para `GL_MAX_SAMPLES`,
   `GL_MAX_3D_TEXTURE_SIZE`, `GL_MAX_ARRAY_TEXTURE_LAYERS`,
   `GL_MAX_VERTEX_OUTPUT_COMPONENTS` y `GL_MAX_DRAW_BUFFERS`. Determina si la
   puerta #11 (MSAA por formato) ya pasa. **Medible en la tableta en un minuto.**
2. Cuáles de las 24 extensiones de la matriz 2 expone hoy Mesa con este driver.
   La mitad se puede leer en `st_extensions.c` con el árbol en la mano; la otra
   mitad conviene medirla (`es2_info`). Sin eso, las celdas "media" son
   inferencia, no hecho.
3. Si `ARB_internalformat_query` y `EXT_sRGB` (renderbuffer) los puede dar st con
   lo que el driver ya tiene, o necesitan trabajo de formato nuevo. Es el ítem
   más barato de verificar y desbloquea dos condiciones de Mesa.
4. El límite real de `GL_MAX_PROGRAM_TEXEL_OFFSET` y de componentes de varying del
   compilador. No son puertas de ANGLE, pero sí de dEQP.
5. Si `rt_max_samples` del kernel reporta 4 en la tableta (uAPI rev 3). Si no,
   `sgx_is_format_supported` rechaza 4 y **entonces sí** cae la puerta #11.

---

## 8. Fuentes

**Chromium**
- `gpu/config/gpu_info_collector.cc` (`allow_es_version_fallback = false`):
  https://chromium.googlesource.com/chromium/src/+/main/gpu/config/gpu_info_collector.cc
- `ui/gl/gl_context_egl.cc` (los dos mensajes "ES version fallback is disabled"):
  https://chromium.googlesource.com/chromium/src/+/main/ui/gl/gl_context_egl.cc
- `ui/gl/gl_context.h` (defaults 3.0 / fallback true):
  https://chromium.googlesource.com/chromium/src/+/main/ui/gl/gl_context.h
- `ui/gl/gl_implementation.cc` (no queda GL directo; sólo ANGLE):
  https://chromium.googlesource.com/chromium/src/+/main/ui/gl/gl_implementation.cc
- CL que borra la caída a software/ES2 (25-sep-2026, `main@{#1705085}`):
  https://chromium-review.googlesource.com/c/chromium/src/+/8461946
- `gpu/command_buffer/service/service_utils.cc` (WebGL2 pide 3.0, WebGL1 pide 2.0,
  sin fallback):
  https://chromium.googlesource.com/chromium/src/+/main/gpu/command_buffer/service/service_utils.cc

**ANGLE**
- `src/libANGLE/validationEGL.cpp` (ES3 bit + `getMaxSupportedESVersion`):
  https://chromium.googlesource.com/angle/angle/+/main/src/libANGLE/validationEGL.cpp
- `src/libANGLE/renderer/gl/renderergl_utils.cpp` (`GenerateCaps`,
  `GenerateTextureFormatCaps`):
  https://chromium.googlesource.com/angle/angle/+/main/src/libANGLE/renderer/gl/renderergl_utils.cpp
- `src/libANGLE/renderer/gl/DisplayGL.cpp` (`getMaxConformantESVersion`):
  https://chromium.googlesource.com/angle/angle/+/main/src/libANGLE/renderer/gl/DisplayGL.cpp
- `src/libANGLE/Display.cpp:506-512` (el backend por defecto en Linux es GL de
  escritorio, no ES):
  https://chromium.googlesource.com/angle/angle/+/main/src/libANGLE/Display.cpp
- `src/libANGLE/renderer/gl/FunctionsGL.cpp` (parseo de `GL_VERSION`):
  https://chromium.googlesource.com/angle/angle/+/main/src/libANGLE/renderer/gl/FunctionsGL.cpp
- `src/libANGLE/formatutils.cpp` (`isRequiredRenderbufferFormat`):
  https://chromium.googlesource.com/angle/angle/+/main/src/libANGLE/formatutils.cpp

**Mesa** (26.2.5, el del árbol; en `main` la lista es un poco más larga)
- `src/mesa/main/version.c`, `compute_version_es2`:
  https://gitlab.freedesktop.org/mesa/mesa/-/blob/main/src/mesa/main/version.c
- local: `build/mesa/mesa-26.2.5/src/mesa/main/version.c:478-511`
- `src/mesa/state_tracker/st_extensions.c` (`MaxSamples` por sondeo de formatos):
  https://gitlab.freedesktop.org/mesa/mesa/-/blob/main/src/mesa/state_tracker/st_extensions.c

**Driver abierto SGX545 (árbol local, rama `clovertrail-v0.2`)**
- `docs/GL3.md` — MRT/H1, MSAA 4×/H6, UBO, instancing, arrays, TF/H4, occlusion
  H5, sRGB, snorm, veredicto y orden de trabajo.
- `docs/COMPILER-GL3.md` — enteros, `texelFetch`, UBO (`ld.a.d`), `gl_InstanceID`,
  varyings planos, tabla de estado GLSL 1.30/1.40.
- `docs/TEX.md` §1 (formatos T1), §5 (T2 = base), §14 (volumen 3D), §15 (`0x12`).
- `docs/STATE.md` §3 (clip planes, blending como shader), §4 (PBE escribe `o0`
  crudo), "Multisampling (4x)".
- `docs/PIGLIT.md` — "First light" (GL 2.0 → 2.1 por `EXT_texture_sRGB`), "sin
  formato de profundidad muestreable", extensiones del GL de escritorio del DDK.
- `mesa/src/gallium/drivers/sgx/sgx_screen.c` — caps actuales
  (`essl_feature_level = 100`, `max_texture_3d_levels = 1`,
  `max_render_targets = 4`, `texture_swizzle`, `mixed_framebuffer_sizes`) y
  `sgx_is_format_supported` (4× sólo RT/DS 2D; sin `PIPE_TEXTURE_2D_ARRAY`).

**Reporte cruzado con la misma causa (otra plataforma, 2026)**
- UTM #8118, "ANGLE/Venus expose only GLES 2.0 to Chromium":
  https://github.com/utmapp/UTM/issues/8118
