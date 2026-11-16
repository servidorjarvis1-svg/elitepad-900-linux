/*
 * sgx-ident - read the identification registers of the PowerVR SGX545 in an
 * Intel Clover Trail (Atom Z2760) tablet, and nothing else.
 *
 * The SGX shares PCI function 0000:00:02.0 and BAR 0 (1 MiB) with the display
 * engine: its window is at BAR 0 + 0x80000 (docs/porting/cores/clovertrail.md
 * in powervr_sgx). Nothing here writes to the GPU, the PCI function or the
 * config space: one O_RDONLY mapping of one page, eight named registers read
 * once each, then exit.
 *
 * Freestanding i386: no libc, the kernel's nolibc headers, static, no PIC.
 * That is what an initramfs on a 32-bit-only tablet with no i386 libc needs.
 *
 * Build and use: see README.md next to this file.
 *
 *   sgx-ident [--dry-run] [--force] [base]
 *
 *     --dry-run   check the PCI identity and print what would be read; map nothing
 *     --force     read even if the PCI identity is not 8086:08cf
 *     base        hexadecimal window base, default BAR 0 + 0x80000
 *
 * Exit: 0 the core answered as an SGX545, 2 it did not, 3 wrong PCI identity,
 * 4 /dev/mem or the mapping failed, 1 bad arguments.
 */

#include <stdint.h>

#ifndef O_RDONLY
#define O_RDONLY 0
#endif
#ifndef SEEK_SET
#define SEEK_SET 0
#endif
#ifndef PROT_READ
#define PROT_READ 1
#endif
#ifndef MAP_SHARED
#define MAP_SHARED 1
#endif
#ifndef MAP_FAILED
#define MAP_FAILED ((void *)-1)
#endif

typedef unsigned int u32;
typedef unsigned short u16;

#define SGX_CLV_OFFSET		0x80000u
#define SGX_BAR0_DEFAULT	0xff200000u
#define PAGE_SIZE_		4096u

/* The registers pvrsgx_regs.h names as safe to read on an uninitialised core. */
static const struct {
	u32 off;
	const char *name;
} regs[] = {
	{ 0x0000, "CLKGATECTL" },
	{ 0x0008, "CLKGATESTATUS" },
	{ 0x001c, "CORE_ID" },
	{ 0x0020, "CORE_REVISION" },
	{ 0x0080, "SOFT_RESET" },
	{ 0x012c, "EVENT_STATUS" },
	{ 0x0130, "EVENT_HOST_ENABLE" },
	{ 0x0c00, "BIF_CTRL" },
};

#define NREGS ((int)(sizeof(regs) / sizeof(regs[0])))

static u32 values[NREGS];

/* ---- output, without a printf ------------------------------------------- */

static void put(const char *s)
{
	size_t n = 0;

	while (s[n])
		n++;
	write(1, s, n);
}

static void put_hex(u32 v, int digits)
{
	static const char hex[] = "0123456789abcdef";
	char b[16];
	int i;

	if (digits > 8)
		digits = 8;
	for (i = 0; i < digits; i++)
		b[i] = hex[(v >> (4 * (digits - 1 - i))) & 0xf];
	write(1, b, digits);
}

static void put_dec(u32 v)
{
	char b[12];
	int i = 0;

	if (!v) {
		write(1, "0", 1);
		return;
	}
	while (v) {
		b[i++] = '0' + v % 10;
		v /= 10;
	}
	while (i--)
		write(1, &b[i], 1);
}

static void put_hex8(u32 v)
{
	put("0x");
	put_hex(v, 8);
}

/* Name, padded to the longest, then its absolute address. */
static void put_reg_line(int i, u32 win)
{
	int len = 0;

	put("  ");
	put(regs[i].name);
	while (regs[i].name[len])
		len++;
	while (len++ < 18)
		put(" ");
	put_hex8(win + regs[i].off);
	put(" = ");
	put_hex8(values[i]);
	put("\n");
}

/* ---- PCI identity, read-only ------------------------------------------- */

#ifndef CONFIG_PATH	/* a test can point it at a fake config space */
#define CONFIG_PATH "/sys/bus/pci/devices/0000:00:02.0/config"
#endif

