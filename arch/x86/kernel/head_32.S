/* SPDX-License-Identifier: GPL-2.0 */
/*
 *
 *  Copyright (C) 1991, 1992  Linus Torvalds
 *
 *  Enhanced CPU detection and feature setting code by Mike Jagdis
 *  and Martin Mares, November 1997.
 */

.text
#include <linux/export.h>
#include <linux/threads.h>
#include <linux/init.h>
#include <linux/linkage.h>
#include <asm/segment.h>
#include <asm/page_types.h>
#include <asm/pgtable_types.h>
#include <asm/cache.h>
#include <asm/thread_info.h>
#include <asm/asm-offsets.h>
#include <asm/setup.h>
#include <asm/processor-flags.h>
#include <asm/msr-index.h>
#include <asm/cpufeatures.h>
#include <asm/percpu.h>
#include <asm/nops.h>
#include <asm/nospec-branch.h>
#include <asm/bootparam.h>
#include <asm/pgtable_32.h>

/* Physical address */
#define pa(X) ((X) - __PAGE_OFFSET)

/*
 * References to members of the new_cpu_data structure.
 */

#define X86		new_cpu_data+CPUINFO_x86
#define X86_VENDOR	new_cpu_data+CPUINFO_x86_vendor
#define X86_MODEL	new_cpu_data+CPUINFO_x86_model
#define X86_STEPPING	new_cpu_data+CPUINFO_x86_stepping
#define X86_HARD_MATH	new_cpu_data+CPUINFO_hard_math
#define X86_CPUID	new_cpu_data+CPUINFO_cpuid_level
#define X86_CAPABILITY	new_cpu_data+CPUINFO_x86_capability
#define X86_VENDOR_ID	new_cpu_data+CPUINFO_x86_vendor_id

/*
 * Worst-case size of the kernel mapping we need to make:
 * a relocatable kernel can live anywhere in lowmem, so we need to be able
 * to map all of lowmem.
 */
KERNEL_PAGES = LOWMEM_PAGES

INIT_MAP_SIZE = PAGE_TABLE_SIZE(KERNEL_PAGES) * PAGE_SIZE
RESERVE_BRK(pagetables, INIT_MAP_SIZE)

/*
 * 32-bit kernel entrypoint; only used by the boot CPU.  On entry,
 * %esi points to the real-mode code as a 32-bit pointer.
 * CS and DS must be 4 GB flat segments, but we don't depend on
 * any particular GDT layout, because we load our own as soon as we
 * can.
 */
__HEAD
SYM_CODE_START(startup_32)
	movl pa(initial_stack),%ecx
	
/*
 * Set segments to known values.
 */
	lgdt pa(boot_gdt_descr)
	movl $(__BOOT_DS),%eax
	movl %eax,%ds
	movl %eax,%es
	movl %eax,%fs
	movl %eax,%gs
	movl %eax,%ss
	leal -__PAGE_OFFSET(%ecx),%esp

/*
 * Clear BSS first so that there are no surprises...
 */
	cld
	xorl %eax,%eax
	movl $pa(__bss_start),%edi
	movl $pa(__bss_stop),%ecx
	subl %edi,%ecx
	shrl $2,%ecx
	rep stosl
/*
 * Copy bootup parameters out of the way.
 * Note: %esi still has the pointer to the real-mode data.
 * With the kexec as boot loader, parameter segment might be loaded beyond
 * kernel image and might not even be addressable by early boot page tables.
 * (kexec on panic case). Hence copy out the parameters before initializing
 * page tables.
 */
	movl $pa(boot_params),%edi
	movl $(PARAM_SIZE/4),%ecx
	cld
	rep movsl
	movl pa(boot_params) + NEW_CL_POINTER,%esi
	andl %esi,%esi
	jz 1f			# No command line
	movl $pa(boot_command_line),%edi
	movl $(COMMAND_LINE_SIZE/4),%ecx
	rep movsl
1:

#ifdef CONFIG_OLPC
	/* save OFW's pgdir table for later use when calling into OFW */
	movl %cr3, %eax
	movl %eax, pa(olpc_ofw_pgd)
#endif

	/* Create early pagetables. */
	call  mk_early_pgtbl_32

	/* Do early initialization of the fixmap area */
	movl $pa(initial_pg_fixmap)+PDE_IDENT_ATTR,%eax
#ifdef  CONFIG_X86_PAE
#define KPMDS (((-__PAGE_OFFSET) >> 30) & 3) /* Number of kernel PMDs */
	movl %eax,pa(initial_pg_pmd+0x1000*KPMDS-8)
#else
	movl %eax,pa(initial_page_table+0xffc)
#endif

	jmp .Ldefault_entry
