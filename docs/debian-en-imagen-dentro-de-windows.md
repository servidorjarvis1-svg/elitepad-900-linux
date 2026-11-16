# Fase 3: sistema Debian completo en una imagen dentro de la partición de Windows

Cuando el kernel propio y los drivers ya funcionan, el último paso es un
userspace completo —escritorio, navegador, SSH, launchers— sin reparticionar ni
tocar el gestor de arranque: una **imagen ext4 dentro de `C:`** que el initramfs
monta por loop y a la que salta con `switch_root`. La entrada de arranque y el
kernel siguen siendo los del entorno de desarrollo.

Frente a instalar: no se toca la tabla de particiones ni el `bootia32.efi` del
fabricante, la vuelta atrás es borrar un archivo, y todo el trabajo pesado
(rootfs, Mesa, paquetes) se hace en el host amd64.

## 1. Ensamblar el rootfs i386 en el host

Debian 13 ya no publica instalador ni kernel i386, pero **los paquetes siguen en
el archivo**: el sistema se monta con `mmdebstrap` y el kernel lo pone el árbol
propio (`entorno-dev-kernel-i386.md`).

```sh
mmdebstrap --arch=i386 --variant=important \
    --include=systemd,systemd-sysv,openssh-server,network-manager,ntfs-3g,\
kmod,console-setup,locales,sudo,curl,chromium,mpv,cage,kmscube,glmark2,mesa-utils \
    trixie rootfs http://deb.debian.org/debian
```

- Un rootfs con escritorio mínimo y navegador ronda **1,7 GB**; sin navegador,
  ~1,5 GB. Dimensiona la imagen con eso más margen para el usuario.
- Divide el trabajo: primero el `mmdebstrap` pelado, después la personalización
  en `chroot` como script aparte. Así un fallo de personalización se repite en
  segundos en vez de costar otros cuatro minutos de descarga.
- **El `chroot` de personalización empieza por `apt-get update`.** `mmdebstrap`
  termina con `I: cleaning package lists and apt cache...` y deja
  `/var/lib/apt/lists` vacío: el primer `apt-get install` posterior falla con
  `Unable to locate package`.
- Mete dentro del rootfs lo que hace falta para entrar sin consola: usuario,
  `~/.ssh/authorized_keys` con la clave del host y política de `root`/`sudo`
  decidida. Sin eso el primer arranque bueno queda inalcanzable por red.
- Red: la Ethernet del dock (la que el propio `init` elige por tipo
  ARPHRD_ETHER) y el WiFi derivado del perfil exportado de Windows — receta en
  `SKILL.md`, sección de WiFi; la contraseña no pasa por el chat.
- Tapa: `HandleLidSwitch=ignore` dentro del rootfs
  (`/etc/systemd/logind.conf.d/`), no solo en la línea del kernel: el parámetro
  `button.lid_init_state=open` vive en la entrada de grub y se pierde al cambiar
  de kernel.

## 2. ¿Ese `root.disk` que ya está ahí tiene algo dentro?

Antes de reutilizar o pisar una imagen grande, léela sin montarla: los primeros
2048 bytes contienen el superbloque ext4. Desde el Windows que arranca:

```powershell
$f=[IO.File]::OpenRead("C:\ubuntu\disks\root.disk"); $b=New-Object byte[] 2048
[void]$f.Read($b,0,2048); $f.Close()
"magic: {0:X2}{1:X2}" -f $b[1081],$b[1080]       # 5346 = "EF" little endian
"label: " + [Text.Encoding]::ASCII.GetString($b,1144,16)
"bloques: " + [BitConverter]::ToUInt32($b,1028)  # libres en 1036
"feat_incompat: {0:X}" -f [BitConverter]::ToUInt32($b,1120)
```

Offsets del superbloque: magic 1080 (`0xEF53`), label 1144, bloques 1028,
libres 1036, `log_block_size` 1048, `feat_incompat` 1120.

- Salen `30 30` y contadores como `808464432`: la imagen **está llena de
  caracteres `'0'`** (`0x30`), no es un sistema de archivos. Es lo que deja un
  instalador tipo Wubi que nunca llegó a formatear: no hay nada que rescatar y
  el formateo es inevitable.
- Salen `53 46` y un label: hay ext4 de verdad; lee el label y monta en solo
  lectura antes de proponer borrar nada.
- **No escribas en esa imagen ni la formatees tú.** El `mkfs` es la orden
  destructiva de este trabajo: la lanza el dueño, con ruta y tamaño ya
  verificados.

## 3. Crear la imagen ya poblada, sin montar nada

`mkfs.ext4 -d` copia un árbol de directorios al formatear: no hace falta loop
mount ni root para poblarla.

```sh
truncate -s 8120172544 root.disk          # tamaño a medida de C:
sudo mkfs.ext4 -q -F -L elitepad-debian -m 1 -d rootfs root.disk
sudo e2fsck -fn root.disk                 # verifica sin escribir
```

