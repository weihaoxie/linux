// SPDX-License-Identifier: GPL-2.0
// Copyright (C) 2018 Hangzhou C-SKY Microsystems co.,ltd.

#include <linux/console.h>
#include <linux/memblock.h>
#include <linux/initrd.h>
#include <linux/of.h>
#include <linux/of_fdt.h>
#include <linux/start_kernel.h>
#include <linux/dma-map-ops.h>
#include <asm/sections.h>
#include <asm/mmu_context.h>
#include <asm/pgalloc.h>

#ifdef CONFIG_BLK_DEV_INITRD
static void __init setup_initrd(void)
{
	unsigned long size;

	if (initrd_start >= initrd_end) {
		pr_err("initrd not found or empty");
		goto disable;
	}

	if (__pa(initrd_end) > PFN_PHYS(max_low_pfn)) {
		pr_err("initrd extends beyond end of memory");
		goto disable;
	}

	size = initrd_end - initrd_start;

	if (memblock_is_region_reserved(__pa(initrd_start), size)) {
		pr_err("INITRD: 0x%08lx+0x%08lx overlaps in-use memory region",
		       __pa(initrd_start), size);
		goto disable;
	}

	memblock_reserve(__pa(initrd_start), size);

	pr_info("Initial ramdisk at: 0x%p (%lu bytes)\n",
		(void *)(initrd_start), size);

	initrd_below_start_ok = 1;

	return;

disable:
	initrd_start = initrd_end = 0;

	pr_err(" - disabling initrd\n");
}
#endif

static void __init csky_memblock_init(void)
{
	unsigned long lowmem_size = PFN_DOWN(LOWMEM_LIMIT - PHYS_OFFSET_OFFSET);
	unsigned long sseg_size = PFN_DOWN(SSEG_SIZE - PHYS_OFFSET_OFFSET);
	unsigned long max_zone_pfn[MAX_NR_ZONES] = { 0 };
	signed long size;

	memblock_reserve(__pa(_start), _end - _start);

	early_init_fdt_reserve_self();
	early_init_fdt_scan_reserved_mem();

	memblock_dump_all();

	min_low_pfn = PFN_UP(memblock_start_of_DRAM());
	max_low_pfn = max_pfn = PFN_DOWN(memblock_end_of_DRAM());

	size = max_pfn - min_low_pfn;

	if (size >= lowmem_size) {
		max_low_pfn = min_low_pfn + lowmem_size;
#ifdef CONFIG_PAGE_OFFSET_80000000
		write_mmu_msa1(read_mmu_msa0() + SSEG_SIZE);
#endif
	} else if (size > sseg_size) {
		max_low_pfn = min_low_pfn + sseg_size;
	}

#ifdef CONFIG_BLK_DEV_INITRD
	setup_initrd();
#endif

	max_zone_pfn[ZONE_NORMAL] = max_low_pfn;

	mmu_init(min_low_pfn, max_low_pfn);

#ifdef CONFIG_HIGHMEM
	max_zone_pfn[ZONE_HIGHMEM] = max_pfn;

	highstart_pfn = max_low_pfn;
	highend_pfn   = max_pfn;
#endif
	memblock_set_current_limit(PFN_PHYS(max_low_pfn));

	dma_contiguous_reserve(0);

	free_area_init(max_zone_pfn);
}

void __init setup_arch(char **cmdline_p)
{
	*cmdline_p = boot_command_line;

	console_verbose();

	pr_info("Phys. mem: %ldMB\n",
		(unsigned long) memblock_phys_mem_size()/1024/1024);

	setup_initial_init_mm(_start, _etext, _edata, _end);

	parse_early_param();

	csky_memblock_init();

	unflatten_and_copy_device_tree();

#ifdef CONFIG_SMP
	setup_smp();
#endif

	sparse_init();

	fixaddr_init();

#ifdef CONFIG_HIGHMEM
	kmap_init();
#endif
}

unsigned long va_pa_offset;
EXPORT_SYMBOL(va_pa_offset);

static inline unsigned long read_mmu_msa(void)
{
#ifdef CONFIG_PAGE_OFFSET_80000000
	return read_mmu_msa0();
#endif

#ifdef CONFIG_PAGE_OFFSET_A0000000
	return read_mmu_msa1();
#endif
}

asmlinkage __visible void __init csky_start(unsigned int unused,
					    void *dtb_start)
{
	/* Clean up bss section */
	memset(__bss_start, 0, __bss_stop - __bss_start);

	va_pa_offset = read_mmu_msa() & ~(SSEG_SIZE - 1);

	pre_trap_init();

	if (dtb_start == NULL)
		early_init_dt_scan(__dtb_start, __pa(dtb_start));
	else
		early_init_dt_scan(dtb_start, __pa(dtb_start));

	start_kernel();

	asm volatile("br .\n");
}
