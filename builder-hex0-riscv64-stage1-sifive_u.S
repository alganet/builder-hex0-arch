# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: Apache-2.0
#
# Builder-hex0 RISC-V 64-bit Stage 1 — SiFive HiFive Unleashed (sifive_u)
#
# Board-specific hex0 compiler bootloader for sifive_u.
# Loaded at 0x80200000 by OpenSBI (a0=hartid, a1=dtb_ptr).
# Reads hex0 source from SD card via SiFive SPI controller,
# compiles to binary at 0x80210000, jumps there with
# a0 = next disk sector, a1 = DTB pointer.
#
# SiFive SPI controller at 0x10050000 (SPI2, SD card slot).
# SD card uses SPI mode protocol.
#
# Registers:
#   s0 = hex state (0=first nibble, 1=have first)
#   s1 = current disk sector
#   s2 = offset in buffer (0-511, init 512 to force read)
#   s3 = SPI controller MMIO base (0x10050000)
#   s5 = output write pointer
#   s6 = high nibble accumulator
#   s7 = sector buffer (same as s4 for compat)
#   s8 = DTB pointer (from OpenSBI a1)
#   s9 = saved ra in next_byte

_start:
    # Park non-boot harts (sifive_u boot hart = 1)
    li t0, 1
    beq a0, t0, boot
park_hart:
    j park_hart
boot:
    mv s8, a1                    # save DTB pointer from OpenSBI
    lui t0, 0x54000
    slli sp, t0, 1               # sp = 0xA8000000

    # SPI base = 0x10050000
    lui s3, 0x10050

    # Buffer area at 0x80503000 (reuse VirtIO struct area)
    lui t0, 0x40280
    slli t0, t0, 1               # t0 = 0x80500000
    lui t1, 3
    add s7, t0, t1               # s7 = 0x80503000

    # --- SPI controller init ---

    # Disable flash mode (FCTRL = 0)
    sw zero, 0x60(s3)

    # Slow clock for SD init: SCKDIV = 0x3F
    li t0, 0x3F
    sw t0, 0x00(s3)

    # SPI mode 0: SCKMODE = 0
    sw zero, 0x04(s3)

    # Select CS 0: CSID = 0
    sw zero, 0x10(s3)

    # CS default = all high: CSDEF = 1
    li t0, 1
    sw t0, 0x14(s3)

    # CS mode = off (manual): CSMODE = 3
    li t0, 3
    sw t0, 0x18(s3)

    # Send 80+ clock cycles with CS deasserted (SD warmup)
    li t2, 10
warmup:
    li a0, 0xFF
    jal ra, spi_xfer
    addi t2, t2, -1
    bnez t2, warmup

    # Assert CS: CSMODE = hold (2)
    li t0, 2
    sw t0, 0x18(s3)

    # --- SD card init ---
    # Each sd_cmd is followed by a flush byte (0xFF) to consume the
    # ssi-sd bridge's RESPONSE→CMD state transition.

    # CMD0: GO_IDLE_STATE
    li a0, 0x40
    li a1, 0
    li a2, 0x95
    jal ra, sd_cmd
    li a0, 0xFF
    jal ra, spi_xfer             # flush

    # CMD8: SEND_IF_COND (0x1AA)
    li a0, 0x48
    li a1, 0x1AA
    li a2, 0x87
    jal ra, sd_cmd
    # Read 4 bytes of R7 (discard) + flush
    li a0, 0xFF
    jal ra, spi_xfer
    li a0, 0xFF
    jal ra, spi_xfer
    li a0, 0xFF
    jal ra, spi_xfer
    li a0, 0xFF
    jal ra, spi_xfer
    li a0, 0xFF
    jal ra, spi_xfer             # flush

    # ACMD41 loop: CMD55 + ACMD41 with HCS + voltage bits
acmd41_loop:
    li a0, 0x77                 # CMD55 = 0x40 | 55
    li a1, 0
    li a2, 0xFF
    jal ra, sd_cmd
    li a0, 0xFF
    jal ra, spi_xfer             # flush

    li a0, 0x69                 # ACMD41 = 0x40 | 41
    lui a1, 0x40FF8             # HCS (bit 30) + voltage window (bits 15:23)
    li a2, 0xFF
    jal ra, sd_cmd
    mv s10, a0                  # save R1
    li a0, 0xFF
    jal ra, spi_xfer             # flush
    bnez s10, acmd41_loop

    # CMD9: SEND_CSD (transitions card to transfer state in SPI mode)
    li a0, 0x49                 # CMD9 = 0x40 | 9
    li a1, 0
    li a2, 0xFF
    jal ra, sd_cmd
    # Skip token + 16-byte CSD + 2-byte CRC = ~20 bytes
    li t2, 20
