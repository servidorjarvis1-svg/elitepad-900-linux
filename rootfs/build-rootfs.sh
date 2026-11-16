#!/bin/sh
# Debian 13 (trixie) i386 para la ElitePad 900 G1 -> rootfs en ~/elitepad-dev/debian/rootfs
# Kernel propio (7.3.4-elitepad): no se instala linux-image.
set -e
D=$HOME/elitepad-dev/debian
R=$D/rootfs
sudo rm -rf "$R"; mkdir -p "$D"

PKGS="systemd-sysv,udev,dbus,kmod,openssh-server,sudo,iproute2,iputils-ping,wpasupplicant,iw,wireless-regdb,\
firmware-atheros,ca-certificates,curl,less,nano,locales,tzdata,console-setup,keyboard-configuration,\
pciutils,usbutils,i2c-tools,evtest,libinput-tools,alsa-utils,htop,busybox,procps,psmisc,file,\
seatd,cage,chromium,mpv,yt-dlp,kmscube,glmark2-es2-drm,mesa-utils-bin,libdrm2,libgbm1,libegl1,libgles2,\
fonts-dejavu-core,fonts-noto-color-emoji"

sudo mmdebstrap --arch=i386 --variant=minbase --mode=root \
  --components="main contrib non-free non-free-firmware" \
  --include="$PKGS" \
  --customize-hook='echo elitepad > "$1/etc/hostname"' \
  --customize-hook='printf "127.0.0.1 localhost\n127.0.1.1 elitepad\n" > "$1/etc/hosts"' \
  trixie "$R" http://deb.debian.org/debian

sudo du -sh "$R"