SYM_CODE_END(startup_32)

/*
 * Non-boot CPU entry point; entered from trampoline.S
 * We can't lgdt here, because lgdt itself uses a data segment, but
 * we know the trampoline has already loaded the boot_gdt for us.
 *
 * If cpu hotplug is not supported then this code can go in init section
 * which will be freed later
 */
SYM_FUNC_START(startup_32_smp)
	cld
	movl $(__BOOT_DS),%eax
	movl %eax,%ds
	movl %eax,%es
	movl %eax,%fs
	movl %eax,%gs
	movl pa(initial_stack),%ecx
	movl %eax,%ss
	leal -__PAGE_OFFSET(%ecx),%esp

.Ldefault_entry:
	movl $(CR0_STATE & ~X86_CR0_PG),%eax
	movl %eax,%cr0

/*
 * We want to start out with EFLAGS unambiguously cleared. Some BIOSes leave
 * bits like NT set. This would confuse the debugger if this code is traced. So
 * initialize them properly now before switching to protected mode. That means
 * DF in particular (even though we have cleared it earlier after copying the
 * command line) because GCC expects it.
 */
	pushl $0
	popfl

/*
 * New page tables may be in 4Mbyte page mode and may be using the global pages.
 *
 * NOTE! If we are on a 486 we may have no cr4 at all! Specifically, cr4 exists
 * if and only if CPUID exists and has flags other than the FPU flag set.
 */
	movl $-1,pa(X86_CPUID)		# preset CPUID level
	movl $X86_EFLAGS_ID,%ecx
	pushl %ecx
	popfl				# set EFLAGS=ID
	pushfl
	popl %eax			# get EFLAGS
	testl $X86_EFLAGS_ID,%eax	# did EFLAGS.ID remained set?
	jz .Lenable_paging		# hw disallowed setting of ID bit
					# which means no CPUID and no CR4

	xorl %eax,%eax
	cpuid
	movl %eax,pa(X86_CPUID)		# save largest std CPUID function

	movl $1,%eax
	cpuid
	andl $~1,%edx			# Ignore CPUID.FPU
	jz .Lenable_paging		# No flags or only CPUID.FPU = no CR4

	movl pa(mmu_cr4_features),%eax
	movl %eax,%cr4

	testb $X86_CR4_PAE, %al		# check if PAE is enabled
	jz .Lenable_paging

	/* Check if extended functions are implemented */
	movl $0x80000000, %eax
	cpuid
	/* Value must be in the range 0x80000001 to 0x8000ffff */
	subl $0x80000001, %eax
	cmpl $(0x8000ffff-0x80000001), %eax
	ja .Lenable_paging

	/* Clear bogus XD_DISABLE bits */
	call verify_cpu

	mov $0x80000001, %eax
	cpuid
	/* Execute Disable bit supported? */
	btl $(X86_FEATURE_NX & 31), %edx
	jnc .Lenable_paging

	/* Setup EFER (Extended Feature Enable Register) */
	movl $MSR_EFER, %ecx
	rdmsr

	btsl $_EFER_NX, %eax
	/* Make changes effective */
	wrmsr

.Lenable_paging:

/*
 * Enable paging
 */
	movl $pa(initial_page_table), %eax
	movl %eax,%cr3		/* set the page table pointer.. */
	movl $CR0_STATE,%eax
	movl %eax,%cr0		/* ..and set paging (PG) bit */
	ljmp $__BOOT_CS,$1f	/* Clear prefetch and normalize %eip */
1:
	/* Shift the stack pointer to a virtual address */
	addl $__PAGE_OFFSET, %esp

/*
 * Check if it is 486
 */
	movb $4,X86			# at least 486
	cmpl $-1,X86_CPUID
	je .Lis486

	/* get vendor info */
	xorl %eax,%eax			# call CPUID with 0 -> return vendor ID
	cpuid
	movl %eax,X86_CPUID		# save CPUID level
	movl %ebx,X86_VENDOR_ID		# lo 4 chars
	movl %edx,X86_VENDOR_ID+4	# next 4 chars
	movl %ecx,X86_VENDOR_ID+8	# last 4 chars

	orl %eax,%eax			# do we have processor info as well?
	je .Lis486

	movl $1,%eax		# Use the CPUID instruction to get CPU type
	cpuid
	movb %al,%cl		# save reg for future use
	andb $0x0f,%ah		# mask processor family
	movb %ah,X86
	andb $0xf0,%al		# mask model
	shrb $4,%al
	movb %al,X86_MODEL
	andb $0x0f,%cl		# mask mask revision
	movb %cl,X86_STEPPING
	movl %edx,X86_CAPABILITY

