_Head:
	/* Set _Entry address */
	adr	x1, _Payload

	/* Jump to the real code */
	b	_Start

	/* Fake Linux kernel header */

_StackBase0: //has to be 0 on some devices
	/* Text Offset */
	.quad 0

_StackSize0:
	/* Image Size */
	.quad 0

	/* Flags */
	.quad 0

	/* Reserved */
	.quad 0

	/* Reserved */
	.quad 0

	/* Reserved */
	.quad 0

	/* ARM64 Magic */
	.ascii "ARM\x64"

	/* Reserved */
	.long 0

	.ascii "EDK2-MSM"

_StackBase:
	/* Text Offset */
	.quad UEFI_BASE

_StackSize:
	/* Image Size */
	.quad UEFI_SIZE

_Start:
	mov	x19, x1
	mov	x0, #1
	bl	_Paint
	mov	x4, x19
	ldr	x5, _StackBase
	cmp	x4, x5
	beq	_Entry
	ldr	x6,	_StackSize

_CopyLoop:
	ldp	x2, x3, [x4], #16
	stp	x2, x3, [x5], #16
	subs	x6, x6, #16
	b.ne	_CopyLoop
	ldr	x5, _StackBase
	mov	x0, #2
	bl	_Paint

_Entry:
	mov	x0, #3
	bl	_Paint
	br	x5

_Dead:
	/* We should never get here */
	b	_Dead

/* Debug progress marker, drawn into the 24 bit scanout buffer of the Mi A1 (0x90001000, 3 bytes per pixel, 1080 pixels per line):
   step k paints a white 48 x 60 pixel block at column (k - 1) * 50, line 1500. Step 1 first blanks lines 1480..1580. Uses x0, x10-x14. */
_Paint:
	ldr	x10, =0x90001000
	cmp	x0, #1
	b.ne	_PaintBlock
	ldr	x11, =(1480*3240)
	add	x11, x10, x11
	ldr	x12, =(100*3240)
_Blank:
	strb	wzr, [x11], #1
	subs	x12, x12, #1
	b.ne	_Blank
_PaintBlock:
	ldr	x11, =(1500*3240)
	add	x10, x10, x11
	sub	x11, x0, #1
	mov	x12, #150
	madd	x10, x11, x12, x10
	mov	x11, #60
_PaintLine:
	mov	x12, #144
	mov	x13, x10
	mov	w14, #0xff
_PaintByte:
	strb	w14, [x13], #1
	subs	x12, x12, #1
	b.ne	_PaintByte
	add	x10, x10, #3240
	subs	x11, x11, #1
	b.ne	_PaintLine
	dsb	sy
	ret
.ltorg

.text
.align 4

_Payload:
	/* Your code will get ran right after this binary */
