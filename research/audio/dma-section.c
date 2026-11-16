/*
 * DMA bring-up.
 *
 * There are two DesignWare AHB DMACs in the LPE.  DMA0 at 0xFFAF8000 is the
 * DSP's own and is NOT reachable from the CPU (Android intel_soc_dump.c marks
 * it "invisible to IA"); that is why its CFG/ChEn never kept what we wrote.
 * DMA1 at 0xFFAF0000 is the one the host drives: the Clover Trail+ firmware
 * loader uses it (PCI DMAC1, 4 channels) and so does Windows (isstrtc.sys
 * builds its "Dmac" object on 0xFFAF0000, len 0x8000, 0x58-byte channels).
 *
 * Mem-to-mem as intel_mid_dma.c programs it: CFG_LO = 0, CFG_HI = 0,
 * DmaCfgReg = 1, then ChEn = (1 << ch) | (1 << (ch + 8)).  Interrupt status
 * is cleared through the Clear* registers (Raw* are read-only).
 * A transfer only counts as done if RawTfr has our bit, RawErr does not, and
 * the data is really where it should be.
 */
#define DMA_RAW_ERR		0x2E0
#define DMA_CLEAR_TFR		0x338
#define DMA_CLEAR_BLOCK		0x340
#define DMA_CLEAR_SRC		0x348
#define DMA_CLEAR_DST		0x350
#define DMA_CLEAR_ERR		0x358
#define DMA_COMP_PARAMS_1	0x3F4
#define DMA_COMP_VERSION	0x3F8
#define DMA_COMP_TYPE		0x3FC

static void clv_dma_dump(struct clv_sst *sst, void __iomem *d, const char *tag)
{
	dev_info(sst->dev,
		 "DMA[%s]: DmaCfg=%#x ChEn=%#x CTL=%#x/%#x CFG=%#x/%#x SAR=%#x DAR=%#x RawTfr=%#x RawErr=%#x\n",
		 tag, readl(d + DMA_CFG_REG), readl(d + DMA_CH_EN),
		 readl(d + DMA_CTL_LO), readl(d + DMA_CTL_HI),
		 readl(d + DMA_CFG_LO), readl(d + DMA_CFG_HI),
		 readl(d + DMA_SAR), readl(d + DMA_DAR),
		 readl(d + DMA_RAW_TFR), readl(d + DMA_RAW_ERR));
}

static int clv_dma_run(struct clv_sst *sst, void __iomem *d, u32 src, u32 dst,
		       unsigned int bytes)
{
	u32 words = bytes / 4, bit = BIT(DMA_TEST_CHAN), tfr = 0, err = 0;
	int i, ret = 0;

	if (!words || words > 0xFFF)
		return -EINVAL;

	writel(1, d + DMA_CFG_REG);			/* controller on */
	writel(bit, d + DMA_CLEAR_TFR);
	writel(bit, d + DMA_CLEAR_BLOCK);
	writel(bit, d + DMA_CLEAR_SRC);
	writel(bit, d + DMA_CLEAR_DST);
	writel(bit, d + DMA_CLEAR_ERR);

	writel(src, d + DMA_SAR);
	writel(dst, d + DMA_DAR);
	writel(0, d + DMA_LLP);
	writel(DMA_CTL_LO_M2M, d + DMA_CTL_LO);
	writel(words, d + DMA_CTL_HI);
	writel(0, d + DMA_CFG_LO);			/* mem2mem: no handshake */
	writel(0, d + DMA_CFG_HI);
	wmb();
	clv_dma_dump(sst, d, "armed");

	writel(bit | (bit << 8), d + DMA_CH_EN);

	for (i = 0; i < 500; i++) {			/* 500 * 100us = 50 ms */
		tfr = readl(d + DMA_RAW_TFR) & bit;
		err = readl(d + DMA_RAW_ERR) & bit;
		if (tfr || err)
			break;
		udelay(100);
	}
	clv_dma_dump(sst, d, "after");

	if (err) {
		dev_warn(sst->dev, "DMA: %#x -> %#x: bus error\n", src, dst);
		ret = -EIO;
	} else if (!tfr) {
		dev_warn(sst->dev, "DMA: %#x -> %#x: no completion in 50 ms\n",
			 src, dst);
		ret = -ETIMEDOUT;
	}
	if (readl(d + DMA_CH_EN) & bit)
		writel(bit << 8, d + DMA_CH_EN);	/* force the channel off */
	writel(bit, d + DMA_CLEAR_TFR);
	writel(bit, d + DMA_CLEAR_ERR);
	writel(0, d + DMA_CFG_REG);
	return ret;
}

