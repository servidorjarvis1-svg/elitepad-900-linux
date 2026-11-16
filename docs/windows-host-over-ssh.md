# Controlar un Windows antiguo por SSH desde Linux

Base de todo el trabajo: casi siempre el único sistema que arranca es el
Windows del equipo, y desde él se editan los archivos de arranque de Linux. Sin
gráfico, por SSH.

## 1. Conseguir sshd en un Windows sin OpenSSH

Comprobar primero si ya viene: en Windows 10 desde 1809 es una capacidad
opcional. En instalaciones más antiguas no existe y hay que traer el portable.

Con capacidad (pegar en PowerShell **como administrador**):

```
Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
Start-Service sshd
Set-Service sshd -StartupType Automatic
New-NetFirewallRule -Name sshd -DisplayName "OpenSSH" -Protocol TCP -LocalPort 22 -Action Allow
```

Sin capacidad: descargar `OpenSSH-Win32.zip` (o `Win64`) desde el release de
PowerShell/Win32-OpenSSH, dejarlo en el pendrive junto al archivo de comandos y
desplegarlo con `Expand-Archive` + `install-sshd.ps1`. Meter el zip **en el
propio pendrive**: la máquina puede no tener forma cómoda de navegar.

Si el humano teclea, el archivo lleva solo comandos (ver "Entregar
instrucciones" en SKILL.md) y los comandos localizan el pendrive por etiqueta
de volumen, nunca por letra fija.

## 2. Ejecutar órdenes por ssh desde bash

- **No anides PowerShell con comillas simples dentro de ssh desde bash.**
  `$_.DeviceID -like 'PCI*'` llega sin comillas al otro lado y devuelve
  `ParserError: Debe proporcionar una expresión de valor después del operador`.
  Alternativas fiables, en este orden:
  1. `wmic` con `/format:csv` (sin comillas anidadas).
  2. `cmd /c` para cosas de sistema de archivos (`dir`, `copy`, `findstr`).
  3. Subir un `.ps1` por `scp` y ejecutarlo con `powershell -File`.
- **Codificación**: la consola española responde en cp850 →
  `| iconv -f cp850 -t utf-8`. La salida CSV de `wmic` sale en ISO-8859-1 y
  **escapa los `&` como `&amp;`**: al leer IDs de PCI hay que desescapar antes
  de comparar (`8076&amp;DEV` → `8076&DEV`).
- Inventario rápido de hardware: `wmic path Win32_PnPEntity get DeviceID,Name /format:csv`.
  Es la vía para sacar el ID de PCI de la GPU, el panel o el lector sin GUI.

## 3. Empujar archivos de arranque y demostrar que quedaron

`scp` acepta rutas de Windows con barra normal:

```
scp -q local/grub.cfg  usuario@host:C:/ubuntu/install/boot/grub/grub.cfg
scp -q usuario@host:C:/ubuntu/install/boot/grub/grub.cfg  local/remoto.cfg
cmp local/grub.cfg local/remoto.cfg && echo GRUB_OK
```

**Nunca digas "aplicado" sin el `cmp`.** Copiar de vuelta y comparar es la
única prueba de que el archivo que arranca es el que editaste. Antes de escribir
el original va a `<archivo>.bak-friday`, y se dice dónde quedó.

## 4. Apagón, reinicio y reconexión

Tras un cuelgue el usuario apaga a la fuerza. Al volver:
`ssh: connect to host ... port 22: No route to host` es normal mientras
Windows arranca. Reintentar en bucle con espera (30-60 s por intento) en vez de
pedirle que avise otra vez:

```bash
for i in 1 2 3 4; do ssh -o ConnectTimeout=8 host 'dir C:\' && break; sleep 20; done
```

## 5. Antes de mandarlo a reiniciar

Comprobar en el propio Windows que no queda nada a medias: hibernación e inicio
rápido fuera (`powercfg /a`), `hiberfil.sys` ausente, `fsutil dirty query C:`
limpio y en corriente. Un NTFS sucio es la causa número uno de un montaje
fallido desde el initramfs.
