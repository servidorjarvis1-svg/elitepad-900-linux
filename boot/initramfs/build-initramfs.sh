#!/bin/sh
# Construye initramfs-elitepad.gz: busybox estatico + dropbear (i386) + init de FRIDAY
set -e
SRC=$HOME/elitepad-dev/initramfs-src
OUT=$HOME/elitepad-dev/out
R=$SRC/root
rm -rf "$R"; mkdir -p "$R" "$OUT"
cd "$R"
mkdir -p bin sbin usr/bin usr/sbin lib lib/i386-linux-gnu etc root/.ssh proc sys dev run tmp mnt/c var/log

# busybox estatico
cp $SRC/x/bin/busybox bin/busybox
ln -s busybox bin/sh
# identificacion read-only de la SGX545 (freestanding i386, sin libc)
if [ -x $HOME/elitepad-dev/tools/sgx-ident/sgx-ident ]; then
  install -m755 $HOME/elitepad-dev/tools/sgx-ident/sgx-ident usr/bin/sgx-ident
fi
# dropbear + librerias (glibc i386)
cp $SRC/x/usr/sbin/dropbear usr/sbin/
cp $SRC/x/usr/bin/dropbearkey usr/bin/
for l in libc.so.6 libcrypt.so.1 libz.so.1 libtomcrypt.so.1 libtommath.so.1 libgmp.so.10 libutil.so.1 libgcc_s.so.1 libresolv.so.2 libnss_files.so.2; do
  f=$(find $SRC/x -name "$l*" | head -1)
  [ -n "$f" ] && cp -L "$f" lib/i386-linux-gnu/$l
done
# el interprete
f=$(find $SRC/x -name 'ld-linux.so.2' | head -1); cp -L "$f" lib/ld-linux.so.2

# usuarios minimos para dropbear
echo 'root:x:0:0:root:/root:/bin/sh' > etc/passwd
echo 'root:x:0:' > etc/group
echo 'root:*:19000:0:99999:7:::' > etc/shadow
echo '/bin/sh' > etc/shells
echo 'passwd: files' > etc/nsswitch.conf
cp ${SSH_PUBKEY:-$HOME/.ssh/id_ed25519.pub} root/.ssh/authorized_keys
find $SRC/root -type d -exec chmod 755 {} +
chmod 700 root root/.ssh; chmod 600 root/.ssh/authorized_keys etc/shadow

cp $SRC/init init; chmod +x init
cp $SRC/shutdown shutdown; chmod +x shutdown

# binario + sus librerias NEEDED (recursivo) desde el arbol i386 extraido en $SRC/x
need_libs() {
  objdump -p "$1" 2>/dev/null | awk '/NEEDED/{print $2}' | while read n; do
    [ -e lib/i386-linux-gnu/$n ] && continue
    f=$(find $SRC/x -name "$n" \( -type f -o -type l \) | head -1)
    if [ -z "$f" ]; then echo "  FALTA $n (para $1)"; continue; fi
    cp -L "$f" lib/i386-linux-gnu/$n
    need_libs lib/i386-linux-gnu/$n
  done
}
add_bin() {  # add_bin ruta-en-x destino
  cp -L "$SRC/x/$1" "$2/" && need_libs "$2/$(basename $1)"
}
# WiFi: iw + wpa_supplicant/wpa_cli, firmware AR6004 hw1.3 y regulatory.db
add_bin sbin/iw usr/sbin 2>/dev/null || add_bin usr/sbin/iw usr/sbin
add_bin sbin/wpa_supplicant usr/sbin
add_bin sbin/wpa_cli usr/sbin
add_bin usr/bin/wpa_passphrase usr/bin
mkdir -p lib/firmware && cp -a $SRC/firmware/. lib/firmware/

# dependencias reales de dropbear, comprobadas
echo "== librerias que pide dropbear:"
objdump -p usr/sbin/dropbear | awk '/NEEDED/{print $2}' | while read n; do
  [ -e lib/i386-linux-gnu/$n ] && echo "  ok $n" || echo "  FALTA $n"
done

find . | cpio -o -H newc -R 0:0 --quiet | gzip -9 > $OUT/initramfs-elitepad.gz
ls -l $OUT/initramfs-elitepad.gz