.Lis486:
	movl $0x50022,%ecx	# set AM, WP, NE and MP
	movl %cr0,%eax
	andl $0x80000011,%eax	# Save PG,PE,ET
	orl %ecx,%eax
	movl %eax,%cr0

	lgdt early_gdt_descr
	ljmp $(__KERNEL_CS),$1f
1:	movl $(__KERNEL_DS),%eax	# reload all the segment registers
	movl %eax,%ss			# after changing gdt.

	movl $(__USER_DS),%eax		# DS/ES contains default USER segment
	movl %eax,%ds
	movl %eax,%es

	movl $(__KERNEL_PERCPU), %eax
	movl %eax,%fs			# set this cpu's percpu

	xorl %eax,%eax
	movl %eax,%gs			# clear possible garbage in %gs

	xorl %eax,%eax			# Clear LDT
	lldt %ax

	call *(initial_code)
1:	jmp 1b
SYM_FUNC_END(startup_32_smp)

#include "verify_cpu.S"

__INIT
SYM_FUNC_START(early_idt_handler_array)
	# 36(%esp) %eflags
	# 32(%esp) %cs
	# 28(%esp) %eip
	# 24(%rsp) error code
	i = 0
	.rept NUM_EXCEPTION_VECTORS
	.if ((EXCEPTION_ERRCODE_MASK >> i) & 1) == 0
	pushl $0		# Dummy error code, to make stack frame uniform
	.endif
	pushl $i		# 20(%esp) Vector number
	jmp early_idt_handler_common
	i = i + 1
	.fill early_idt_handler_array + i*EARLY_IDT_HANDLER_SIZE - ., 1, 0xcc
	.endr
SYM_FUNC_END(early_idt_handler_array)
	
SYM_CODE_START_LOCAL(early_idt_handler_common)
	/*
	 * The stack is the hardware frame, an error code or zero, and the
	 * vector number.
	 */
	cld

	incl %ss:early_recursion_flag

	/* The vector number is in pt_regs->gs */

	cld
	pushl	%fs		/* pt_regs->fs (__fsh varies by model) */
	pushl	%es		/* pt_regs->es (__esh varies by model) */
	pushl	%ds		/* pt_regs->ds (__dsh varies by model) */
	pushl	%eax		/* pt_regs->ax */
	pushl	%ebp		/* pt_regs->bp */
	pushl	%edi		/* pt_regs->di */
	pushl	%esi		/* pt_regs->si */
	pushl	%edx		/* pt_regs->dx */
	pushl	%ecx		/* pt_regs->cx */
	pushl	%ebx		/* pt_regs->bx */

	/* Fix up DS and ES */
	movl	$(__KERNEL_DS), %ecx
	movl	%ecx, %ds
	movl	%ecx, %es

	/* Load the vector number into EDX */
	movl	PT_GS(%esp), %edx

	/* Load GS into pt_regs->gs (and maybe clobber __gsh) */
	movw	%gs, PT_GS(%esp)

	movl	%esp, %eax	/* args are pt_regs (EAX), trapnr (EDX) */
	call	early_fixup_exception

	popl	%ebx		/* pt_regs->bx */
	popl	%ecx		/* pt_regs->cx */
	popl	%edx		/* pt_regs->dx */
	popl	%esi		/* pt_regs->si */
	popl	%edi		/* pt_regs->di */
	popl	%ebp		/* pt_regs->bp */
	popl	%eax		/* pt_regs->ax */
	popl	%ds		/* pt_regs->ds (always ignores __dsh) */
	popl	%es		/* pt_regs->es (always ignores __esh) */
	popl	%fs		/* pt_regs->fs (always ignores __fsh) */
	popl	%gs		/* pt_regs->gs (always ignores __gsh) */
	decl	%ss:early_recursion_flag
	addl	$4, %esp	/* pop pt_regs->orig_ax */
	iret
SYM_CODE_END(early_idt_handler_common)

/* This is the default interrupt "handler" :-) */
SYM_FUNC_START(early_ignore_irq)
	cld
#ifdef CONFIG_PRINTK
	pushl %eax
	pushl %ecx
	pushl %edx
	pushl %es
	pushl %ds
	movl $(__KERNEL_DS),%eax
	movl %eax,%ds
	movl %eax,%es
	cmpl $2,early_recursion_flag
	je hlt_loop
	incl early_recursion_flag
	pushl 16(%esp)
	pushl 24(%esp)
	pushl 32(%esp)
	pushl 40(%esp)
	pushl $int_msg
	call _printk

	call dump_stack

	addl $(5*4),%esp
	popl %ds
	popl %es
	popl %edx
	popl %ecx
	popl %eax
