#!/bin/sh
# Banco de pruebas de la GPU en la tableta (se ejecuta como root en la tableta).
# Uso: sh bench-gpu.sh ETIQUETA   -> /root/bench/ETIQUETA/*.txt
# Parte X11 (con lightdm) y parte DRM (para lightdm, mide, lo vuelve a arrancar).
L=${1:?etiqueta}; O=/root/bench/$L; mkdir -p $O; cd $O
U=user; FPS=file:///root/bench/fps.html
asuser() { runuser -u $U -- env DISPLAY=:0 XAUTHORITY=/home/$U/.Xauthority "$@"; }
log() { echo "[$(date +%T)] $*" | tee -a resumen.txt; }

log "== $L  kernel $(uname -r)  mesa $(ls /usr/local/lib/sgx/libgallium-*.so)"
cp /root/bench/fps-bench.html /tmp/fps.html 2>/dev/null; chmod 644 /tmp/fps.html

# --- X11 ---
for m in css canvas webgl; do
  rm -f /tmp/fps.res; (timeout 40 busybox nc -l -p 8765 > /tmp/fps.res) &
  asuser luakit "file:///tmp/fps.html#$m" > luakit-$m.log 2>&1 &
  for i in $(seq 1 30); do grep -q 'GET /r' /tmp/fps.res 2>/dev/null && break; sleep 1; done
  t=$(sed -n 's#^GET /r?\([^ ]*\).*#\1#p' /tmp/fps.res | python3 -c 'import sys,urllib.parse;print(urllib.parse.unquote(sys.stdin.read().strip()))')
  log "luakit $m: ${t:-sin resultado}"
  pkill -x luakit; sleep 4
done
asuser env vblank_mode=0 timeout 12 glxgears > glxgears.txt 2>&1
log "glxgears: $(grep -o '[0-9.]* FPS' glxgears.txt | tail -1)"
asuser timeout 50 script -qc "mpv --no-config --vo=gpu --gpu-context=x11egl --fs --hwdec=no \
  --length=30 av://lavfi:testsrc2=size=1280x720:rate=30" /dev/null > mpv-x11.txt 2>&1
log "mpv x11 720p30 30s: $(tr '\r' '\n' < mpv-x11.txt | grep -o 'Dropped: [0-9]*' | tail -1)"

# --- DRM (sin X) ---
systemctl stop lightdm; sleep 3
timeout 600 glmark2-es2-drm --visual-config a=0 > glmark2.txt 2>&1
log "glmark2: $(grep -i 'score' glmark2.txt | tail -1)  fallos: $(grep -ciE 'unsupported|error|fail' glmark2.txt)"
timeout 50 script -qc "mpv --no-config --vo=gpu --gpu-context=drm --hwdec=no \
  --length=30 av://lavfi:testsrc2=size=1280x720:rate=30" /dev/null > mpv-drm.txt 2>&1
log "mpv drm 720p30 30s: $(tr '\r' '\n' < mpv-drm.txt | grep -o 'Dropped: [0-9]*' | tail -1)"
T=${SGX_TESTS:-/opt/sgx/tests}
$T/powervr_sgx_test > uapi.txt 2>&1; log "uapi: $(tail -1 uapi.txt)"
$T/powervr_sgx_frame -n 100 > frame.txt 2>&1 || $T/powervr_sgx_frame > frame.txt 2>&1; log "frame: $(tail -1 frame.txt)"
systemctl start lightdm
log "irqs: $(grep -i powervr /proc/interrupts | awk '{print $2+$3+$4+$5}')"
log "dmesg powervr: $(dmesg | grep -ciE 'powervr.*(fault|lost|reset|error)')"
