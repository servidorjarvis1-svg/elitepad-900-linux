#!/bin/sh
# DMA directo con varios tamaños a IRAM (0xFFB00000) y DRAM (0xFFB80000).
D="busybox devmem"
DM=0xFFAF8000; SR=0xFFFC0000
h() { printf 0x%08X $(( $1 )); }
w() { $D $(h $1) 32 $(h $2); }
r() { $D $(h $1) 32; }
copy() {
  w $((DM+0x398)) 1; w $((DM+0x338)) 0xFF
  w $((DM+0x00)) $1; w $((DM+0x08)) $2; w $((DM+0x10)) 0
  w $((DM+0x18)) 0xD825; w $((DM+0x1C)) $3
  w $((DM+0x40)) 0x5; w $((DM+0x44)) 0
  w $((DM+0x3A0)) 0x0101
  n=0; while [ $n -lt 500 ] && [ $(( $(r $((DM+0x3A0))) & 1 )) -ne 0 ]; do n=$((n+1)); done
  w $((DM+0x3A0)) 0xFF00
}
# patron de 64 palabras
i=0; while [ $i -lt 64 ]; do w $((SR + i*4)) $((0xA0000000 + i)); i=$((i+1)); done
w $SR $(r $SR); echo "patron: [$SR]=$(r $SR) [$((SR+0xFC))]=$(r $((SR+0xFC)))"
for dst in 0xFFB00000 0xFFB80000; do
  for n in 4 16 64; do
    w $((SR+0x200)) 0; w $((SR+0x204)) 0
    copy $SR $dst $n
    copy $dst $((SR+0x200)) $n
    echo "  dst=$(h $dst) n=$n -> vuelta=$(r $((SR+0x200))) $(r $((SR+0x204)))"
  done
done