skip_csd:
    li a0, 0xFF
    jal ra, spi_xfer
    addi t2, t2, -1
    bnez t2, skip_csd
    li a0, 0xFF
    jal ra, spi_xfer             # flush

    # Speed up: SCKDIV = 3
    li t0, 3
    sw t0, 0x00(s3)

    # --- Hex0 compiler ---

    # Init compiler state
    lui t0, 0x40108
    slli s5, t0, 1               # s5 = 0x80210000 (output)
    li s0, 0                     # state
    li s1, 0                     # sector
    li s2, 512                   # offset (force first read)

hex0_loop:
    jal ra, next_byte
    beqz t0, hex0_done
    li t1, 0x21
    blt t0, t1, hex0_loop
    li t1, 0x23
    beq t0, t1, skip_comment
    li t1, 0x3B
    beq t0, t1, skip_comment
    li t1, 0x61
    blt t0, t1, no_lower
    addi t0, t0, -0x20
no_lower:
    addi t1, t0, -0x30
    bltz t1, hex0_loop
    li t2, 10
    blt t1, t2, got_nibble
    addi t1, t1, -17
    li t2, 6
    bgeu t1, t2, hex0_loop
    addi t1, t1, 10
got_nibble:
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

# --- read_sector: read sector s1 from SD card into s7 ---
read_sector:
    addi sp, sp, -8
    sd ra, 0(sp)

    # CMD17: READ_SINGLE_BLOCK (byte address = sector * 512)
    li a0, 0x51
    slli a1, s1, 9              # sector * 512 for byte addressing
    li a2, 0xFF
    jal ra, sd_cmd

    # Wait for data token (0xFE)
    # First 0xFF consumes the bridge RESPONSE→DATA_START transition
rs_wait_token:
    li a0, 0xFF
    jal ra, spi_xfer
    li t0, 0xFE
    bne a0, t0, rs_wait_token

    # Read 512 bytes into s7 (t3 as pointer, safe: spi_xfer only clobbers a0/t0)
    mv t3, s7
    li t2, 512
rs_read_loop:
    li a0, 0xFF
    jal ra, spi_xfer
    sb a0, 0(t3)
    addi t3, t3, 1
    addi t2, t2, -1
    bnez t2, rs_read_loop

    # Read 2 CRC bytes (discard)
    li a0, 0xFF
    jal ra, spi_xfer
    li a0, 0xFF
    jal ra, spi_xfer

    ld ra, 0(sp)
    addi sp, sp, 8
    ret

# --- spi_xfer: exchange one byte over SPI ---
# a0 = byte to send, returns received byte in a0
spi_xfer:
spi_tx_wait:
    lw t0, 0x48(s3)             # TXDATA
    bltz t0, spi_tx_wait
    sw a0, 0x48(s3)
spi_rx_wait:
    lw a0, 0x4C(s3)             # RXDATA
    bltz a0, spi_rx_wait
    andi a0, a0, 0xFF
    ret

# --- sd_cmd: send SD command, return R1 in a0 ---
# a0 = cmd byte, a1 = arg, a2 = crc
sd_cmd:
    addi sp, sp, -16
    sd ra, 0(sp)
    sd s0, 8(sp)

    # spi_xfer only clobbers a0/t0, so a1 (arg) and a2 (CRC) survive

    # Send command byte (a0 already has it)
    jal ra, spi_xfer
    # Send 4 arg bytes (big-endian, a1 preserved across calls)
    srli a0, a1, 24
    andi a0, a0, 0xFF
    jal ra, spi_xfer
    srli a0, a1, 16
    andi a0, a0, 0xFF
    jal ra, spi_xfer
    srli a0, a1, 8
    andi a0, a0, 0xFF
    jal ra, spi_xfer
    andi a0, a1, 0xFF
    jal ra, spi_xfer
    # Send CRC (a2 preserved across calls)
    mv a0, a2
    jal ra, spi_xfer

    # Poll for response (bit 7 = 0)
    li s0, 8
sd_cmd_poll:
    li a0, 0xFF
    jal ra, spi_xfer
    andi t0, a0, 0x80
    beqz t0, sd_cmd_done
    addi s0, s0, -1
    bnez s0, sd_cmd_poll
    li a0, 0xFF                 # timeout

sd_cmd_done:
    ld ra, 0(sp)
    ld s0, 8(sp)
    addi sp, sp, 16
    ret
