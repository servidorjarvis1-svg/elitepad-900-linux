# Linux on the HP ElitePad 900 G1 (Intel Atom Z2760 "Clover Trail")

Intel never shipped Linux support for Clover Trail (2012). This repository
collects what it took to run a **current** Linux on the HP ElitePad 900 G1 in
2026: kernel patches, kernel configs, the boot chain, a Debian 13 i386 root
filesystem, and the GPU stack for the PowerVR SGX545.

Everything here was tested on real hardware. Lab notes are in Spanish (`docs/`,
`research/`); scripts carry Spanish comments.

## Hardware status

| Part | Status | How |
|---|---|---|
| Boot (32-bit UEFI, no USB boot) | ✅ | Wubi's GRUB on the Windows partition → own kernel + initramfs (`boot/`) |
| Kernel | ✅ Linux 7.3.4 i386 | `kernel/7.x/` (6.12 patches kept in `kernel/6.12/`) |
| Root filesystem | ✅ Debian 13 (trixie) i386 | ext4 image inside `C:\ubuntu\disks\root.disk`, loop-mounted by the initramfs (`rootfs/`) |
| USB on the dock (EHCI, Ethernet, keyboard) | ✅ | patches 0001-0002 (ACPI IDs + `_DSM` post-reset to host mode) |
| GPIO `INT33B2`, I2C `INT33B1` | ✅ | patches 0004-0005 |
| Touchscreen (Atmel `ATML1000`, i2c-hid) | ✅ | |
| WiFi (Atheros AR6004, SDIO) | ✅ | patch 0006 (SDIO 1.8 V) + `firmware-atheros` |
| eMMC 8-bit bus | ✅ 1.4-1.9× faster | patch 0007, `sdhci_acpi.ctv_emmc=1` |
| Reboot | ✅ | patch 0003 (cold reset through the SCU IPC mailbox) |
| GPU PowerVR SGX545 (`8086:08cf`) | ✅ GLES 2.0 | upstream PRs [#17 (kernel)](https://github.com/The1TrueJoe/powervr_sgx/pull/17) and [#18 (Mesa)](https://github.com/The1TrueJoe/powervr_sgx/pull/18); the tablet runs branch [`tablet-dev-highmem`](https://github.com/servidorjarvis1-svg/powervr_sgx/tree/tablet-dev-highmem) |
| GPU buffers in HIGHMEM | ✅ 1.4-1.7× faster, and lowmem stays free | patches 0008-0009 (`kernel/7.x/patches/lkml/`) + `powervr_sgx.highmem=1` |
| Desktop | ✅ Xfce on X11, glamor on the SGX545 | `rootfs/desktop/` |
| Accelerated browser | ✅ WebKitGTK 4.1 / GTK 3 (luakit, surf) | Chromium and Firefox need GLES 3.0 → software only; the gap is in [`docs/chromium-gles3-gap.md`](docs/chromium-gles3-gap.md) |
| Audio (Realtek RT5640 + Intel SST DSP) | ❌ in progress | codec answers on I2C-5 `0x1c`; DSP RAM not powered yet (`docs/audio-sst-cloverview.md`) |
| Cameras (OV8830 / OV2720 via ISP2300) | ❌ | ISP firmware `shisp_css15.bin` is not in linux-firmware; mainline `atomisp` only covers ISP2400/2401 |
| RTC | ❌ | no `/dev/rtc`; time comes from NTP |
| Suspend / lid / deep C-states | ❌ | needs `idle=poll`; s2idle never resumes, with or without the GPU driver (`results/s2idle-*.txt`); lid handling disabled |

### Measured

- GPU: `kmscube` OK, `glmark2-es2-drm` score 82 (build 87, texture 112, phong 60),
  Xorg glamor + `glxgears` ~37 FPS, `mpv` YouTube 480p30 over DRM: 1 dropped frame in 45 s, 28 % CPU.
- GPU, upstream `dev` + the Clover Trail PRs + HIGHMEM buffers: `glxgears` 37 → 62 FPS,
  `mpv` 720p30 in X11 52 → 2 dropped frames per 30 s (2 on DRM), `glmark2-es2-drm`
  69 (2 scenes unsupported, was 8), uAPI 50/50, frame 100/100, blit and hang tests
  all right, 0 GPU page faults, 0 kernel oops. `luakit`: CSS 61.8, canvas 13.7,
  WebGL 14.2 FPS (was 8). All runs: `results/bench-2026-11-16.txt`; the scripts are
  in `gpu/bench/` (`sgx-try.sh` loads a driver build without installing it).
- Browser (WebKitGTK, 1280×740): CSS animation 57.7 FPS; canvas and WebGL ~7 FPS (still CPU copies).
- eMMC: 23 MB/s → 32-44 MB/s raw with the 8-bit bus. Boot to desktop ~19 s.

### Why the kernel needs patches 0008-0009

A 32-bit kernel without PAE has no `ZONE_DMA32`, so a 32-bit GPU MMU that can
reach every page below 4 GiB ends up keeping all its buffers in ~830 MB of
lowmem: a browser takes `LowFree` from 483 MB to 7 MB and the kernel starts
killing processes. Moving them to HIGHMEM hits two kernel bugs instead — CPA
oopses on a HIGHMEM page in a page array, and PAT never records its memory
type, so the write-combined user mapping silently becomes write-back and the
GPU reads stale memory (continuous GPU page faults, device resets). Both
patches are in `kernel/7.x/patches/lkml/` ready to send upstream, and the
driver's `highmem` parameter is off by default for kernels without them. The
oops and the fault storm they fix: `results/oops-cpa-highmem.txt`,
`results/gpu-faults-pat-missing.txt`.

## Layout

```
kernel/7.x/       patches against 7.3.4, config script and the full .config used
kernel/6.12/      the original 6.12 patch set
boot/             GRUB entry, initramfs (busybox + dropbear) init/shutdown, test cycle
rootfs/           mmdebstrap build + customisation, X11/lightdm/Xfce configs
gpu/              loader and uAPI test build for powervr_sgx
tools/sgx-ident/  read-only SGX core identification (freestanding i386)
research/         audio DMA probes, GPIO inventory, GPU and camera plans
results/          benchmark runs and the kernel/GPU logs behind the fixes
docs/             lab notes: ACPI/DSDT, audio, boot, performance, desktop
```

## Building (short version)

1. Kernel: download Linux 7.3.4, apply `kernel/7.x/patches/*`, run
   `kernel/7.x/config-elitepad-7.x.sh <tree>`, `make ARCH=i386 bzImage modules`.
2. GPU: build `drm/powervr_sgx` and Mesa (`mesa/build.sh i386-x11`) from the
   powervr_sgx fork, branch `clovertrail-v0.2`, and load the module with
   `highmem=1` on a kernel that has patches 0008-0009.
3. initramfs: `boot/initramfs/build-initramfs.sh` (needs i386 busybox-static and
   dropbear unpacked from Debian `.deb`s; set `SSH_PUBKEY`).
4. Root fs: `rootfs/build-rootfs.sh` then `rootfs/customize.sh`, then
   `mkfs.ext4 -d rootfs root.disk 8G` and copy it to `C:\ubuntu\disks\`.
5. Boot: add `boot/grub-entry.cfg` to `C:\ubuntu\install\boot\grub\grub.cfg`.
   The initramfs switches to Debian only when `C:\ubuntu\friday-dev\boot-debian`
   exists (one-shot marker), otherwise it stays in the busybox + SSH environment.

Paths in the scripts assume `$HOME/elitepad-dev` and `$HOME/src/powervr_sgx`.

## Not included

Windows drivers, firmware blobs from Windows (`realtek_fw_sst.bin`, ISP firmware)
and ACPI table dumps are not redistributed. Extract them from your own device.

## Credits

- GPU driver, microkernel and Mesa driver: [The1TrueJoe/powervr_sgx](https://github.com/The1TrueJoe/powervr_sgx).
- Clover Trail+ Android kernels (e.g. Lenovo K900 `redhookbay`) as reference for GPIO, I2C, SDIO and SST.

## License

Scripts and docs: MIT (`LICENSE`). Kernel patches: GPL-2.0, like the Linux kernel.
