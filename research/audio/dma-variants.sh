#!/bin/sh
# Variantes de activacion del DMAC del LPE (canal 0). SRAM->SRAM, 4 palabras.
D="busybox devmem"
DM=0xFFAF8000; SR=0xFFFC0000
h() { printf 0x%08X $(( $1 )); }
w() { $D $(h $1) 32 $(h $2); }
r() { $D $(h $1) 32; }

w $SR 0x11223344; w $((SR+4)) 0x55667788; w $((SR+0x100)) 0; w $((SR+0x104)) 0
$D $((SR)) 32 0x11223344
echo "SRAM ok: $(r $SR) $(r $((SR+4)))"

prep() {
  w $((DM+0x398)) 1
  w $((DM+0x338)) 0xFF
  w $((DM+0x00)) $SR
  w $((DM+0x08)) $((SR+0x100))
  w $((DM+0x10)) 0
  w $((DM+0x18)) 0xD825
  w $((DM+0x1C)) 4
  w $((DM+0x40)) 0x5
  w $((DM+0x44)) 0
}
for v in 0x01 0x0101 0xFF01 0x0100; do
  w $((SR+0x100)) 0; w $((SR+0x104)) 0
  prep
  w $((DM+0x3A0)) $v
  usleep=0; n=0
  while [ $n -lt 20 ]; do n=$((n+1)); done
  echo "ChEn escrito=$v -> ChEn=$(r $((DM+0x3A0))) RawTfr=$(r $((DM+0x2C0))) RawBlock=$(r $((DM+0x2C8))) StatusTfr=$(r $((DM+0x2E8))) datos=$(r $((SR+0x100))) $(r $((SR+0x104)))"
  w $((DM+0x3A0)) 0xFF00
done
echo "DmaStatus=$(r $((DM+0x3A8))) DmaCfg=$(r $((DM+0x398)))"