- `-m 1` baja la reserva para root del 5 % al 1 %: en una imagen de 8 GB son
  ~300 MB que se recuperan.
- `e2fsck -fn` es la verificación barata: detecta conteos, enlaces y
  directorios incoherentes antes de subir 8 GB por la red, y con `-n` no toca
  nada. Si sale limpio y con el número de bloques que esperas, la imagen es
  buena.
- Deja ≥300 MB libres en `C:` además de la imagen: NTFS necesita aire para sus
  propios metadatos y Windows no arranca bien con el volumen al límite.

## 4. Subirla y verificar de verdad

```sh
scp root.disk home@<ip>:C:/ubuntu/disks/root.disk
```

- **Mide el ritmo, no lo estimes.** En el host, `tx_bytes` del interfaz antes y
  después (`echo $(( (b-a)/10/1024/1024 ))` MB/s). Con el dock a 100 Mbps son
  ~10 MB/s y 8 GB tardan ~13 min; sin el dato se le dice al humano una espera
  que no es.
- **MD5 en los dos extremos.** `certutil -hashfile <ruta> MD5` en Windows trae
  el digest con espacios en la **segunda línea** (`| sed -n 2p`) y sin nombre de
  archivo: normaliza ambos lados antes de comparar, o compararás un hash con
  espacios contra uno sin ellos.
- Guarda como `.bak-pre-<hito>` cualquier artefacto que vayas a pisar
  (`initramfs`, `bzImage`, `grub.cfg`) y dilo al entregar.

## 5. Cambiar de sistema con un marcador de un solo uso

El `init` del busybox monta la partición de Windows para los logs; si además
encuentra un archivo marcador (`boot-debian`), lo **borra antes de usarlo**,
monta la imagen por loop y hace `switch_root` al Debian. Con el marcador ya
consumido, un arranque fallido vuelve solo al entorno de siempre en el
siguiente reinicio, sin que nadie monte el NTFS a mano.

Reglas del enlace:

- El marcador se consume **antes** del `switch_root`, no después: si el Debian
  muere arrancando, el humano no tiene que borrar nada desde Windows.
- Volcar el log del intento a `C:\ubuntu\friday-dev\logs\debian\` desde el
  propio `init` y con `sync`: es lo único que queda si el userspace no llega a
  arrancar.
- Comprobar que el punto de montaje de la imagen tiene `/sbin/init` antes de
  saltar; un `switch_root` a medias deja el kernel sin PID 1 y sin mensaje.

## 6. Busybox: opciones cortas

El `mount` de busybox no acepta las opciones largas de util-linux: `--move` y
`--make-rprivate` fallan con `unrecognized option` y el `init` se queda a mitad
de camino sin decirlo. Usa `-o move` y `-o rprivate`. Vale para cualquier `init`
de initramfs escrito con la cabeza puesta en util-linux.

## 7. Aceleración gráfica: Mesa `sgx`

El SGX545 no tiene driver mainline. La cadena que funciona es el driver
`powervr_sgx` (módulos y firmware propios) más **Mesa con el backend `sgx`
compilado para i386**, instalado en `/opt/sgx` dentro del rootfs. EGL sale con
GBM y surfaceless.

- Compilación cruzada en el host amd64: hace falta `zig` (Debian no lo
  empaqueta; se baja de `ziglang.org` y se pone delante en el `PATH`) más las
  herramientas de compilación de `apt`.
- Compila **antes** de crear la imagen y copia el resultado dentro del rootfs:
  así un cambio de Mesa no obliga a rehacer el `mkfs` ni a resubir 8 GB.
- Prueba con `kmscube` y `glmark2` en la propia tableta, ya con sesión SSH,
  antes de montar ningún escritorio: separa "la cadena EGL funciona" de "el
  compositor está mal configurado".
- La GPU del lab no está libre para esto: el render es siempre software en la
  tableta; de lo que se ocupa Mesa `sgx` es de la aceleración del SGX545.

## 8. Kiosco y vídeo en el sistema ya instalado

Con la GPU presentando (sección 7 y `clovertrail-costes-y-veredictos.md`), los
siguientes tropiezos son de userspace y cuestan un ciclo cada uno si se
descubren a ciegas:

- **El reloj.** Una máquina sin RTC arranca con la fecha del universo y apt
  rechaza las firmas de Debian (`Release file ... is not valid yet`), que se lee
  como un problema de repositorios. Ponla a mano contra el host
  (`date -s "$(ssh <host> date)"`) e instala `systemd-timesyncd` en el mismo
  paso; si `hwclock` no encuentra nada, el kernel no trae driver de RTC y eso va
  a la lista del próximo kernel.
- **`yt-dlp` de la distro no sirve** para YouTube aunque la red funcione. Baja
  el binario oficial a `/usr/local/bin` verificando el checksum
  (`grep " yt-dlp$" SHA2-256SUMS | sha256sum -c`) y en mpv pásalo con
  `--script-opts=ytdl_hook-ytdl_path=/usr/local/bin/yt-dlp`.
- **Chromium bajo `cage` con un kernel sin `CONFIG_USER_NS`**: instala
  `chromium-sandbox` y arranca con `--disable-gpu-sandbox`; sin eso el proceso
  GPU muere con `exit_code=5` y el navegador se cierra sin decir por qué. Y no
  esperes aceleración: ANGLE exige GLES 3.0, la SGX545 da 2.0 y `chrome://gpu`
  dirá "Software only" — vale para un panel, no para vídeo.
