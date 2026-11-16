#!/bin/sh
# Ciclo de prueba ElitePad: (Linux) instala *.new y reinicia -> Windows -> bootsequence -> Linux.
# Uso: sh ciclo.sh            (la tableta puede estar en Linux o en Windows)
IP=${ELITEPAD_IP:?export ELITEPAD_IP=<tablet IP>}
O="-o BatchMode=yes -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o LogLevel=ERROR"
GUID="${LINUX_BOOT_GUID:?export LINUX_BOOT_GUID=<firmware boot entry GUID, see bcdedit /enum firmware>}"
t0=$(date +%s)
el() { echo "[$(( $(date +%s) - t0 ))s] $*"; }

if timeout 6 ssh $O root@$IP true 2>/dev/null; then
  el "en Linux: instalo .new y reinicio"
  timeout 20 ssh $O root@$IP 'cd /mnt/c/ubuntu/friday-dev && for f in *.new; do [ -f "$f" ] && mv -f "$f" "${f%.new}" && echo "  instalado ${f%.new}"; done; sync; md5sum bzImage initramfs-elitepad.gz; reboot'
  sleep 10
fi
for i in $(seq 1 60); do
  timeout 5 ssh $O home@$IP ver 2>/dev/null | grep -q Windows && { el "Windows arriba"; break; }
  sleep 5
done
ssh $O home@$IP "bcdedit /set {fwbootmgr} bootsequence $GUID >nul && shutdown /r /t 3 /f" || { el "ERROR: no llego a Windows"; exit 1; }
el "bootsequence puesto, reiniciando a Linux"
sleep 15
for i in $(seq 1 40); do
  timeout 5 ssh $O root@$IP true 2>/dev/null && { el "Linux arriba: $(ssh $O root@$IP uname -v)"; exit 0; }
  sleep 5
done
el "ERROR: Linux no aparece en red"; exit 1
