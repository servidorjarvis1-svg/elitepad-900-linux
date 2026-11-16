#!/bin/sh
# Prueba DMA del LPE (DesignWare AHB DMAC @0xFFAF8000): SRAM -> IRAM -> SRAM, canal 0, mem2mem, 32 bits, sondeado.
# Solo toca: SHIM CSR (DSP parado), regs del DMA, SRAM 0xFFFC0000..+0x200 e IRAM 0xFFB00000..+0x10. Restaura CSR.
D="busybox devmem"
DMA=0xFFAF8000; SRAM=0xFFFC0000; IRAM=0xFFB00000; CSR=0xFFAE8000
h() { printf 0x%08X $(( $1 )); }
w() { $D $(h $1) 32 $(h $2); }
r() { $D $(h $1) 32; }

csr0=$(r $CSR)
w $CSR $(( ((csr0 | 0x30000) & 0xFFFFFFF3) | 0x382 | 0x400 ))   # DSP en reset+stall, RAM habilitada
echo "CSR=$(r $CSR)"

# patrón en SRAM y zona de vuelta a cero
i=0; for v in 0x11223344 0x55667788 0x99AABBCC 0xDDEEFF00; do w $((SRAM + i*4)) $v; w $((SRAM + 0x100 + i*4)) 0; i=$((i+1)); done

dma_copy() {  # src dst nwords
  w $((DMA+0x398)) 1                       # DmaCfgReg: enable
  w $((DMA+0x338)) 0xFF                    # ClearTfr
  w $((DMA+0x00)) $1                       # SAR
  w $((DMA+0x08)) $2                       # DAR
  w $((DMA+0x10)) 0                        # LLP
  w $((DMA+0x18)) 0x24                     # CTL_LO: 32b src/dst, inc, mem2mem, sin IRQ
  w $((DMA+0x1C)) $3                       # CTL_HI: BLOCK_TS
  w $((DMA+0x40)) 0                        # CFG_LO
  w $((DMA+0x44)) 0x4                      # CFG_HI: PROTCTL=1
  w $((DMA+0x3A0)) 0x101                   # ChEnReg: canal 0
  n=0; while [ $(( $(r $((DMA+0x3A0))) & 1 )) -ne 0 ] && [ $n -lt 50 ]; do n=$((n+1)); done
  echo "  copia $(h $1)->$(h $2): ChEn=$(r $((DMA+0x3A0))) RawTfr=$(r $((DMA+0x2C0))) CTL_HI=$(r $((DMA+0x1C))) esperas=$n"
}
dma_copy $SRAM $IRAM 4
dma_copy $IRAM $((SRAM+0x100)) 4
echo "origen : $(r $SRAM) $(r $((SRAM+4))) $(r $((SRAM+8))) $(r $((SRAM+12)))"
echo "vuelta : $(r $((SRAM+0x100))) $(r $((SRAM+0x104))) $(r $((SRAM+0x108))) $(r $((SRAM+0x10C)))"
w $((DMA+0x398)) 0
w $CSR $csr0
echo "CSR restaurado=$(r $CSR)"
