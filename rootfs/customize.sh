#!/bin/sh
# Personaliza el rootfs Debian 13 i386 de la ElitePad (tras build-rootfs.sh y mesa/build.sh i386).
set -e
D=$HOME/elitepad-dev
R=$D/debian/rootfs
K=$D/linux-7.x/linux-7.3.4
KREL=7.3.4-elitepad
MESA=$HOME/src/powervr_sgx/build/mesa/i386/install
S="sudo"

# --- paquetes que faltaron en la primera pasada ---
$S cp /etc/resolv.conf $R/etc/resolv.conf 2>/dev/null || true
for m in proc sys dev; do $S mount --bind /$m $R/$m; done
trap 'for m in dev sys proc; do sudo umount $R/$m 2>/dev/null; done' EXIT
$S chroot $R env DEBIAN_FRONTEND=noninteractive sh -c "apt-get update -q >/dev/null && apt-get install -y -q systemd-resolved >/dev/null"

# --- fstab: el root (loop sobre C:\ubuntu\disks\root.disk) y C: (/host) los monta el initramfs ---
$S tee $R/etc/fstab >/dev/null <<'EOF'
# / = loop sobre C:\ubuntu\disks\root.disk y /host = C: (ntfs3): los monta el initramfs.
tmpfs /tmp tmpfs defaults,nosuid,nodev,size=256m 0 0
EOF

# --- usuarios y SSH (solo clave de FRIDAY) ---
$S chroot $R sh -c 'id user >/dev/null 2>&1 || useradd -m -s /bin/bash -G sudo,video,render,input,audio,plugdev user'
for h in root/.ssh home/user/.ssh; do
  $S install -d -m700 $R/$h
  $S install -m600 ${SSH_PUBKEY:-$HOME/.ssh/id_ed25519.pub} $R/$h/authorized_keys
done
$S chroot $R chown -R user:user /home/user/.ssh
echo 'user ALL=(ALL) NOPASSWD:ALL' | $S tee $R/etc/sudoers.d/user >/dev/null
$S chmod 440 $R/etc/sudoers.d/user
$S tee $R/etc/ssh/sshd_config.d/friday.conf >/dev/null <<'EOF'
PasswordAuthentication no
PermitRootLogin prohibit-password
EOF

# --- red: Ethernet del dock por DHCP (networkd) y WiFi con el perfil que ya hay en C: ---
$S tee $R/etc/systemd/network/20-wired.network >/dev/null <<'EOF'
[Match]
Type=ether
[Network]
DHCP=yes
[DHCPv4]
RouteMetric=100
EOF
$S tee $R/etc/systemd/network/30-wlan.network >/dev/null <<'EOF'
[Match]
Name=wlan0
[Network]
DHCP=yes
[DHCPv4]
RouteMetric=600
EOF
$S ln -sf /host/ubuntu/friday-dev/wpa_supplicant.conf $R/etc/wpa_supplicant/wpa_supplicant-wlan0.conf
$S chroot $R systemctl enable systemd-networkd systemd-resolved wpa_supplicant@wlan0 ssh >/dev/null 2>&1 || true
$S ln -sf ../run/systemd/resolve/stub-resolv.conf $R/etc/resolv.conf

# --- tapa: el sensor no es fiable todavía; sin suspensiones ---
$S install -d $R/etc/systemd/logind.conf.d
$S tee $R/etc/systemd/logind.conf.d/elitepad.conf >/dev/null <<'EOF'
[Login]
HandleLidSwitch=ignore
HandleLidSwitchDocked=ignore
HandleLidSwitchExternalPower=ignore
EOF
$S chroot $R systemctl mask suspend.target hibernate.target hybrid-sleep.target >/dev/null 2>&1

# --- volcado del arranque a C:\ubuntu\friday-dev\logs\debian\ (por si no hay red) ---
$S tee $R/usr/local/sbin/friday-bootlog >/dev/null <<'EOF'
#!/bin/sh
O=/host/ubuntu/friday-dev/logs/debian
mkdir -p $O
for i in $(seq 1 60); do
  journalctl -b --no-pager > $O/journal.txt 2>&1
  dmesg > $O/dmesg.txt; ip -br addr > $O/ip.txt 2>&1
  systemctl --failed --no-pager > $O/failed.txt 2>&1
  sync; sleep 5
done
EOF
$S chmod +x $R/usr/local/sbin/friday-bootlog
$S tee $R/etc/systemd/system/friday-bootlog.service >/dev/null <<'EOF'
[Unit]
Description=FRIDAY: volcado del arranque a C:
DefaultDependencies=no
After=systemd-journald.service
[Service]
Type=simple
ExecStart=/usr/local/sbin/friday-bootlog
[Install]
WantedBy=sysinit.target
EOF
$S chroot $R systemctl enable friday-bootlog >/dev/null 2>&1

# --- locale, teclado y hora ---
echo 'es_ES.UTF-8 UTF-8' | $S tee $R/etc/locale.gen >/dev/null
$S chroot $R locale-gen >/dev/null
echo 'LANG=es_ES.UTF-8' | $S tee $R/etc/default/locale >/dev/null
$S sed -i 's/^XKBLAYOUT=.*/XKBLAYOUT="es"/' $R/etc/default/keyboard
$S ln -sf /usr/share/zoneinfo/Europe/Madrid $R/etc/localtime
echo 'Europe/Madrid' | $S tee $R/etc/timezone >/dev/null

# --- módulos y firmware de la GPU (powervr_sgx) para el kernel propio ---
M=$R/lib/modules/$KREL
$S install -d $M/extra $R/lib/firmware/powervr_sgx
$S cp $D/out-7.x/sgx-mods/*.ko $M/extra/
$S cp $K/modules.builtin $K/modules.builtin.modinfo $K/modules.order $M/
$S cp $D/out-7.x/sgx-mods/sgx545_ukernel.bin $R/lib/firmware/powervr_sgx/
$S depmod -b $R $KREL
echo powervr_sgx | $S tee $R/etc/modules-load.d/powervr_sgx.conf >/dev/null
$S install -d $R/opt/sgx/tests
$S cp $D/out-7.x/sgx-tests/powervr_sgx_* $R/opt/sgx/tests/

# --- Mesa sgx en /opt/sgx (antes que la Mesa de Debian) ---
if [ -d "$MESA/usr/lib" ] || [ -d "$MESA/lib" ]; then
  L=$MESA/usr/lib; [ -d "$L" ] || L=$MESA/lib
  $S install -d $R/opt/sgx/lib
  $S cp -a $L/. $R/opt/sgx/lib/
  echo /opt/sgx/lib | $S tee $R/etc/ld.so.conf.d/00-sgx.conf >/dev/null
  $S chroot $R ldconfig
  echo GBM_BACKENDS_PATH=/opt/sgx/lib/gbm | $S tee -a $R/etc/environment >/dev/null
else
  echo "AVISO: no encuentro la Mesa i386 en $MESA"
fi

echo "== personalizado"; $S du -sh $R
