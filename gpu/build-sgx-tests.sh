#!/bin/sh
# Compila las pruebas uAPI de powervr_sgx como i386 estático, sin instalar nada en friday:
# glibc i386 sacada de los .deb multilib de Debian (sysroot32/) + cabeceras del kernel 7.3.4.
set -eu
S=$HOME/elitepad-dev/sysroot32
R=$HOME/src/powervr_sgx
OUT=$HOME/elitepad-dev/out-7.x/sgx-tests
mkdir -p "$OUT"
GCCDIR=$S/usr/lib/gcc/x86_64-linux-gnu/14/32
CC="gcc -m32 -static -O2 -fno-strict-aliasing -Wall -Wno-unused-function \
 -isystem $S/khdr/include -isystem $S/khdr/include/drm -isystem $S/usr/include/x86_64-linux-gnu -isystem /usr/include/x86_64-linux-gnu \
 -I $R/drm/powervr_sgx/include/uapi/drm \
 -B $S/usr/lib32 -B $GCCDIR -L $S/usr/lib32 -L $GCCDIR"
cd "$R"
python3 tools/gen/mkusse.py > "$OUT/usse_progs.h"
$CC -I "$OUT" -o "$OUT/powervr_sgx_test" drm/tests/powervr_sgx_test.c
$CC -I "$OUT" -DSGXGEN_DRM -I tools/gen -o "$OUT/powervr_sgx_frame" drm/tests/powervr_sgx_frame.c tools/gen/sgxgen.c -lm
$CC -I "$OUT" -I tools/tex -o "$OUT/powervr_sgx_blit" drm/tests/powervr_sgx_blit.c tools/tex/sgxtex.c
$CC -I "$OUT" -DSGXGEN_DRM -I tools/gen -I tools/tex -o "$OUT/powervr_sgx_hang" drm/tests/powervr_sgx_hang.c tools/gen/sgxgen.c tools/tex/sgxtex.c -lm
file "$OUT"/powervr_sgx_* | sed "s|$OUT/||"
