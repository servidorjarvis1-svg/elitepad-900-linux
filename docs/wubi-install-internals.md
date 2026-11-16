# Dentro de una instalación Wubi

Wubi instala Ubuntu en archivos dentro del NTFS de Windows. Saber qué hay y
qué hook se ejecuta en cada fase es lo que permite instrumentar el arranque
cuando no hay consola.

## Layout de `C:\ubuntu`

| Ruta | Qué es |
|---|---|
| `disks\root.disk` | el sistema de archivos de Ubuntu (ext4 en archivo) |
| `disks\swap.disk` | swap en archivo |
| `disks\boot` | kernels/initrd del sistema instalado |
| `install\boot\grub\grub.cfg` | **el grub.cfg que se usa de verdad**; sobrescribe al del ESP |
| `install\custom-installation\hooks\` | scripts que el instalador ejecuta en cada fase |
| `install\success-command.sh` | se ejecuta al terminar bien |
| `winboot\` | cargadores que Windows pone en el BCD (`wubildr`) |

No se toca `root.disk` mientras se depura el arranque: su fecha dice si un
intento anterior llegó a escribir algo.

## Hooks (por fase)

- `casper-premount.sh` → primer punto del initramfs, antes de montar nada.
- `casper-bottom.sh` → final del initramfs, **antes de lanzar el sistema real**.
  Es el mejor sitio para un volcado: si corre, el initramfs funcionó.
- `early-command.sh` → antes de instalar. `post-installer.sh` → después de
  copiar. `failure-command.sh` → si algo falla. `success-command.sh` → al final.

`success-command.sh` hace `rm -rf /host/ubuntu/install`: todo lo que se ponga
dentro de `install\` desaparece. Lo que haya que leer después del primer
arranque se copia a `C:\ubuntu\` (fuera de `install\`).

## Volcado desde el initramfs

Bloque para el principio de `casper-bottom.sh`. Escribe en NTFS antes de que
nada más pueda colgarse, y sincroniza en el acto:

```sh
for d in /root/isodevice /isodevice; do
  if [ -d $d/ubuntu ]; then
    { echo "$(date)"; cat /proc/cmdline; echo; mount; echo; \
      ls -l /dev/fb* /dev/mmcblk* 2>&1; echo; dmesg; } \
      > $d/ubuntu/friday-initramfs.txt 2>&1
    sync
  fi
done
```

Lo que responde ese volcado:

- `cat /proc/cmdline` → si los parámetros del cargador llegaron al kernel.
- `mount` → si el NTFS se montó (un Windows con NTFS sucio no monta) y qué
  discos existen.
- `/dev/fb*` → si hay framebuffer. Sin `/dev/fb0` la pantalla negra es del
  driver; con `/dev/fb0` el problema está por encima (X/Wayland, instalador).
- `/dev/mmcblk*` → si el almacenamiento interno aparece como disco.
- `dmesg` → qué driver se enganchó y qué falló.

## Interpretar los resultados

| Qué existe tras el cuelgue | Conclusión |
|---|---|
| nada | no se llegó a ese hook: el fallo es anterior |
| `friday-initramfs.txt` solo | initramfs OK, murió al lanzar el sistema real |
| `friday-live\` con logs de sesión | llegó a userspace: el eje es el servidor gráfico |

Un directorio de logs que el sistema crea *antes* de colgarse (patrón
"escribe aquí y sigue") sirve para lo mismo: su ausencia ya acota el fallo, sin
necesidad de foto de pantalla.

## Reglas

- Todo archivo de hook en **LF** y validado con `sh -n` antes de subirlo.
- Backup del hook original (`*.bak-friday`) y `cmp` de vuelta tras subirlo.
- Guardar los scripts fuente en el Linux de trabajo y subirlos por `scp`: se
  reeditan cada iteración y el lado Windows no es sitio para editarlos.
- Pedir al usuario que **espere un minuto en el cuelgue** antes de apagar a la
  fuerza, para que el `sync` tenga ocasión de llegar al disco.
