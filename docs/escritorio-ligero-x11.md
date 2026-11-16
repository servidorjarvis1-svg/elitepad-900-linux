# Escritorio ligero en X11 sobre hardware sin GL moderno

Receta verificada en una tableta Atom con framebuffer `simpledrm` (card0) y una
GPU que solo da GLES 2.0 (card1, sin salidas conectadas): Debian 13 **i386**
con **Xfce sobre X11**, autologin y Chromium como navegador, arrancando de una
imagen ext4 dentro de la partición de Windows.

## Por qué X11 y por qué la sesión empaquetada

- En trixie no existe `lxqt-wayland-session`: montar labwc + panel + escritorio a
  mano es una sesión que nadie prueba junta.
- Síntoma de esa sesión montada a mano: el compositor y el fondo funcionan, el
  panel y el escritorio se pintan **y desaparecen**, los procesos siguen vivos y
  el log no da ni un error.
- Con `WLR_RENDERER=pixman` (renderizador por software) el resultado fue el
  mismo — negro con solo el cursor —, así que el eje no era Mesa. Cuando el
  renderizador por software no cambia nada, no sigas depurando el compositor:
  pasa a la sesión X11 oficial.
- Xfce es la apuesta segura en pantallas pequeñas y táctiles: panel, menú
  Whisker y arrastre de ventanas funcionan sin tocar nada.

## Instalación

```
P="xorg xserver-xorg-input-libinput xinit dbus-x11 xfce4 xfce4-terminal \
   xfce4-whiskermenu-plugin onboard lightdm lightdm-gtk-greeter"
DEBIAN_FRONTEND=noninteractive apt-get install -y -q $P
```

- **En metapaquetes de escritorio, no uses `--no-install-recommends`.** Quita
  plugins que nadie declara como dependencia (en LXQt faltaba
  `layer-shell-qt`, y sin él el panel no entraba en el compositor) y el fallo
  aparece como "el panel no se ve", no como un error de instalación. Comprueba
  tamaño antes con `apt-get install -y --print-uris $P | awk '{s+=$3} END
  {print s/1048576" MB"}'` — un escritorio completo X11+rápido son ~120 MB.

## Cambiar el gestor de sesión

Si venías de `greetd` montado a mano, deshabilítalo: dos gestores peleando por
el mismo seat dan arranques intermitentes.

```
systemctl stop greetd; systemctl disable greetd
/usr/sbin/lightdm > /etc/X11/default-display-manager
echo /usr/sbin/lightdm > /etc/X11/default-display-manager
systemctl enable lightdm; systemctl start lightdm
```

Autologin (el equipo es de una sola persona y el teclado es táctil):
`/etc/lightdm/lightdm.conf.d/50-elitepad-lightdm.conf`

```
[Seat:*]
autologin-user=<usuario>
autologin-user-timeout=0
autologin-session=xfce
user-session=xfce
greeter-session=lightdm-gtk-greeter
```

## Xorg sobre el framebuffer correcto, sin glamor

Con dos nodos DRM (`card0` = simpledrm con el conector real, `card1` = GPU sin
salidas) el `modesetting` puede elegir mal. Fíjalo a mano y **empieza sin
glamor** (`AccelMethod none`): funciona siempre y sirve para separar un fallo
de la sesión de un fallo de la GPU. glamor es un paso posterior y necesita Mesa
con plataforma X11 (sección «Aceleración del escritorio»), no basta con el
`-Dgallium-drivers=sgx` de fbdev.

`/etc/X11/xorg.conf.d/20-elitepad-simpledrm.conf`

```
Section "Device"
    Identifier "simpledrm"
    Driver     "modesetting"
    Option     "kmsdev" "/dev/dri/card0"
    Option     "AccelMethod" "none"
EndSection
```

No es el `xorg.conf` con `Driver "fbdev"` que hay que evitar: sigue siendo
`modesetting` (con su cascada de respaldo) pero atado al nodo y sin aceleración.

Comprobación tras arrancar: `grep -E '\(EE\)|using drv|glamor' /var/log/Xorg.0.log`.
Sin líneas `(EE)`, `modesetting(0): using drv /dev/dri/card0` y
`glamor disabled`. Y que los procesos de la sesión existan:
`pgrep -ax xfwm4; pgrep -ax xfce4-panel; pgrep -ax xfdesktop`.

## Ver la pantalla sin estar delante: `xwd`, no `grim`

En Wayland, `grim` lee la imagen de vuelta por la misma pila EGL/GBM que está
en duda: cuando esa pila falla, la captura sale negra y no distingues "pantalla
negra" de "captura rota". En X11 no hay ese problema:

```
DISPLAY=:0 xwd -root -silent > /tmp/x1.xwd
scp <host>:/tmp/x1.xwd $TMPDIR/ && ffmpeg -y -i $TMPDIR/x1.xwd $TMPDIR/x1.png
```

Luego se mira el PNG con visión. Es la única forma honesta de decir "se ve el
escritorio" cuando el dueño no está delante; y para probar una app concreta,
lánzala con `DISPLAY=:0`, espera ~30 s, captura y comprueba también que sus
procesos siguen vivos (`pgrep -c <app>`) y que el log no tiene `FATAL`.

## Navegador predeterminado con flags fijos

Dos archivos: uno dice **cuál** es el navegador, el otro **cómo** se lanza.

```
printf "WebBrowser=chromium\n" > ~/.config/xfce4/helpers.rc      # Xfce
# en /etc/chromium.d/<equipo>:
export CHROMIUM_FLAGS="$CHROMIUM_FLAGS --disable-gpu-sandbox --disable-gpu --password-store=basic"
```

- `--disable-gpu-sandbox`: kernel sin `CONFIG_USER_NS`.
- `--disable-gpu`: ANGLE pide GLES 3.0; con GLES 2.0 el compositor se queda en
  software igual, pero sin los reintentos que ensucian el log.
- `--password-store=basic`: sin llavero en una sesión mínima.
- Verifica con `xdg-settings get default-web-browser` y con una captura real del
  navegador abierto.

## Teclado táctil (`onboard`) en Xfce

`apt-get install onboard` no basta: el proceso arranca y **muere en el acto**
sin teclado en pantalla. Dos causas, las dos hay que quitar:

1. **Falta el bus de accesibilidad.** Sin `at-spi2-core` instalado, el log dice
   `dbind-ERROR: AT-SPI: Couldn't connect to accessibility bus. Is
   at-spi-bus-launcher running?` y `onboard` aborta. Comprueba el paquete
   (`dpkg -l at-spi2-core` → `un`) antes de buscar otra explicación.
2. **Su entrada de autostart no lo lanza en Xfce.**
   `/etc/xdg/autostart/onboard-autostart.desktop` lleva
   `OnlyShowIn=Unity;MATE;`, así que la sesión Xfce la ignora en silencio. No
   edites el archivo del paquete: copia a `~/.config/autostart/onboard.desktop`
   con `X-XFCE-Autostart-Override=true`.

```
apt-get install -y at-spi2-core
printf "[Desktop Entry]\nType=Application\nName=Onboard\nExec=onboard\nX-XFCE-Autostart-Override=true\n" \
    > ~/.config/autostart/onboard.desktop
gsettings set org.gnome.desktop.interface toolkit-accessibility true
gsettings set org.onboard.auto-show enabled true
gsettings set org.gnome.desktop.a11y.applications screen-keyboard-enabled true
xfconf-query -c xfce4-session -p /general/StartAssistiveTechnologies -n -t bool -s true
```

- **`gsettings` desde SSH necesita el bus de la sesión**, no el de root ni el de
  la shell: `gsettings` sin `DBUS_SESSION_BUS_ADDRESS` escribe en un dconf que
  nadie lee. Sácalo del proceso de la sesión, que es el que sí lo tiene:
  `export $(tr '\0' '\n' < /proc/$(pgrep -u <usuario> -x xfce4-session)/environ |
  grep DBUS_SESSION_BUS_ADDRESS)` y añade `DISPLAY=:0`.
- Lanza una prueba a mano (`setsid onboard >/tmp/onboard.log 2>&1 &`, 4 s,
  `pgrep -ax onboard`) y lee el log antes de reiniciar la sesión: el error de
  AT-SPI aparece en el acto y ahorra un ciclo.

## Aceleración del escritorio: Mesa con plataforma X11 y glamor

El target normal de Mesa en este proyecto es **fbdev** (`-Dplatforms=fbdev
-Dglx=disabled`, sin glvnd): sirve para kiosco y mpv a pantalla completa, pero
un escritorio X11 no lo ve. Xorg y las apps necesitan la plataforma X11 con
GLX/EGL por glvnd, que el repo construye con el target `x86_64-x11` contra un
root Debian en `$X11_SYSROOT`. Para i386 es el **mismo** target con otro
multiarch: compila, enlaza y **acelera de verdad** en la tableta (glamor
inicializado sobre la GPU, escritorio y apps GL por hardware).