#endif
	iret

hlt_loop:
	hlt
	jmp hlt_loop
SYM_FUNC_END(early_ignore_irq)

__INITDATA
	.align 4
SYM_DATA(early_recursion_flag, .long 0)

__REFDATA
	.align 4
SYM_DATA(initial_code,		.long i386_start_kernel)

#ifdef CONFIG_MITIGATION_PAGE_TABLE_ISOLATION
#define	PGD_ALIGN	(2 * PAGE_SIZE)
#define PTI_USER_PGD_FILL	1024
#else
#define	PGD_ALIGN	(PAGE_SIZE)
#define PTI_USER_PGD_FILL	0
#endif
/*
 * BSS section
 */
__PAGE_ALIGNED_BSS
	.align PGD_ALIGN
#ifdef CONFIG_X86_PAE
.globl initial_pg_pmd
initial_pg_pmd:
	.fill 1024*KPMDS,4,0
#else
.globl initial_page_table
initial_page_table:
	.fill 1024,4,0
#endif
	.align PGD_ALIGN
initial_pg_fixmap:
	.fill 1024,4,0
.globl swapper_pg_dir
	.align PGD_ALIGN
swapper_pg_dir:
	.fill 1024,4,0
	.fill PTI_USER_PGD_FILL,4,0
.globl empty_zero_page
empty_zero_page:
	.fill 4096,1,0
EXPORT_SYMBOL(empty_zero_page)

/*
 * This starts the data section.
 */
#ifdef CONFIG_X86_PAE
__PAGE_ALIGNED_DATA
	/* Page-aligned for the benefit of paravirt? */
	.align PGD_ALIGN
SYM_DATA_START(initial_page_table)
	.long	pa(initial_pg_pmd+PGD_IDENT_ATTR),0	/* low identity map */
# if KPMDS == 3
	.long	pa(initial_pg_pmd+PGD_IDENT_ATTR),0
	.long	pa(initial_pg_pmd+PGD_IDENT_ATTR+0x1000),0
	.long	pa(initial_pg_pmd+PGD_IDENT_ATTR+0x2000),0
# elif KPMDS == 2
	.long	0,0
	.long	pa(initial_pg_pmd+PGD_IDENT_ATTR),0
	.long	pa(initial_pg_pmd+PGD_IDENT_ATTR+0x1000),0
# elif KPMDS == 1
	.long	0,0
	.long	0,0
	.long	pa(initial_pg_pmd+PGD_IDENT_ATTR),0
# else
#  error "Kernel PMDs should be 1, 2 or 3"
# endif
	.align PAGE_SIZE		/* needs to be page-sized too */

#ifdef CONFIG_MITIGATION_PAGE_TABLE_ISOLATION
	/*
	 * PTI needs another page so sync_initial_pagetable() works correctly
	 * and does not scribble over the data which is placed behind the
	 * actual initial_page_table. See clone_pgd_range().
	 */
	.fill 1024, 4, 0
#endif

SYM_DATA_END(initial_page_table)
#endif

.data
.balign 4
SYM_DATA(initial_stack, .long __top_init_kernel_stack)

__INITRODATA
int_msg:
	.asciz "Unknown interrupt or fault at: %p %p %p\n"

#include "../xen/xen-head.S"

/*
 * The IDT and GDT 'descriptors' are a strange 48-bit object
 * only used by the lidt and lgdt instructions. They are not
 * like usual segment descriptors - they consist of a 16-bit
 * segment size, and 32-bit linear address value:
 */

	.data
	ALIGN
# early boot GDT descriptor (must use 1:1 address mapping)
	.word 0				# 32 bit align gdt_desc.address
SYM_DATA_START_LOCAL(boot_gdt_descr)
	.word __BOOT_DS+7
	.long boot_gdt - __PAGE_OFFSET
SYM_DATA_END(boot_gdt_descr)

# boot GDT descriptor (later on used by CPU#0):
	.word 0				# 32 bit align gdt_desc.address
SYM_DATA_START(early_gdt_descr)
	.word GDT_ENTRIES*8-1
	.long gdt_page			/* Overwritten for secondary CPUs */
SYM_DATA_END(early_gdt_descr)

/*
 * The boot_gdt must mirror the equivalent in setup.S and is
 * used only for booting.
 */
	.align L1_CACHE_BYTES
SYM_DATA_START(boot_gdt)
	.fill GDT_ENTRY_BOOT_CS,8,0
	.quad 0x00cf9a000000ffff	/* kernel 4GB code at 0x00000000 */
	.quad 0x00cf92000000ffff	/* kernel 4GB data at 0x00000000 */
SYM_DATA_END(boot_gdt)
