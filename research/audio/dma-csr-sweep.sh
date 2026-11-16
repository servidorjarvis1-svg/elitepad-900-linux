#!/bin/sh
# Prueba: para cada valor de CSR, escribir IRAM por DMA y leerlo de vuelta por DMA.
D="busybox devmem"
DM=0xFFAF8000; SR=0xFFFC0000; IR=0xFFB00000; CS=0xFFAE8000
h() { printf 0x%08X $(( $1 )); }
w() { $D $(h $1) 32 $(h $2); }
r() { $D $(h $1) 32; }
copy() {
  w $((DM+0x398)) 1; w $((DM+0x338)) 0xFF
  w $((DM+0x00)) $1; w $((DM+0x08)) $2; w $((DM+0x10)) 0
  w $((DM+0x18)) 0xD825; w $((DM+0x1C)) $3
  w $((DM+0x40)) 0x5; w $((DM+0x44)) 0
  w $((DM+0x3A0)) 0x0101
  n=0; while [ $n -lt 300 ] && [ $(( $(r $((DM+0x3A0))) & 1 )) -ne 0 ]; do n=$((n+1)); done
  w $((DM+0x3A0)) 0xFF00
}
CSR0=$(r $CS)
w $SR 0x11223344; w $((SR+4)) 0x55667788
for v in 0x04830882 0x04830880 0x04800082 0x04800401 0x04830082; do
  w $((SR+0x100)) 0; w $((SR+0x104)) 0
  w $CS $v
  copy $SR $IR 4                 # escribir en IRAM
  copy $IR $((SR+0x100)) 4       # leer de IRAM
  echo "CSR=$(h $v) -> leido CSR=$(r $CS) IRAM_vuelta=$(r $((SR+0x100))) $(r $((SR+0x104)))"
done
w $CS $CSR0
echo "CSR restaurado=$(r $CS)"
