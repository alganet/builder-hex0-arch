# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: Apache-2.0
#
# Builder-hex0 RISC-V 64-bit Stage 1 (512 bytes)
#
# Board-specific hex0 compiler bootloader for QEMU virt.
# Loaded at 0x80200000 by OpenSBI (a0=hartid, a1=dtb_ptr).
# Reads hex0 source from disk sector 0, compiles to binary at 0x80210000,
# jumps there with a0 = next disk sector, a1 = DTB pointer.
#
# Registers:
#   s0 = hex state (0=first nibble, 1=have first)
#   s1 = current disk sector
#   s2 = offset in buffer (0-511, init 512 to force read)
#   s3 = VirtIO MMIO base
#   s4 = VirtIO struct base (0x80500000)
#   s5 = output write pointer
#   s6 = high nibble accumulator
#   s7 = sector buffer (s4+0x3000)
#   s8 = DTB pointer (from OpenSBI a1)
#   s9 = saved ra in next_byte

_start:
    mv s8, a1                    # save DTB pointer from OpenSBI
    lui t0, 0x54000
    slli sp, t0, 1               # sp = 0xA8000000
    lui t0, 0x40280
    slli s4, t0, 1               # s4 = 0x80500000

    # Scan MMIO 0x10001000..0x10008000 for VirtIO block device
    lui s3, 0x10001
scan:
    lw t0, 0(s3)
    lui t1, 0x74727
    addi t1, t1, -1674           # 0x74726976
    bne t0, t1, scan_next
    lw t0, 8(s3)
    li t1, 2
    beq t0, t1, found
scan_next:
    lui t0, 1
    add s3, s3, t0
    lui t1, 0x10009
    bne s3, t1, scan
halt:
    j halt

found:
    # Legacy VirtIO v1 init (device starts in reset state)
    li t0, 3
    sw t0, 0x70(s3)              # ACKNOWLEDGE|DRIVER
    lui t0, 1
    sw t0, 0x28(s3)              # GuestPageSize=4096
    sw t0, 0x3C(s3)              # QueueAlign=4096
    li t0, 8
    sw t0, 0x38(s3)              # queue size=8
    srli t0, s4, 12
    sw t0, 0x40(s3)              # QueuePFN = s4/4096
    li t0, 7
    sw t0, 0x70(s3)              # DRIVER_OK

    # s7 = sector buffer at s4+0x3000
    lui t0, 3
    add s7, s4, t0

    # Init compiler state
    lui t0, 0x40108
    slli s5, t0, 1               # s5 = 0x80210000 (output)
    li s0, 0                     # state
    li s1, 0                     # sector
    li s2, 512                   # offset (force first read)

    # --- Hex0 main loop ---
hex0_loop:
    jal ra, next_byte
    beqz t0, hex0_done
    # Whitespace: anything <= 0x20
    li t1, 0x21
    blt t0, t1, hex0_loop
    # Comments
    li t1, 0x23
    beq t0, t1, skip_comment
    li t1, 0x3B
    beq t0, t1, skip_comment
    # Force uppercase: if >= 'a', subtract 0x20
    li t1, 0x61
    blt t0, t1, no_lower
    addi t0, t0, -0x20
no_lower:
    # Parse hex: '0'-'9' then 'A'-'F'
    addi t1, t0, -0x30
    bltz t1, hex0_loop           # < '0'
    li t2, 10
    blt t1, t2, got_nibble       # 0-9
    addi t1, t1, -17             # 'A'->0, 'F'->5
    li t2, 6
    bgeu t1, t2, hex0_loop       # rejects gap and > 'F'
    addi t1, t1, 10              # 0->10, 5->15
got_nibble:
    # t1 = nibble (0-15)
    bnez s0, second_nibble
    slli s6, t1, 4
    li s0, 1
    j hex0_loop
second_nibble:
    or t1, s6, t1
    sb t1, 0(s5)
    addi s5, s5, 1
    li s0, 0
    j hex0_loop

skip_comment:
    jal ra, next_byte
    beqz t0, hex0_done
    li t1, 0x0A
    bne t0, t1, skip_comment
    j hex0_loop

hex0_done:
    mv a0, s1
    mv a1, s8                    # pass DTB pointer to stage 2
    lui t0, 0x40108
    slli t0, t0, 1
    jalr zero, t0, 0             # jump to 0x80210000

# --- next_byte: return next byte in t0 ---
next_byte:
    li t0, 512
    blt s2, t0, nb_ready
    mv s9, ra
    jal ra, read_sector
    mv ra, s9
    addi s1, s1, 1
    li s2, 0
nb_ready:
    add t0, s7, s2
    lbu t0, 0(t0)
    addi s2, s2, 1
    ret

# --- read_sector: read sector s1 via VirtIO into s7 ---
# Descriptors set up fresh each call. Uses s3, s4, s7.
read_sector:
    # Header at s4+0x2000
    lui t2, 2
    add t2, s4, t2
    sd s1, 8(t2)                 # sector number (type=0, reserved=0)

    # Descriptor 0: header (s4+0x2000, 16B, NEXT, next=1)
    sd t2, 0(s4)
    li t0, 16
    sw t0, 8(s4)
    li t0, 1
    sh t0, 12(s4)
    sh t0, 14(s4)

    # Descriptor 1: data (s7, 512B, NEXT|WRITE, next=2)
    sd s7, 16(s4)
    li t0, 512
    sw t0, 24(s4)
    li t0, 3
    sh t0, 28(s4)
    li t0, 2
    sh t0, 30(s4)

    # Descriptor 2: status (s4+0x2010, 1B, WRITE)
    addi t0, t2, 0x10
    sd t0, 32(s4)
    li t0, 1
    sw t0, 40(s4)
    li t0, 2
    sh t0, 44(s4)
    sh zero, 46(s4)

    # Save used.idx, update avail ring
    lui t0, 1
    add t0, s4, t0
    lhu t1, 2(t0)                # t1 = initial used.idx
    addi t0, s4, 0x80
    lhu a0, 2(t0)
    andi t2, a0, 7
    slli t2, t2, 1
    addi t2, t2, 4
    add t2, t0, t2
    sh zero, 0(t2)
    addi a0, a0, 1
    sh a0, 2(t0)

    fence
    sw zero, 0x50(s3)            # notify

    lui t0, 1
    add t0, s4, t0
rs_poll:
    fence
    lhu a0, 2(t0)
    beq a0, t1, rs_poll
    ret
