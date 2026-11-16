#!/bin/sh
# Prueba DMA del LPE con los valores EXACTOS de intel_mid_dma (mem2mem, 32b, burst 16, SW handshake).
# Restaura CSR al final. Solo toca SHIM CSR, regs DMA, SRAM 0xFFFC0000..+0x200 e IRAM 0xFFB00000..+0x10.
D="busybox devmem"
DMA=0xFFAF8000; SRAM=0xFFFC0000; IRAM=0xFFB00000; CSR=0xFFAE8000
h() { printf 0x%08X $(( $1 )); }
w() { $D $(h $1) 32 $(h $2); }
r() { $D $(h $1) 32; }

csr0=$(r $CSR)
w $CSR $(( ((csr0 | 0x30000) & 0xFFFFFFF3) | 0x382 | 0x400 ))
echo "CSR=$(r $CSR)"

# CTL_LO segun union intel_mid_dma_ctl_lo: int_en=1, dst/src width=2(32b), msize=3(16), tt_fc=0
CTLLO=$(( 1 + (2<<1) + (2<<4) + (3<<11) + (3<<14) ))
echo "CTL_LO=$(h $CTLLO)"

i=0; for v in 0x11223344 0x55667788 0x99AABBCC 0xDDEEFF00; do w $((SRAM + i*4)) $v; w $((SRAM + 0x100 + i*4)) 0; i=$((i+1)); done

prog() { # sar dar nwords llp
  w $((DMA+0x398)) 1
  w $((DMA+0x338)) 0xFF
  w $((DMA+0x00)) $1
  w $((DMA+0x08)) $2
  w $((DMA+0x10)) $4
  w $((DMA+0x18)) $CTLLO
  w $((DMA+0x1C)) $3
  w $((DMA+0x40)) 0x5          # CFG_LO: hs_sel_src|hs_sel_dst (SW handshake)
  w $((DMA+0x44)) 0            # CFG_HI: 0 en mem2mem
  w $((DMA+0x3A0)) 0x101
  n=0; while [ $(( $(r $((DMA+0x3A0))) & 1 )) -ne 0 ] && [ $n -lt 60 ]; do n=$((n+1)); done
  echo "  $(h $1)->$(h $2) n=$3 llp=$(h $4): ChEn=$(r $((DMA+0x3A0))) RawTfr=$(r $((DMA+0x2C0))) CTL_HI=$(r $((DMA+0x1C))) esperas=$n"
}

echo "A) sin LLI, SRAM->SRAM"
prog $SRAM $((SRAM+0x100)) 4 0
echo "   vuelta: $(r $((SRAM+0x100))) $(r $((SRAM+0x104))) $(r $((SRAM+0x108))) $(r $((SRAM+0x10C)))"

# LLI de un bloque en SRAM+0x180: {sar,dar,llp,ctl_lo,ctl_hi,sstat}
LLI=$((SRAM+0x180))
i=0; for v in 0 0 0 0 0 0; do w $((SRAM + 0x100 + i*4)) 0; i=$((i+1)); done
w $((LLI+0x00)) $SRAM
w $((LLI+0x04)) $((SRAM+0x100))
w $((LLI+0x08)) 0
w $((LLI+0x0C)) $CTLLO
w $((LLI+0x10)) 4
w $((LLI+0x14)) 0
echo "B) con LLI, SRAM->SRAM"
prog 0 0 0 $LLI
echo "   vuelta: $(r $((SRAM+0x100))) $(r $((SRAM+0x104))) $(r $((SRAM+0x108))) $(r $((SRAM+0x10C)))"

echo "C) sin LLI, SRAM->IRAM"
prog $SRAM $IRAM 4 0
echo "D) con LLI, SRAM->IRAM"
w $((LLI+0x04)) $IRAM
prog 0 0 0 $LLI

w $((DMA+0x398)) 0
w $CSR $csr0
echo "CSR restaurado=$(r $CSR)"
