#!/bin/sh
# Prueba NO persistente de una pila de GPU: nada se escribe en el sistema.
# Tras un cuelgue y un reinicio, la tableta vuelve sola a la pila instalada.
#   sh sgx-try.sh [DIR]   DIR (por defecto /root/sgx-dev) con powervr_sgx.ko, sgx545_ukernel.bin y lib/
set -e
N=${1:-/root/sgx-dev}
mkdir -p /run/sgx-try/fw/powervr_sgx
cp $N/sgx545_ukernel.bin /run/sgx-try/fw/powervr_sgx/
systemctl stop lightdm; sleep 3
for i in 1 2 3 4 5; do rmmod powervr_sgx 2>/dev/null && break; sleep 2; done
! lsmod | grep -q '^powervr_sgx ' || { echo "ERROR: powervr_sgx sigue cargado"; systemctl start lightdm; exit 1; }
grep -q ' /usr/local/lib/sgx ' /proc/mounts || mount --bind $N/lib /usr/local/lib/sgx
echo /run/sgx-try/fw > /sys/module/firmware_class/parameters/path
insmod $N/powervr_sgx.ko
sleep 2
echo > /sys/module/firmware_class/parameters/path
dmesg | grep -i powervr | tail -3
systemctl start lightdm
echo "prueba activa (no persistente): $(md5sum $N/powervr_sgx.ko | cut -c1-8)"
