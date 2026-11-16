# Entrada de GRUB para dar consola en firmware con bugs

Cuando el gestor de arranque pinta su menú pero al elegir la entrada la
pantalla queda negra **incluso con `nomodeset`**, el fallo es anterior al
driver gráfico: no hay consola porque no se cargó el framebuffer EFI ni se
preservó el modo de vídeo al saltar al kernel.

## Mecanismo

GRUB toma el framebuffer del firmware (`efi_gop` en EFI, `efi_uga` en EFI de
32 bits con VGA) y pinta su menú. Al lanzar el kernel, si el modo no se
preserva, el kernel arranca sin ninguna superficie de texto: no es que el
sistema esté colgado en silencio, es que no tiene dónde escribir. `nomodeset`
no lo arregla porque el problema es anterior al KMS.

## Entrada completa

Las rutas (`search.fs_uuid`, `set root`, `linux .../vmlinuz`, `initrd ...`)
**se copian de la entrada que ya existe en ese mismo archivo**, no se inventan:

```
insmod efi_gop
insmod efi_uga
insmod gfxterm
set gfxmode=auto
set gfxpayload=keep          # lo que se pierde y deja la pantalla muerta
terminal_output gfxterm
echo "cargando kernel..."
linux /ruta/vmlinuz <params> earlyprintk=efi,keep ignore_loglevel
initrd /ruta/initrd
echo "arrancando"
```

Los `echo` entre `linux` e `initrd` son la diferencia entre "no cargó el
kernel" y "no cargó el initrd", y el usuario solo tiene que mandar una foto.

## Parámetros, por eje

| Parámetro | Qué hace | Cuándo |
|---|---|---|
| `gfxpayload=keep` (set) | conserva el modo de vídeo del firmware al saltar al kernel | siempre en esta clase |
| `nomodeset` | prohibe KMS; sólo sirve si ya hay consola | ceguera del driver, no del framebuffer |
| `earlyprintk=efi,keep` | consola temprana sobre el framebuffer EFI | depurar antes del initramfs |
| `noefi` | desactiva los servicios EFI en runtime | cuelgue en `efi_enter_virtual_mode` (Clover Trail, IA32) |
| `ignore_loglevel` / `loglevel=7` | saca todos los mensajes | siempre al depurar |
| `forcepae` | habilita PAE | solo Pentium M / núcleos sin PAE |

`noefi` no rompe el vídeo: el framebuffer EFI llega por `screen_info`, no por
los runtime services.

## Reglas al editarlo

- **Backup primero**: `<archivo>.bak-friday`, y decir dónde quedó.
- **Entrada nueva y primera**; no se reescriben las que ya existen. Si no
  sirve, se elige otra y ya está.
- **Un solo eje por reinicio.** Dos parámetros de vídeo a la vez y el resultado
  no dice cuál funcionó.
- Verificar que quedó escrito y primero (`findstr`/`grep` del archivo, mejor con
  `cmp` contra la copia local) antes de decirle que reinicie.
