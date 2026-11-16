# Rendimiento en una tableta de 2 GB: qué medir y qué se gana

Un Atom con 2 GB y eMMC no se arregla con florituras: se mide dónde duele y se
toca solo eso. Orden: disco → memoria → arranque. La GPU ya está resuelta y no
compensa volver a ella.

## 1. Medir el disco crudo antes de culpar a la CPU

La eMMC de estas tabletas es el cuello de botella real; con 22 MB/s cualquier
compilación, `apt` o arranque de Chromium parece "CPU lenta".

```
dd if=/dev/mmcblk0 of=/dev/null bs=1M count=256 iflag=direct   # lectura secuencial
cat /sys/kernel/debug/mmc0/ios                                # reloj, ancho de bus, timing
```

- `bs=1M iflag=direct` salta la caché de página: sin `direct` se mide la RAM.
- En `ios`, mira `clock`, `bus width` y `timing`: si el bus va a 4 bits o el
  reloj bajo cuando el chip soporta más, hay margen en el controlador antes que
  en el sistema de archivos.
- Con el número en la mano, di el veredicto: por debajo de ~50 MB/s en lectura
  secuencial, el usuario nota el disco en todo y hay que optimizar ahí (swap en
  RAM, no escribir logs, evitar indexadores).

## 2. Arranque: `critical-chain`, no `blame`

`systemd-analyze blame` ordena por duración propia y engaña: servicios que
corren en paralelo salen arriba sin retrasar nada. La cadena que importa es la
que llega a `graphical.target`.

```
systemd-analyze
systemd-analyze critical-chain graphical.target --no-pager | head -14
```

- Ejemplo real: `keyboard-setup` 5,5 s y `console-setup` 4 s encabezaban
  `blame` y **no estaban en la cadena**; lo que retrasaba el escritorio era
  `plymouth-quit-wait` (2,9 s) en serie con `getty`.
- Optimiza los nodos de la cadena, uno a uno, y vuelve a medir. Tocar lo que
  sale en `blame` sin mirar la cadena es trabajo sin efecto.

## 3. Quitar el splash: 3 s que además tapan el diagnóstico

Con `simpledrm` y sin necesidad de arranque bonito, plymouth solo cuesta:

```
DEBIAN_FRONTEND=noninteractive apt-get purge -y plymouth plymouth-label
```

Comprueba después con `systemd-analyze` que el total baja y que
`plymouth-quit-wait` ya no aparece. Un sistema sin splash arranca igual de
satisfactorio en una tableta y te deja ver los mensajes cuando algo falla.

## 4. zram: swap comprimida en RAM

En 2 GB, el `OOM` de Chromium llega antes que cualquier otra cosa, y una swap
en eMMC a 22 MB/s no sirve de nada. zram comprime páginas en RAM con lz4, que
es lo único barato para un Atom.

### Kernel

El `CONFIG_ZRAM` **no viene puesto** en la config heredada. En el script de
configuración del equipo, antes del `olddefconfig`:

```sh
$C --enable ZSMALLOC --enable ZRAM --enable ZRAM_BACKEND_LZ4 --enable CRYPTO_LZ4
```

- Los tres símbolos van juntos: sin `ZSMALLOC` no hay zram, y sin un backend
  (`ZRAM_BACKEND_LZ4`) el módulo registra el dispositivo pero no tiene
  compresor. `CRYPTO_LZ4` es la dependencia que se olvida y la que hace
  desaparecer `ZRAM_BACKEND_LZ4` sin decir nada.
- Tras `olddefconfig`, `CONFIG_ZRAM_DEF_COMP="lz4"` aparece solo. Si sale
  `zstd`, es que el backend de zstd ganó: fíjalo con
  `--set-str ZRAM_DEF_COMP lz4` o acepta el coste de compresión en el Atom.
- Añade los símbolos nuevos a la lista que el script imprime al final, para que
  se lean en cada ejecución.
- Compila `bzImage` **y** `modules` (`make ARCH=i386 -j<N> bzImage modules`):
  zram puede ser módulo y sin `modules` no lo cargas.
- Build incremental: recompilar tras cambiar solo la config son minutos, no una
  compilación entera. No borres el árbol para "limpiar".

### Userspace

```
apt-get install -y systemd-zram-generator
```

`/etc/systemd/zram-generator.conf`

```
[zram0]
zram-size = ram / 2
compression-algorithm = lz4
swap-priority = 100
```

`/etc/sysctl.d/90-zram.conf`

```
vm.swappiness = 100
vm.page-cluster = 0
```

- `swappiness=100` porque el destino de la swap **es** RAM comprimida: paginar
  ahí es más rápido que recomprimir y reasignar; con la swap por defecto (60)
  el kernel prefiere reclamar caché de página y el navegador se arrastra.
- `page-cluster=0` desactiva el readahead de 8 páginas: en zram no hay latencia
  de disco que amortiguar y leer de más es trabajo regalado al Atom.