1. **Dev files de X11 dentro del rootfs i386**, en un chroot con `/proc`, `/sys`
   y `/dev` bindeados y `resolv.conf` copiado (sin red no hay apt; y
   `mmdebstrap` deja las listas de apt vacías, así que `apt-get update` primero):

   ```
   for m in proc sys dev; do mount --bind /$m $R/$m; done
   chroot $R apt-get update
   chroot $R apt-get install -y --no-install-recommends libx11-dev libx11-xcb-dev \
     libxext-dev libxfixes-dev libxcb1-dev libxcb-glx0-dev libxcb-dri2-0-dev \
     libxcb-dri3-dev libxcb-present-dev libxcb-sync-dev libxcb-randr0-dev \
     libxcb-shm0-dev libxcb-xfixes0-dev libxshmfence-dev libxxf86vm-dev \
     libxrandr-dev x11proto-dev libglvnd-dev
   for m in dev sys proc; do umount $R/$m; done        # desmonta o el rootfs queda enganchado
   ls $R/usr/lib/i386-linux-gnu/pkgconfig | grep -cE '^(x11|xcb|glx|egl|libglvnd)'
   ```

   Con ~19 archivos `.pc` hay de sobra. Si son cero, el `apt-get update` no
   corrió: mesa dirá que no encuentra `x11` en `Dependency "x11" not found`.

2. **Un target `i386-x11` en `mesa/build.sh`** en vez de tocar los que ya
   existen (los de fbdev deben seguir igual): añade `i386-x11` al `case` del
   target cruzado (`x86-linux-gnu.2.36`, `cpu=i686`) y haz que la rama X11 elija
   el directorio multiarch por arquitectura (`i386-linux-gnu` frente a
   `x86_64-linux-gnu`) para `pkg_config_libdir`, `-L` y `sys_root`.

   ```
   X11_SYSROOT=$HOME/elitepad-dev/debian/rootfs PATH=$HOME/opt/zig:$PATH \
       sh mesa/build.sh i386-x11
   ```

3. **Para que glamor arranque tienen que cuadrar dos cosas**: las rutas donde
   Mesa busca el driver, y que las variables lleguen al **servidor X**.

   Rutas: Xorg busca el cargador GBM en `/usr/lib/gbm` y los drivers DRI en
   `/usr/lib/dri`, no donde quedaron los nuestros. Sin esto, el Xorg.0.log solo
   dice `glamor initialization failed` y la causa está en
   `/var/log/lightdm/x-0.log`: `MESA-LOADER: failed to open dri:
   /usr/lib/gbm/dri_gbm.so: cannot open shared object file (search paths
   /usr/lib/gbm, suffix _gbm)`. Se arregla con enlaces, sin reinstalar nada:

   ```
   ln -sfn /opt/sgx/lib/gbm/dri_gbm.so /usr/lib/gbm/dri_gbm.so   # antes: mkdir -p /usr/lib/gbm
   ln -sfn /opt/sgx/lib/dri /usr/lib/dri                          # solo si no existen
   echo LIBGL_DRIVERS_PATH=/opt/sgx/lib/dri >> /etc/environment
   ```

   Entorno: **el drop-in de `lightdm.service` con `Environment=` no llega a
   Xorg.** systemd se lo pone al proceso de lightdm, y el servidor X lo lanza
   lightdm como hijo: se comprueba con
   `tr '\0' '\n' < /proc/$(pgrep -x Xorg)/environ` y la variable no está. Va en
   la orden de arranque del propio X, y así los clientes de la sesión no heredan
   un override que es solo para el servidor:

   ```
   # /etc/lightdm/lightdm.conf.d/50-elitepad-lightdm.conf   ([Seat:*])
   xserver-command=env MESA_GL_VERSION_OVERRIDE=2.1 MESA_GLSL_VERSION_OVERRIDE=120 X
   ```

   Hace falta porque glamor pide GL de escritorio 2.1 y el driver da 2.0 —le
   falta solo `EXT_texture_sRGB`—: sin el override glamor no se inicializa y el
   servidor acaba en `DRISWRAST` (pantalla negra con el cursor).

4. **Convive con la vuelta atrás**: deja `20-elitepad-simpledrm.conf`
   (`AccelMethod none`) y añade `20-elitepad-glamor.conf`. Se elige uno
   renombrando/quitando el otro, sin editar nada.

