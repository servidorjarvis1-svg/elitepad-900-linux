#!/bin/sh
# Cambia la pila de la GPU de la tableta entre la actual y la de upstream dev (o vuelve atrás).
# Uso (root en la tableta): sh sgx-swap.sh instalar   -> usa /root/sgx-dev/{powervr_sgx.ko,sgx545_ukernel.bin,lib/}
#                           sh sgx-swap.sh volver     -> restaura las copias .bak-pre-dev
set -e
KO=/lib/modules/7.3.4-elitepad/kernel/drivers/gpu/drm/powervr_sgx/powervr_sgx.ko
FW=/lib/firmware/powervr_sgx/sgx545_ukernel.bin
LIB=/usr/local/lib/sgx
N=/root/sgx-dev

parar() {
  systemctl stop lightdm; sleep 3
  for i in 1 2 3 4 5; do rmmod powervr_sgx 2>/dev/null && break; sleep 2; done
  ! lsmod | grep -q '^powervr_sgx ' || { echo "ERROR: powervr_sgx sigue cargado"; lsof /dev/dri/* 2>/dev/null | head; systemctl start lightdm; exit 1; }
}
arrancar() {
  modprobe powervr_sgx; sleep 2
  dmesg | grep -i powervr | tail -5
  ls /dev/dri
  systemctl start lightdm
}

case "$1" in
instalar)
  [ -e $KO.bak-pre-dev ] || cp -a $KO $KO.bak-pre-dev
  [ -e $FW.bak-pre-dev ] || cp -a $FW $FW.bak-pre-dev
  [ -d $LIB.bak-pre-dev ] || cp -a $LIB $LIB.bak-pre-dev
  parar
  install -m644 $N/powervr_sgx.ko $KO
  install -m644 $N/sgx545_ukernel.bin $FW
  cp -a $N/lib/. $LIB/
  ldconfig
  arrancar ;;
volver)
  parar
  cp -a $KO.bak-pre-dev $KO
  cp -a $FW.bak-pre-dev $FW
  rm -rf $LIB && cp -a $LIB.bak-pre-dev $LIB
  ldconfig
  arrancar ;;
*) echo "uso: $0 instalar|volver"; exit 1 ;;
esac
md5sum $KO $FW $LIB/libgallium-*.so