- Verifica con `zramctl` (dispositivo, algoritmo, tamaño) y `swapon --show`
  (prioridad). Si zram no aparece, mira `systemctl status
  systemd-zram-setup@zram0.service`: el generador es silencioso cuando la
  config tiene una clave con errata.
- Una sola swap: si ya hay un archivo o partición de swap, se quita. Dos swaps
  con prioridades distintas se pisan y el resultado no es medible.

## 5. Quitar `idle=poll` antes de medir rendimiento

`idle=poll` es un parche de diagnóstico para el cuelgue por C-states: mantiene
la CPU al 100 % y falsea cualquier medición de rendimiento, consumo y
temperatura. Quítalo de la línea `linux` en cuanto el sistema arranque estable,
y vuelve a medir el arranque y el vídeo con el reposo normal.

## 6. Ancho de bus y timing de la eMMC: lo que da velocidad de verdad

Cuando `ios` dice `bus width: 1 (4 bits)` o `timing spec: 1 (mmc high-speed)`
en un chip que soporta 8 bits y DDR52, el techo está en el controlador y es la
mejora más barata que hay (~1,5-2x). Comprobación en tres lecturas, sin escribir
nada:

```
cat /sys/kernel/debug/mmc0/ios          # bus width, timing spec, clock
mount -t debugfs none /sys/kernel/debug 2>/dev/null
grep -iE 'bus width|timing|clock' /sys/kernel/debug/mmc0/ios
```

`bus width`: 1 = 4 bits, 3 = 8 bits. `timing spec`: 0 legacy, 1 MMC high-speed,
8 MMC-DDR52. El núcleo MMC corre él solo la prueba de bus y elige el máximo que
funcione, así que **un valor bajo significa que el host no anunció la capacidad**
(`MMC_CAP_8_BIT_DATA`, `MMC_CAP_DDR`), no que el chip no pueda.

En Clover Trail (`INT33BA`, `sdhci_acpi`) las capacidades las fija un quirk del
driver por un parámetro de módulo con orígenes distintos según versión —lo que
se comprueba es el efecto en `ios`, no el nombre del parámetro—. Si el quirk
solo se aplica en `probe`/`add_host` **después** de que el host se registre, el
core ya leyó las capacidades viejas y el bus se queda en 4 bits: el punto
correcto es `probe_slot()` del `sdhci_pltfm_host`, que corre antes de
`mmc_add_host()` y donde `drvdata` ya está asignado. Las capacidades se leen de
la ventana MMIO del controlador (+0x40, +0x44) y se guardan en `host->mmc->caps`
para que el core haga el resto.

## 7. Verificar un cambio de bus sin engañarte con los datos

Un bus más ancho sin comprobación de integridad no es una mejora: es una
corrupción silenciosa esperando. Secuencia completa, toda desde el equipo:

1. **Referencias estables**: `md5sum` de las particiones que Windows no toca
   (`mmcblk0gp0`, `mmcblk0boot0`). Válvula de seguridad: si cambian, el bus está
   corrompiendo, no acelerando.
2. **La partición NTFS cambia por diseño**: Windows reescribe
   `System Volume Information/\*.log` cada arranque, así que su MD5 global
   **no** coincide entre ciclos y no prueba nada. Para comparar de verdad, parte
   la partición en trozos de 1 MB y compara lista contra lista:

   ```
   i=0; while [ $i -lt <n_bloques> ]; do
       dd if=/dev/mmcblk0p1 bs=1M skip=$i count=1 2>/dev/null | md5sum; i=$((i+1));
   done > /tmp/p1.md5
   # después, con el bus nuevo:
   paste -d' ' /tmp/p1-nuevo.md5 /tmp/p1-viejo.md5 | awk '$1!=$3{print NR-1}'
   ```

   Que salgan exactamente los bloques donde está el log de Windows es el
   resultado esperado; bloques dispersos, no.
3. **Escritura con relectura**: 200 MB de `/dev/urandom`, `dd conv=fsync` y
   `echo 3 > /proc/sys/vm/drop_caches` antes de releer y comparar el MD5. Sin
   el `drop_caches` se compara la caché de página, no la flash.
4. **Errores del controlador a cero**: `dmesg | grep -ciE 'mmc0.*(error|crc|timeout)|I/O error'`.
5. **Velocidad con `busybox time`**: en sistemas busybox no siempre hay `time`
   como orden, y `$(date +%s%N)` da división por cero cuando el formato no está
   soportado. Mide dos zonas distintas del disco (`skip=3000` y `skip=9000`):
   una sola puede caer en zona ya leída y dar un número optimista.

## 8. Qué NO tocar

- **No compenses la falta de RAM con swap en la eMMC.** A 22 MB/s, paginar en
  disco multiplica la espera por diez y desgasta la flash.
- **No persigas la GPU otra vez.** Ya da lo que puede dar (GLES 2.0 + glamor);
  el escritorio acelerado no va a ir más rápido por tocar Mesa.
- **No desactives servicios por `blame` a ciegas.** Fuera de la cadena
  crítica, quitarlos no acelera el arranque y sí rompe cosas.