- **Comprobar el vídeo con contadores**, no de oído:
  `mpv --vo=gpu --gpu-context=drm --gpu-api=opengl --hwdec=no --ao=null
  --term-status-msg="t=${time-pos} drop=${frame-drop-count} ..."` junto a `top`
  da fotogramas perdidos y CPU; una fuente local (`av://lavfi:testsrc2=...`)
  descarta la red como causa.

## 9. Apagar desde el sistema instalado: instrumenta el `shutdown` del initramfs

Apagar el Debian de la imagen es el punto más frágil de toda la cadena. El
cierre cuelga en el último paso (el equipo se queda muerto y Windows no
aparece), y en el siguiente arranque eso **se lee como "el kernel nuevo no
arranca"** aunque el kernel nuevo ni se haya ejecutado. Mientras no se arregle,
la única forma de saberlo es que la pantalla diga en qué paso se quedó.

Cómo funciona: `systemd-shutdown` desmonta el userspace, hace `pivot_root` a
`/run/initramfs` con el sistema viejo en `/oldroot` y **ejecuta el archivo
`shutdown`** de ese initramfs con `reboot`, `poweroff` o `halt` como argumento.
Sustituye ese script.

```sh
#!/bin/sh
/bin/busybox --install -s /bin
export PATH=/bin
mount -t proc proc /proc 2>/dev/null
mount -t devtmpfs dev /dev 2>/dev/null
echo 8 > /proc/sys/kernel/printk          # sin esto el `loglevel=` del cmdline lo tapa
paso() { echo "[FRIDAY apagado] $*" > /dev/kmsg; echo "[FRIDAY apagado] $*" > /dev/console 2>/dev/null; }
paso "1/6 inicio ($1)"
sync
mount -o rprivate / 2>/dev/null
mount -o move /oldroot/host /host 2>/dev/null && MOVED=1     # el NTFS tiene que salir de debajo del loop
paso "2/6 C: movido=${MOVED:-no}"
umount -l /oldroot 2>/dev/null
for l in /dev/loop[0-9]*; do losetup -d "$l" 2>/dev/null; done
sync; sleep 1
paso "3/6 root.disk soltado"
if [ -n "$MOVED" ]; then
  umount /host 2>/dev/null || { mount -o remount,ro /host 2>/dev/null; umount -l /host; }
fi
sync; sleep 1
paso "4/6 C: desmontado"
paso "5/6 llamando a $1 -f"
case "$1" in poweroff) poweroff -f ;; halt) halt -f ;; *) reboot -f ;; esac
paso "6/6 ERROR: $1 -f ha vuelto"     # no debería llegar nunca
sleep 30; echo b > /proc/sysrq-trigger
```

Por qué cada pieza:

- **Dos destinos, `kmsg` y `console`.** El journal se pierde con el equipo
  apagado y la consola del kernel puede estar tapada por la última línea de
  systemd; escribir a los dos garantiza que el último paso quede **en pantalla**,
  que es lo único que el humano puede mandar.
- **Pasos numerados, no un mensaje único.** El número señala el eslabón: 2 = no
  consigue mover el NTFS; 3 = el loop no suelta; 4 = el NTFS no desmonta; 5 =
  el `-f` no reinicia (ahí el eje es el reset del SoC, no el apagado).
- **`mount -o move` antes de desmontar el loop.** El ext4 vive dentro de un
  archivo del NTFS: hay que sacar el NTFS de `/oldroot` a un punto propio antes
  de soltar el loop, o el desmontaje se queda bloqueado sin decir nada.
- **El `sleep` final y el `sysrq b`.** Si el `-f` vuelve, algo impidió el
  apagado; sin la línea `6/6` ese caso es indistinguible de un cuelgue.

Antes de gastar un reinicio, comprueba que el script está **dentro** del
initramfs reconstruido y que la sintaxis es válida:

```sh
sh -n initramfs-src/shutdown && sh build-initramfs.sh \
  && zcat out/initramfs-elitepad.gz | cpio -i --to-stdout shutdown | grep -c 'FRIDAY apagado'
```

Y al pedir la prueba, dile al humano qué mirar: **el último mensaje
`[FRIDAY apagado] N/6` que llegue a verse**. Con ese número, el siguiente
intento es sobre un eslabón concreto en vez de sobre la cadena entera.
