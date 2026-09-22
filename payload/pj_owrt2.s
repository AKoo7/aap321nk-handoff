	.syntax unified
	.arch armv7-a
	.arch_extension sec
	.arm
	.section .probe,"ax",%progbits
	.global idu_probe
@ v2: mask IRQ/FIQ, flush caches over the staged ranges, then the TZ monitor-boot SMC.
@ Staged: image 0x44000000 (27.1MB, VA 0x84000000 @ PAGE_OFFSET 0x80000000/PHYS 0x40000000)
@         dtb   0x48C00000 (26,997B -> 32KB window)
@         desc  0x48D00000 (80B -> 4KB window)
idu_probe:
	push	{r4-r8, lr}
	cpsid	if
	mov	r0, #0
	mcr	p15, 0, r0, c7, c5, 0		@ ICIALLU (invalidate I-cache)
	dsb	sy
	ldr	r4, =0x84000000
	ldr	r5, =0x86000000
	bl	flush_range
	ldr	r4, =0x88c00000
	ldr	r5, =0x88c08000
	bl	flush_range
	ldr	r4, =0x88d00000
	ldr	r5, =0x88d01000
	bl	flush_range
	dsb	sy
	isb	sy
	ldr	r0, =0x0200010f		@ SiP SCM_SVC_BOOT/0x0F
	mov	r1, #0x12		@ U-Boot's command selector
	ldr	r2, =0x48d00000		@ descriptor {F0=DTB, 64 zeros, F1=entry}
	mov	r3, #0x50		@ 80 bytes
	mov	r4, #0
	mov	r5, #0
	ldr	r6, =0x48d01000		@ scratch ptr (as U-Boot passes)
	mov	r7, #0
	smc	#0
	cpsie	if
	pop	{r4-r8, pc}		@ returns TZ's r0 -> loader errno is the diagnostic

flush_range:
	mov	r6, r4
1:	mcr	p15, 0, r6, c7, c14, 1		@ DCCIMVAC (clean+invalidate D by MVA)
	mcr	p15, 0, r6, c7, c5, 1		@ ICIMVAU (invalidate I by MVA)
	add	r6, r6, #64
	cmp	r6, r5
	blo	1b
	bx	lr
	.balign 4
	.ltorg
