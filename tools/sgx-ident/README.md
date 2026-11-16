# sgx-ident — the SGX545's identity, on the tablet, without writing anything

The first thing to run on the ElitePad once a kernel boots: read the eight SGX
registers that are safe on a core nobody has initialised, and print what they mean.
It is the F0 step of `~/elitepad-dev/ref/plan-sgx545-clovertrail.md` and
`powervr_sgx`'s `docs/porting/cores/clovertrail.md`, in one binary.

**It only reads.** No register writes, no config-space writes, no BAR sizing, one
`O_RDONLY` mapping of exactly one page.

## What it reads

| Offset from the window | Register | Expected |
|---|---|---|
| 0x0000 | `CLKGATECTL` | stable after reset; gating mode of every unit |
| 0x0008 | `CLKGATESTATUS` | bit 5 (`DPM_CLKS`) up = the DPM's clocks run |
| 0x001c | `CORE_ID` | `0x0115xxxx` = SGX545; `xxxx` is CONFIG |
| 0x0020 | `CORE_REVISION` | `0x0001000d` (Cedarview), `0x0001000e` (CE5300), or new |
| 0x0080 | `SOFT_RESET` | 0 when the cores are out of reset |
| 0x012c | `EVENT_STATUS` | bit 14 set = a microkernel is already running |
| 0x0130 | `EVENT_HOST_ENABLE` | 0 in the reset state |
| 0x0c00 | `BIF_CTRL` | 0 when idle |

Window = BAR 0 + `0x80000` = **`0xFF280000`** (BAR 0 is `0xFF200000`, 1 MiB). Nothing
below `0xFF280000` is touched: that half is the display engine's, and a wrong read
there can take the tablet down.

Before the mapping it reads `0000:00:02.0`'s config space (vendor, device, BAR 0) and
refuses to run if it is not `8086:08cf` — that is one read of 8 bytes, no write.

## Build

Needs only gcc with 32-bit support (no i386 libc: this host has none, and the binary
needs none):

```sh
cd ~/elitepad-dev/tools/sgx-ident
make            # gcc -m32 -static -nostdlib -fno-pic, kernel nolibc headers
make check      # parses a fake config space and a fake window: no hardware
```

The exact command, if you want it outside the Makefile:

```sh
NOLIBC=~/elitepad-dev/linux-6.12.117/tools/include/nolibc
gcc -m32 -static -nostdlib -fno-pic -fno-stack-protector -Os \
    -I"$NOLIBC" -include "$NOLIBC/nolibc.h" -o sgx-ident sgx-ident.c
```

Result: `ELF 32-bit LSB executable, Intel i386, statically linked`, ~12 KiB, no
interpreter, no undefined symbols. It runs in an initramfs with busybox only.

## Run

On the tablet, as root, from the initramfs (or any i386 userspace):

```sh
sgx-ident --dry-run     # prints the addresses, maps nothing
sgx-ident               # reads the eight registers once
sgx-ident 0xff280000    # explicit window, if BAR 0 is somewhere else
```

`build-initramfs.sh` copies it to `/usr/bin/sgx-ident` when the binary is present.

### Reading the output

```
verdict: SGX545 confirmed, CORE_ID 0x01150002 (CONFIG 0002)
  CORE_REVISION 0x0001000f = 1.0.15  (not in the table yet)
  for drm/powervr_sgx/pvrsgx_core.c: .core_rev = 0x0001000f,
```

Put that value into `PVRSGX_CLV_CORE_REV` in `drm/powervr_sgx/pvrsgx_core.c` (it is
`0` today, a placeholder that never matches) and rebuild.

If `CORE_ID` reads `0x00000000` or `0xffffffff`, the window is not there or the
graphics island is gated; the tool prints the P-Unit APM reads to do next and stops.
Do **not** sweep other offsets: an SGX that hangs can hang the bus, and only a cold
boot clears it.

## Exit codes

| Code | Meaning |
|---|---|
| 0 | the core answered as an SGX545 |
| 1 | bad arguments (or a base that is not page-aligned) |
| 2 | the window did not answer as an SGX545 |
| 3 | `0000:00:02.0` is not `8086:08cf` (`--force` overrides) |
| 4 | `/dev/mem` could not be opened or mapped |

## Safety, in one line

Everything it does is `open(O_RDONLY)`, `read`, `mmap(PROT_READ)` and `write(1)`.
There is no `write()` to a file descriptor that is not stdout, and no `outl`.