static int pci_identity(u16 *vendor, u16 *device, u32 *bar0_raw)
{
	int fd;
	u32 v;

	fd = open(CONFIG_PATH, O_RDONLY, 0);
	if (fd < 0)
		return -1;
	*bar0_raw = 0;
	if (lseek(fd, 0, SEEK_SET) != 0 || read(fd, &v, 4) != 4) {
		close(fd);
		return -1;
	}
	*vendor = (u16)(v & 0xffff);
	*device = (u16)(v >> 16);
	/* lseek returns the offset it moved to, not 0. */
	if (lseek(fd, 0x10, SEEK_SET) < 0 || read(fd, bar0_raw, 4) != 4) {
		*bar0_raw = 0;	/* no BAR 0 from config space: the default is used */
	} /* else: a memory BAR, bit 0 clear and bits 2:1 its width (0 = 32-bit) */
	close(fd);
	return 0;
}

static u32 parse_hex(const char *s)
{
	u32 v = 0;

	if (s[0] == '0' && (s[1] == 'x' || s[1] == 'X'))
		s += 2;
	for (; *s; s++) {
		v <<= 4;
		if (*s >= '0' && *s <= '9')
			v |= (u32)(*s - '0');
		else if (*s >= 'a' && *s <= 'f')
			v |= (u32)(*s - 'a' + 10);
		else if (*s >= 'A' && *s <= 'F')
			v |= (u32)(*s - 'A' + 10);
		else
			return 0;
	}
	return v;
}

static int streq(const char *a, const char *b)
{
	while (*a && *a == *b) {
		a++;
		b++;
	}
	return *a == *b;
}

static int find(u32 off)
{
	for (int i = 0; i < NREGS; i++)
		if (regs[i].off == off)
			return i;
	return -1;
}

/* ---- main --------------------------------------------------------------- */

