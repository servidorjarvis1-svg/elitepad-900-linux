#!/bin/sh
# DMA directo (sin LLI): SRAM -> IRAM -> SRAM, 4 palabras. Comprueba si la memoria del DSP es alcanzable.
D="busybox devmem"
DM=0xFFAF8000; SR=0xFFFC0000; IR=0xFFB00000
h() { printf 0x%08X $(( $1 )); }
w() { $D $(h $1) 32 $(h $2); }
r() { $D $(h $1) 32; }
copy() { # src dst nwords
  w $((DM+0x398)) 1
  w $((DM+0x338)) 0xFF
  w $((DM+0x00)) $1
  w $((DM+0x08)) $2
  w $((DM+0x10)) 0
  w $((DM+0x18)) 0xD825
  w $((DM+0x1C)) $3
  w $((DM+0x40)) 0x5
  w $((DM+0x44)) 0
  w $((DM+0x3A0)) 0x0101
  n=0; while [ $n -lt 200 ] && [ $(( $(r $((DM+0x3A0))) & 1 )) -ne 0 ]; do n=$((n+1)); done
  printf "  %s->%s n=%s ChEn=%s RawTfr=%s esperas=%s\n" $(h $1) $(h $2) $3 $(r $((DM+0x3A0))) $(r $((DM+0x2C0))) $n
  w $((DM+0x3A0)) 0xFF00
}
w $SR 0x11223344; w $((SR+4)) 0x55667788; w $((SR+8)) 0xDEADBEEF; w $((SR+12)) 0x0BADF00D
w $((SR+0x100)) 0; w $((SR+0x104)) 0; w $((SR+0x108)) 0; w $((SR+0x10C)) 0
echo "patron en SRAM: $(r $SR) $(r $((SR+4))) $(r $((SR+8))) $(r $((SR+12)))"
echo "SRAM -> IRAM"; copy $SR $IR 4
echo "IRAM -> SRAM+0x100"; copy $IR $((SR+0x100)) 4
echo "vuelta: $(r $((SR+0x100))) $(r $((SR+0x104))) $(r $((SR+0x108))) $(r $((SR+0x10C)))"
echo "lectura directa de IRAM por CPU: $(r $IR) $(r $((IR+4)))"
