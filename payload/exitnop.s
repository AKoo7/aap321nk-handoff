	.syntax unified
	.arch armv7-a
	.arm
	.section .exitnop,"ax",%progbits
	.global idu_exit
idu_exit:
	mov	r0, #0
	bx	lr