int main(int argc, char **argv)
{
	u32 base = 0, bar0 = 0, win;
	u16 vendor = 0, device = 0;
	int dry = 0, force = 0, have_base = 0;
	volatile u32 *p;
	int fd, i;

	for (i = 1; i < argc; i++) {
		if (streq(argv[i], "--dry-run") || streq(argv[i], "-n")) {
			dry = 1;
		} else if (streq(argv[i], "--force")) {
			force = 1;
		} else if (streq(argv[i], "--help") || streq(argv[i], "-h")) {
			put("usage: sgx-ident [--dry-run] [--force] [base]\n"
			    "  reads CLKGATECTL, CLKGATESTATUS, CORE_ID, CORE_REVISION,\n"
			    "  SOFT_RESET, EVENT_STATUS, EVENT_HOST_ENABLE and BIF_CTRL\n"
			    "  of the SGX545 at BAR 0 + 0x80000 (0000:00:02.0). No writes.\n");
			return 0;
		} else if (argv[i][0] == '-') {
			put("sgx-ident: unknown option; try --help\n");
			return 1;
		} else {
			base = parse_hex(argv[i]);
			if (!base) {
				put("sgx-ident: bad base address\n");
				return 1;
			}
			have_base = 1;
		}
	}

	put("sgx-ident: PowerVR SGX545 identification, Intel Clover Trail (Atom Z2760)\n");

	/* 1. Who is on 00:02.0, and where is BAR 0? Read-only config space. */
	if (pci_identity(&vendor, &device, &bar0) == 0) {
		put("pci 0000:00:02.0: vendor ");
		put_hex(vendor, 4);
		put(" device ");
		put_hex(device, 4);
		if (bar0 & 1) {
			put(", BAR 0 is I/O space (raw ");
			put_hex8(bar0);
			put(")\n");
			bar0 = 0;
		} else {
			bar0 &= ~0xfu;
			put(", BAR 0 ");
			put_hex8(bar0);
			put("\n");
		}
		if (vendor != 0x8086 || device != 0x08cf) {
			put("sgx-ident: not the SGX function of a Clover Trail (8086:08cf).\n");
			if (!force) {
				put("           Refusing; --force reads it anyway.\n");
				return 3;
			}
			put("           --force: reading anyway.\n");
		}
	} else {
		put("sgx-ident: cannot read " CONFIG_PATH " (not root, or no such device)\n");
		put("           continuing with the default BAR 0 ");
		put_hex8(SGX_BAR0_DEFAULT);
		put("\n");
	}

	/* 2. The window: BAR 0 + the SGX's offset. */
	if (!have_base)
		base = (bar0 ? bar0 : SGX_BAR0_DEFAULT) + SGX_CLV_OFFSET;
	if (base & (PAGE_SIZE_ - 1)) {
		put("sgx-ident: the base must be page-aligned\n");
		return 1;
	}
	win = base;
	put("window ");
	put_hex8(win);
	if (have_base) {
		put(" (given on the command line)\n");
	} else {
		put(" (BAR 0 + ");
		put_hex8(SGX_CLV_OFFSET);
		put(")\n");
	}

	if (dry) {
		put("--dry-run: nothing mapped. Would read:\n");
		for (i = 0; i < NREGS; i++) {
			put("  ");
			put(regs[i].name);
			put(" at ");
			put_hex8(win + regs[i].off);
			put("\n");
		}
		return 0;
	}

	/* 3. One page of /dev/mem, PROT_READ only. */
#ifndef DEVMEM_PATH	/* a test can point it at a fake window */
#define DEVMEM_PATH "/dev/mem"
#endif
	fd = open(DEVMEM_PATH, O_RDONLY, 0);
	if (fd < 0) {
		put("sgx-ident: cannot open /dev/mem (needs root, CONFIG_DEVMEM=y)\n");
		return 4;
	}
	/*
	 * Not mmap(): on i386 nolibc turns it into mmap2 with a signed 32-bit
	 * off_t shifted right, so any window above 2 GiB comes out wrong
	 * (EINVAL).  mmap2 takes the page number; pass it unsigned.
	 */
	p = (volatile u32 *)my_syscall6(__NR_mmap2, 0, PAGE_SIZE_, PROT_READ,
					MAP_SHARED, fd, (unsigned long)(win >> 12));
	if ((unsigned long)p >= (unsigned long)-4095)
		p = MAP_FAILED;
	if (p == MAP_FAILED) {
		put("sgx-ident: mmap of the window failed (EINVAL: not page-aligned? EPERM?)\n");
		close(fd);
		return 4;
	}

	/* 4. The eight registers, once each. */
	for (i = 0; i < NREGS; i++) {
		values[i] = p[regs[i].off / 4];
		put_reg_line(i, win);
	}
	put("\n");

	/* 5. What it is. */
	if (values[find(0x001c)] == 0 || values[find(0x001c)] == 0xffffffffu) {
		put("verdict: CORE_ID reads ");
		put_hex8(values[find(0x001c)]);
		put(": nothing is decoded there.\n");
		put("  Either the window is not at this offset, or the island is gated.\n");
		put("  Do not try other offsets blind. Read the P-Unit's APM bases first:\n");
		put("    setpci -s 00:00.0 0xd0.l=0x10047af0 ; setpci -s 00:00.0 0xd4.l\n");
		put("    setpci -s 00:00.0 0xd0.l=0x100478f0 ; setpci -s 00:00.0 0xd4.l\n");
		put("  then APM_STS (APM base + 4): bits 1:0 are the graphics island,\n");
		put("  00 = on, 11 = in D0I3.\n");
		close(fd);
		return 2;
	}
	if ((values[find(0x001c)] >> 16) != 0x0115u) {
		put("verdict: CORE_ID ");
		put_hex8(values[find(0x001c)]);
		put(" is not an SGX545 (core number 0x0115).\n");
		put("  Wrong window, or a different part. Nothing was written.\n");
		close(fd);
		return 2;
	}

	put("verdict: SGX545 confirmed, CORE_ID ");
	put_hex8(values[find(0x001c)]);
	put(" (CONFIG ");
	put_hex(values[find(0x001c)] & 0xffff, 4);
	put(")\n");
	{
		u32 rev = values[find(0x0020)];

		put("  CORE_REVISION ");
		put_hex8(rev);
		put(" = ");
		put_dec((rev >> 16) & 0xff);
		put(".");
		put_dec((rev >> 8) & 0xff);
		put(".");
		put_dec(rev & 0xff);
		if (rev == 0x0001000du)
			put("  (Cedarview's, already in the table)");
		else if (rev == 0x0001000eu)
			put("  (the CE5300's, already in the table)");
		else
			put("  (not in the table yet)");
		put("\n  for drm/powervr_sgx/pvrsgx_core.c: .core_rev = ");
		put_hex8(rev);
		put(",\n");
	}
	put("  CLKGATESTATUS ");
	put_hex8(values[find(0x0008)]);
	put(": DPM_CLKS (bit 5) ");
	put(values[find(0x0008)] & 0x20 ? "running\n" : "gated\n");
	put("  Nothing was written.\n");

	close(fd);
	return 0;
}
