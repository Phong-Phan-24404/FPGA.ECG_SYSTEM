// SPDX-License-Identifier: GPL-2.0
/*
 * pl_dmabuf -- a physically contiguous, DMA-coherent buffer for user space.
 *
 * The AXI DMA in this design is a bus master: it is handed a raw physical
 * address and writes straight to DDR, bypassing the MMU entirely. A user-space
 * program therefore cannot use ordinary malloc'd memory, which is virtually
 * contiguous but physically scattered, and whose pages the kernel may move.
 *
 * This module allocates one coherent buffer from CMA, reports its physical
 * address, and lets a process mmap it. dma_alloc_coherent also removes the
 * cache-maintenance problem: the mapping is uncached on arm64, so what the CPU
 * writes is what the DMA reads, with no flush/invalidate dance.
 *
 * The 32-bit DMA mask is not incidental. The KV260's DDR extends past 4 GiB
 * (/proc/iomem shows System RAM up to 0x8_7fff_ffff), while the AXI DMA is
 * built with xlnx,addrwidth = 32. Without the mask the allocator could hand
 * back a buffer the hardware cannot address, and the transfer would silently
 * land somewhere else.
 */
#include <linux/module.h>
#include <linux/miscdevice.h>
#include <linux/platform_device.h>
#include <linux/dma-mapping.h>
#include <linux/fs.h>
#include <linux/mm.h>

#define DRV_NAME "pl_dmabuf"

static unsigned int buf_size = 1u << 20;      /* 1 MiB is ample for 748 B in, 10 B out */
module_param(buf_size, uint, 0444);
MODULE_PARM_DESC(buf_size, "coherent buffer size in bytes");

/* Published so user space can read the bus address without a custom ioctl:
 * /sys/module/pl_dmabuf/parameters/phys_addr */
static unsigned long phys_addr;
module_param(phys_addr, ulong, 0444);
MODULE_PARM_DESC(phys_addr, "physical address of the buffer (read-only)");

static struct platform_device *pdev;
static void      *cpu_addr;
static dma_addr_t dma_handle;

static int pl_dmabuf_mmap(struct file *filp, struct vm_area_struct *vma)
{
	size_t len = vma->vm_end - vma->vm_start;

	if (vma->vm_pgoff != 0)
		return -EINVAL;
	if (len > buf_size)
		return -EINVAL;

	/* dma_mmap_coherent applies the same attributes the kernel used for the
	 * allocation, so the user mapping is uncached exactly as the kernel's is.
	 * Hand-rolling this with remap_pfn_range is what produces the classic
	 * "DMA wrote the data but the CPU still sees stale bytes" bug. */
	return dma_mmap_coherent(&pdev->dev, vma, cpu_addr, dma_handle, len);
}

static const struct file_operations pl_dmabuf_fops = {
	.owner = THIS_MODULE,
	.mmap  = pl_dmabuf_mmap,
	.llseek = noop_llseek,
};

static struct miscdevice pl_dmabuf_misc = {
	.minor = MISC_DYNAMIC_MINOR,
	.name  = DRV_NAME,
	.fops  = &pl_dmabuf_fops,
	.mode  = 0666,
};

static int __init pl_dmabuf_init(void)
{
	int ret;

	pdev = platform_device_register_simple(DRV_NAME, -1, NULL, 0);
	if (IS_ERR(pdev))
		return PTR_ERR(pdev);

	ret = dma_set_mask_and_coherent(&pdev->dev, DMA_BIT_MASK(32));
	if (ret) {
		pr_err(DRV_NAME ": no 32-bit DMA mask: %d\n", ret);
		goto err_pdev;
	}

	cpu_addr = dma_alloc_coherent(&pdev->dev, buf_size, &dma_handle, GFP_KERNEL);
	if (!cpu_addr) {
		pr_err(DRV_NAME ": could not allocate %u bytes of coherent DMA memory\n",
		       buf_size);
		ret = -ENOMEM;
		goto err_pdev;
	}

	/* The mask should already guarantee this; check anyway, because a buffer
	 * above 4 GiB would fail silently at run time rather than here. */
	if ((u64)dma_handle + buf_size > 0x100000000ULL) {
		pr_err(DRV_NAME ": buffer at 0x%llx is beyond the DMA's 32-bit reach\n",
		       (unsigned long long)dma_handle);
		ret = -ERANGE;
		goto err_dma;
	}

	phys_addr = (unsigned long)dma_handle;

	ret = misc_register(&pl_dmabuf_misc);
	if (ret)
		goto err_dma;

	pr_info(DRV_NAME ": %u bytes at phys 0x%08lx, /dev/%s\n",
		buf_size, phys_addr, DRV_NAME);
	return 0;

err_dma:
	dma_free_coherent(&pdev->dev, buf_size, cpu_addr, dma_handle);
err_pdev:
	platform_device_unregister(pdev);
	return ret;
}

static void __exit pl_dmabuf_exit(void)
{
	misc_deregister(&pl_dmabuf_misc);
	dma_free_coherent(&pdev->dev, buf_size, cpu_addr, dma_handle);
	platform_device_unregister(pdev);
	pr_info(DRV_NAME ": removed\n");
}

module_init(pl_dmabuf_init);
module_exit(pl_dmabuf_exit);

MODULE_LICENSE("GPL");
MODULE_DESCRIPTION("Coherent CMA buffer exported to user space for the KV260 CNN accelerator");