5. **Verificación honesta**: `glxinfo -B` debe decir *direct rendering: yes*,
   `Using DRI3 for screen 0` y el renderer de la GPU (no `llvmpipe`), y el log de
   Xorg tiene que nombrar `glamor` al inicializar. Antes de instalar las
   librerías nuevas, aparta las actuales (`/opt/sgx/lib` → `/opt/sgx/lib.gbm-only`)
   para que revertir sea un `mv`.

   Los dos fallos se leen en sitios distintos: si `glxinfo` responde
   `screen 0 does not appear to be DRI3 capable` y Xorg dice en su log
   `AIGLX: Screen 0 is not DRI2 capable` + `GLX: Initialized DRISWRAST`, glamor
   no se inicializó (rutas u override); si glamor sí aparece en el log y la
   pantalla sigue negra, el eje ya es otro.

   Medido en la tableta con el target `i386-x11`: `glamor X acceleration enabled
   on <GPU>`, `glxgears` a ~37 FPS y captura correcta de los tres engranajes, y
   mpv a pantalla completa con `--vo=gpu --gpu-context=x11egl` dando 480p30 con
   ~4 % de fotogramas perdidos y CPU al 46 % (en DRM directo era 1 perdido:
   dentro del escritorio cuesta algo más, pero va por hardware).

## Tareas del usuario en la sesión

- En X11 el vídeo por GPU de mpv necesita su contexto explícito: `--vo=gpu
  --gpu-context=x11egl`. Con `--gpu-context=drm` solo funciona a pantalla
  completa fuera del escritorio; dentro de la sesión, con Mesa `i386-x11`
  instalado, el contexto x11 EGL va por GPU y se mide con los contadores de mpv.

## Bloqueo de pantalla: la cuenta sin contraseña se queda fuera

El autologin entra sin credenciales, pero el bloqueador de la sesión no lo sabe:
`light-locker` (lo arrastra `xfce4-session`) o `xfce4-screensaver` tapan el
escritorio a los minutos y piden una contraseña que esa cuenta **no tiene**
(`passwd -S <usuario>` la marca `L`, bloqueada). Desde la pantalla táctil no se
puede desbloquear: hay que entrar por red.

Diagnóstico y recuperación, en este orden:

```
ssh root@<equipo> 'pgrep -af "light-locker|xfce4-screensaver"; passwd -S <usuario>'
ssh root@<equipo> 'loginctl list-sessions; loginctl unlock-session <id>'
loginctl show-session <id> -p Active -p LockedHint -p VTNr
```

- `unlock-session` puede no bastar: el greeter se queda en otro VT y la sesión
del usuario aparece `Active=no` aunque siga viva. Devuélvela a pantalla con
`loginctl activate <id>` y confirma `Active=yes` y un `VTNr` coherente con
`fgconsole`.
- Arréglalo de raíz: `apt-get purge -y light-locker` y, si existe,
`xfce4-screensaver`. El interruptor equivalente vive en `xfce4-power-manager`
(`/xfce4-power-manager/lock-screen-suspend-hibernate`), sin bloqueador no hay
nada que apagar.
- Comprobación final: dejar el equipo 15 minutos sin tocar nada y que no pida
contraseña. En una máquina que solo se maneja desde su propia pantalla, este
fallo la deja inservible aunque todo lo demás esté bien.

## Pitfalls

1. **`pkill -f "patrón"` lanzado por SSH mata la propia sesión SSH** cuando el
   patrón aparece en la línea de órdenes del shell remoto; el comando devuelve
   una salida vacía que parece un fallo del proceso. Usa `pkill -x <nombre>` o
   ancla el patrón al inicio (`pkill -f '^/usr/bin/app'`).
2. **Deja el barrido de gestores y flags de vuelta atrás a un archivo**
   (`/etc/lightdm/lightdm.conf.d/`, `/etc/X11/xorg.conf.d/`) en vez de editar el
   archivo principal: se revierte borrando un archivo, y sobrevive a
   actualizaciones del paquete.
3. **Un sistema recién ensamblado sin RTC arranca con la fecha equivocada** y
   apt rechaza las firmas del repositorio (`is not valid yet`): pon la hora a
   mano con la de la máquina de trabajo antes de instalar el escritorio.
4. **`pgrep -ax <nombre>` devuelve cero coincidencias si el nombre pasa de 15
   caracteres** y lo avisa con `un patrón que busque un nombre de proceso de más
   de 15 caracteres dará como resultado cero coincidencias`: procps compara
   contra `comm`, que está truncado a 15 (`lightdm-gtk-greeter` no casa nunca).
   Usa `pgrep -f` con la ruta o `pgrep -x` con el nombre corto.
5. **Un chequeo de proceso que devuelve vacío no siempre significa "no está
   vivo".** Antes de sacar conclusiones, distingue el proceso ausente de la
   herramienta negándose a buscar (pitfall anterior) o del comando que se mató a
   sí mismo (`pkill -f`): si el diagnóstico y el objeto del diagnóstico comparten
   patrón, el resultado vacío es del diagnóstico, no del sistema.