static const u32 clv_pattern[4] = { 0x11223344, 0x55667788, 0x99AABBCC, 0xDDEEFF00 };

static bool clv_check(struct clv_sst *sst, const char *what, const u32 *got)
{
	bool ok = !memcmp(got, clv_pattern, sizeof(clv_pattern));

	if (ok)
		dev_info(sst->dev, "DMA: %s VERIFIED\n", what);
	else
		dev_warn(sst->dev, "DMA: %s mismatch %#x %#x %#x %#x\n", what,
			 got[0], got[1], got[2], got[3]);
	return ok;
}

/*
 * mode: "id1"  read DMA1 id/params only
 *       "ddr0" / "ddr1"  DDR -> DDR on DMA0 / DMA1
 *       "sram1"  DDR -> LPE SRAM 0xFFFC0100 on DMA1 (checked by CPU)
 *       "iram1" / "dram1"  DDR -> DSP RAM -> DDR on DMA1 (CPU never
 *                touches the DSP RAM)
 */
static void clv_dma_test(struct clv_sst *sst, const char *mode)
{
	void __iomem *d = sst->dmac1;
	u32 *buf, back[4];
	dma_addr_t phys;
	u32 ram = 0;
	int i;

	if (!strcmp(mode, "id1")) {
		dev_info(sst->dev, "DMA1: version=%#x type=%#x params1=%#x\n",
			 readl(d + DMA_COMP_VERSION), readl(d + DMA_COMP_TYPE),
			 readl(d + DMA_COMP_PARAMS_1));
		return;
	}
	if (!strcmp(mode, "ddr0"))
		d = sst->dmac;

	/* buf[0..3] = source, buf[64..67] = destination */
	buf = dma_alloc_coherent(sst->dev, PAGE_SIZE, &phys, GFP_KERNEL);
	if (!buf) {
		dev_err(sst->dev, "DMA: no coherent buffer\n");
		return;
	}
	memset(buf, 0, PAGE_SIZE);
	memcpy(buf, clv_pattern, sizeof(clv_pattern));
	wmb();

	if (!strcmp(mode, "ddr0") || !strcmp(mode, "ddr1")) {
		if (!clv_dma_run(sst, d, phys, phys + 0x100, 16))
			clv_check(sst, mode, buf + 64);
	} else if (!strcmp(mode, "sram1")) {
		for (i = 0; i < 4; i++)
			writel(0, sst->sram + 0x100 + i * 4);
		wmb();
		if (!clv_dma_run(sst, d, phys, (u32)CLV_SRAM_BASE + 0x100, 16)) {
			for (i = 0; i < 4; i++)
				back[i] = readl(sst->sram + 0x100 + i * 4);
			clv_check(sst, "DDR->SRAM", back);
		}
	} else {
		ram = !strcmp(mode, "iram1") ? CLV_IRAM_BASE : CLV_DRAM_BASE;
		if (!clv_dma_run(sst, d, phys, ram, 16) &&
		    !clv_dma_run(sst, d, ram, phys + 0x100, 16))
			clv_check(sst, mode, buf + 64);
	}
	dma_free_coherent(sst->dev, PAGE_SIZE, buf, phys);
}

static ssize_t dma_test_write(struct file *f, const char __user *ubuf,
			      size_t len, loff_t *off)
{
	struct clv_sst *sst = clv_sst_g;
	static const char * const modes[] = {
		"id1", "ddr0", "ddr1", "sram1", "iram1", "dram1",
	};
	char buf[8] = {};
	unsigned int i;

	if (!sst)
		return -ENODEV;
	if (len > sizeof(buf) - 1)
		return -EINVAL;
	if (copy_from_user(buf, ubuf, len))
		return -EFAULT;
	buf[len] = 0;
	for (i = 0; i < ARRAY_SIZE(modes); i++) {
		if (sysfs_streq(buf, modes[i])) {
			clv_dma_test(sst, modes[i]);
			return len;
		}
	}
	return -EINVAL;
}

static const struct file_operations dma_test_fops = {
	.owner = THIS_MODULE,
	.write = dma_test_write,
	.llseek = noop_llseek,
};
