#!/bin/sh
# Tras arrancar Linux en la ElitePad: sube módulos, firmware y pruebas de la GPU y carga powervr_sgx.
# Uso: sh sgx-load.sh
IP=${ELITEPAD_IP:?export ELITEPAD_IP=<tablet IP>}
O="-o BatchMode=yes -o UserKnownHostsFile=/dev/null -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o LogLevel=ERROR"
D=$HOME/elitepad-dev/out-7.x
tar cf - -C $D/sgx-mods . -C $D/sgx-tests powervr_sgx_test powervr_sgx_frame powervr_sgx_blit powervr_sgx_hang |
timeout 60 ssh $O root@$IP '
set -e
mkdir -p /tmp/sgx /lib/firmware/powervr_sgx && cd /tmp/sgx && tar xf -
cp sgx545_ukernel.bin /lib/firmware/powervr_sgx/
grep -q " /sys/kernel/debug " /proc/mounts || mount -t debugfs none /sys/kernel/debug
for m in drm_exec drm_gpuvm gpu-sched powervr_sgx; do
  lsmod | grep -q "^$(echo $m | tr - _) " || insmod ./$m.ko
done
sleep 1
dmesg | grep -i powervr | tail -4
ls /dev/dri/
cat /sys/kernel/debug/dri/1/status | head -4'
