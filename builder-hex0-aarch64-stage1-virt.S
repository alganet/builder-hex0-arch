# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: Apache-2.0
#
# Builder-hex0 AArch64 Stage 1
#
# Board-specific hex0 compiler bootloader for QEMU virt.
# Loaded by QEMU -kernel (x0=dtb_ptr).
# Reads hex0 source from disk sector 0, compiles to binary at 0x40210000,
# jumps there with x0 = next disk sector, x1 = DTB pointer.
#
# Uses VirtIO MMIO v1 (legacy) protocol.
#
# Registers (callee-saved x19-x28):
#   x19 = hex state (0=first nibble, 1=have first)
#   x20 = current disk sector
#   x21 = offset in buffer (0-511, init 512 to force read)
#   x22 = VirtIO MMIO base
#   x23 = VirtIO struct base (0x40500000)
#   x24 = output write pointer
#   x25 = high nibble accumulator
#   x26 = sector buffer (x23+0x3000)
#   x27 = DTB pointer (from QEMU x0)
#   x28 = saved lr in next_byte

_start:
    mov x27, x0                      ; save DTB pointer
    movz x0, #0x6800, lsl #16
    mov sp, x0                       ; sp = 0x68000000
    movz x23, #0x4050, lsl #16       ; x23 = 0x40500000

    ; Scan VirtIO MMIO 0x0A000000..0x0A004000 (step 0x200, 32 slots)
    movz x22, #0x0A00, lsl #16       ; x22 = 0x0A000000
scan:
    ldr w0, [x22]                    ; read magic
    movz w1, #0x6976
    movk w1, #0x7472, lsl #16        ; w1 = 0x74726976
    cmp w0, w1
    b.ne scan_next
    ldr w0, [x22, #8]                ; read device ID
    cmp w0, #2
    b.eq found
scan_next:
    add x22, x22, #0x200
    movz x1, #0x4000
    movk x1, #0x0A00, lsl #16        ; x1 = 0x0A004000
    cmp x22, x1
    b.lt scan
halt:
    b halt

found:
    ; Legacy VirtIO v1 init
    movz w0, #3
    str w0, [x22, #0x70]             ; ACKNOWLEDGE|DRIVER
    movz w0, #0x1000
    str w0, [x22, #0x28]             ; GuestPageSize=4096
    str w0, [x22, #0x3C]             ; QueueAlign=4096
    movz w0, #8
    str w0, [x22, #0x38]             ; queue size=8
    lsr x0, x23, #12
    str w0, [x22, #0x40]             ; QueuePFN = x23/4096
    movz w0, #7
    str w0, [x22, #0x70]             ; DRIVER_OK

    ; x26 = sector buffer at x23+0x3000
    add x26, x23, #0x3000

    ; Init compiler state
    movz x24, #0x4021, lsl #16       ; x24 = 0x40210000 (output)
    movz x19, #0                     ; state
    movz x20, #0                     ; sector
    movz x21, #512                   ; offset (force first read)

    ; --- Hex0 main loop ---
hex0_loop:
    bl next_byte
    cbz w0, hex0_done
    ; Whitespace: anything <= 0x20
    cmp w0, #0x21
    b.lt hex0_loop
    ; Comments
    cmp w0, #0x23
    b.eq skip_comment
    cmp w0, #0x3B
    b.eq skip_comment
    ; Force uppercase: if >= 'a', subtract 0x20
    cmp w0, #0x61
    b.lt no_lower
    sub w0, w0, #0x20
no_lower:
    ; Parse hex: '0'-'9' then 'A'-'F'
    sub w1, w0, #0x30
    cmp w1, #0
    b.lt hex0_loop                   ; < '0'
    cmp w1, #10
    b.lt got_nibble                  ; 0-9
    sub w1, w1, #17                  ; 'A'->0, 'F'->5
    cmp w1, #6
    b.hs hex0_loop                   ; rejects gap and > 'F' (unsigned)
    add w1, w1, #10                  ; 0->10, 5->15
got_nibble:
    ; w1 = nibble (0-15)
    cbnz w19, second_nibble
    lsl w25, w1, #4
    movz w19, #1
    b hex0_loop
second_nibble:
    orr w1, w25, w1
    strb w1, [x24]
    add x24, x24, #1
    movz w19, #0
    b hex0_loop

skip_comment:
    bl next_byte
    cbz w0, hex0_done
    cmp w0, #0x0A
    b.ne skip_comment
    b hex0_loop

hex0_done:
    mov x0, x20
    mov x1, x27                      ; pass DTB pointer to stage 2
    movz x2, #0x4021, lsl #16        ; x2 = 0x40210000
    br x2

; --- next_byte: return next byte in w0 ---
next_byte:
    cmp w21, #512
    b.lt nb_ready
    mov x28, lr
    bl read_sector
    mov lr, x28
    add x20, x20, #1
    movz x21, #0
nb_ready:
    ldrb w0, [x26, x21]
    add x21, x21, #1
    ret

; --- read_sector: read sector x20 via VirtIO into x26 ---
read_sector:
    ; Header at x23+0x2000
    add x2, x23, #0x2000
    str xzr, [x2]                    ; type=0 (READ), reserved=0
    str x20, [x2, #8]               ; sector number

    ; Descriptor 0: header (x2, 16B, NEXT, next=1)
    str x2, [x23]
    movz w0, #16
    str w0, [x23, #8]
    movz w0, #1
    strh w0, [x23, #12]
    strh w0, [x23, #14]

    ; Descriptor 1: data (x26, 512B, NEXT|WRITE, next=2)
    str x26, [x23, #16]
    movz w0, #512
    str w0, [x23, #24]
    movz w0, #3
    strh w0, [x23, #28]
    movz w0, #2
    strh w0, [x23, #30]

    ; Descriptor 2: status (x2+0x10, 1B, WRITE)
    add x0, x2, #0x10
    str x0, [x23, #32]
    movz w0, #1
    str w0, [x23, #40]
    movz w0, #2
    strh w0, [x23, #44]
    strh wzr, [x23, #46]

    ; Save used.idx, update avail ring
    add x0, x23, #0x1000
    ldrh w1, [x0, #2]               ; w1 = initial used.idx
    add x0, x23, #0x80
    ldrh w3, [x0, #2]
    and w2, w3, #7
    lsl w2, w2, #1
    add w2, w2, #4
    add x2, x0, x2
    strh wzr, [x2]
    add w3, w3, #1
    strh w3, [x0, #2]

    dsb sy
    str wzr, [x22, #0x50]           ; notify

    add x0, x23, #0x1000
rs_poll:
    dsb sy
    ldrh w3, [x0, #2]
    cmp w3, w1
    b.eq rs_poll
    ret
