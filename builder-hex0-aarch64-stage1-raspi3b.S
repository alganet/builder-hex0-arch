# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: Apache-2.0
#
# Builder-hex0 AArch64 Stage 1 — Raspberry Pi 3B
#
# Board-specific hex0 compiler bootloader for QEMU raspi3b.
# Loaded by QEMU -kernel at EL2. Drops to EL1, inits SDHCI (ARASAN),
# reads hex0 source from SD card sector 0, compiles to binary
# at 0x00210000, jumps there with:
#   x0 = next disk sector, x1 = 0 (no DTB on raspi3b),
#   x2 = SDHCI base (0x3F300000), x3 = 3 (SDHCI type)
#
# QEMU raspi3b connects -sd to ARASAN SDHCI at 0x3F300000.
# UART PL011 at 0x3F201000.
#
# Registers (callee-saved x19-x28):
#   x19 = hex state    x20 = current sector
#   x21 = buffer offset (init 512 to force read)
#   x22 = SDHCI base   x23 = sector buffer (0x00500000)
#   x24 = output ptr    x25 = high nibble
#   x28 = saved lr

_start:
    ; Park non-boot cores (QEMU raspi3b starts all 4 cores)
    mrs x9, mpidr_el1
    and x9, x9, #0xFF
    cbnz x9, park_core

    mrs x9, currentel
    lsr x9, x9, #2
    cmp x9, #1
    b.eq at_el1

    ; EL2 -> EL1 drop
    movz x9, #0x8000, lsl #16
    movk x9, #0x0002
    msr hcr_el2, x9
    msr cptr_el2, xzr
    mov x9, #3
    msr cnthctl_el2, x9
    msr sctlr_el2, xzr
    movz x9, #0x03C5
    msr spsr_el2, x9
    adr x9, at_el1
    msr elr_el2, x9
    eret

at_el1:
    movz x9, #0x2800, lsl #16
    mov sp, x9

    ; SDHCI base
    movz x22, #0x3F30, lsl #16
    ; Sector buffer
    movz x23, #0x0050, lsl #16

    ; --- SDHCI init ---
    mov w10, #1
    strb w10, [x22, #0x2F]       ; reset
    movz w10, #0x0001
    strh w10, [x22, #0x2C]       ; enable internal clock
clk_wait:
    ldrh w10, [x22, #0x2C]
    and w10, w10, #2
    cbz w10, clk_wait
    movz w10, #0x0005
    strh w10, [x22, #0x2C]       ; + SD clock enable
    mov w10, #0x0F
    strb w10, [x22, #0x29]       ; power on 3.3V
    mov w10, #0x0E
    strb w10, [x22, #0x2E]       ; timeout
    movz w10, #0xFFFF
    str w10, [x22, #0x34]        ; interrupt status enable
    str w10, [x22, #0x38]        ; interrupt signal enable

    ; --- SD card init ---
    str wzr, [x22, #0x08]
    str wzr, [x22, #0x0C]
    bl emmc_wait                  ; CMD0

    movz w10, #0x01AA
    str w10, [x22, #0x08]
    movz w10, #0x0000
    movk w10, #0x081A, lsl #16
    str w10, [x22, #0x0C]
    bl emmc_wait                  ; CMD8

    ; CMD55
    str wzr, [x22, #0x08]
    movz w10, #0x0000
    movk w10, #0x371A, lsl #16
    str w10, [x22, #0x0C]
    bl emmc_wait

    ; ACMD41 — loop until busy bit set
    movz w10, #0x8000
    movk w10, #0x40FF, lsl #16
    str w10, [x22, #0x08]
    movz w10, #0x0000
    movk w10, #0x2902, lsl #16
    str w10, [x22, #0x0C]
    bl emmc_wait

    str wzr, [x22, #0x08]
    movz w10, #0x0000
    movk w10, #0x0209, lsl #16
    str w10, [x22, #0x0C]
    bl emmc_wait                  ; CMD2

    str wzr, [x22, #0x08]
    movz w10, #0x0000
    movk w10, #0x031A, lsl #16
    str w10, [x22, #0x0C]
    bl emmc_wait                  ; CMD3
    ldr w10, [x22, #0x10]
    and w10, w10, #0xFFFF0000

    str w10, [x22, #0x08]
    movz w10, #0x0000
    movk w10, #0x071A, lsl #16
    str w10, [x22, #0x0C]
    bl emmc_wait                  ; CMD7

    movz w10, #0x200
    str w10, [x22, #0x08]
    movz w10, #0x0000
    movk w10, #0x101A, lsl #16
    str w10, [x22, #0x0C]
    bl emmc_wait                  ; CMD16

    ; --- Hex0 compiler ---
    movz x24, #0x0021, lsl #16
    movz x19, #0
    movz x20, #0
    movz x21, #512

hex0_loop:
    bl next_byte
    cbz w0, hex0_done
    cmp w0, #0x21
    b.lt hex0_loop
    cmp w0, #0x23
    b.eq skip_comment
    cmp w0, #0x3B
    b.eq skip_comment
    cmp w0, #0x61
    b.lt no_lower
    sub w0, w0, #0x20
no_lower:
    sub w1, w0, #0x30
    cmp w1, #0
    b.lt hex0_loop
    cmp w1, #10
    b.lt got_nibble
    sub w1, w1, #17
    cmp w1, #6
    b.hs hex0_loop
    add w1, w1, #10
got_nibble:
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
    ; Re-init SDHCI before jumping to stage2 (resets QEMU TCG state)
    mov w10, #1
    strb w10, [x22, #0x2F]       ; software reset
    movz w10, #0x0001
    strh w10, [x22, #0x2C]       ; enable internal clock
s1_clk:
    ldrh w10, [x22, #0x2C]
    and w10, w10, #2
    cbz w10, s1_clk
    movz w10, #0x0005
    strh w10, [x22, #0x2C]       ; + SD clock enable
    mov w10, #0x0F
    strb w10, [x22, #0x29]       ; power on 3.3V
    mov w10, #0x0E
    strb w10, [x22, #0x2E]       ; timeout
    movz w10, #0xFFFF
    str w10, [x22, #0x34]        ; interrupt status enable
    str w10, [x22, #0x38]        ; interrupt signal enable
    ; CMD0
    str wzr, [x22, #0x08]
    str wzr, [x22, #0x0C]
    bl emmc_wait
    ; CMD8
    movz w10, #0x01AA
    str w10, [x22, #0x08]
    movz w10, #0x0000
    movk w10, #0x081A, lsl #16
    str w10, [x22, #0x0C]
    bl emmc_wait
    ; CMD55
    str wzr, [x22, #0x08]
    movz w10, #0x0000
    movk w10, #0x371A, lsl #16
    str w10, [x22, #0x0C]
    bl emmc_wait
    ; ACMD41
    movz w10, #0x8000
    movk w10, #0x40FF, lsl #16
    str w10, [x22, #0x08]
    movz w10, #0x0000
    movk w10, #0x2902, lsl #16
    str w10, [x22, #0x0C]
    bl emmc_wait
    ; CMD2
    str wzr, [x22, #0x08]
    movz w10, #0x0000
    movk w10, #0x0209, lsl #16
    str w10, [x22, #0x0C]
    bl emmc_wait
    ; CMD3
    str wzr, [x22, #0x08]
    movz w10, #0x0000
    movk w10, #0x031A, lsl #16
    str w10, [x22, #0x0C]
    bl emmc_wait
    ldr w10, [x22, #0x10]
    and w10, w10, #0xFFFF0000
    ; CMD7
    str w10, [x22, #0x08]
    movz w10, #0x0000
    movk w10, #0x071A, lsl #16
    str w10, [x22, #0x0C]
    bl emmc_wait
    ; CMD16
    movz w10, #0x200
    str w10, [x22, #0x08]
    movz w10, #0x0000
    movk w10, #0x101A, lsl #16
    str w10, [x22, #0x0C]
    bl emmc_wait

    mov x0, x20
    mov x1, xzr
    mov x2, x22
    mov x3, #3
    movz x9, #0x0021, lsl #16
    br x9

next_byte:
    cmp w21, #512
    b.lt nb_ready
    mov x28, lr
    bl read_sector
    mov lr, x28
    add x20, x20, #1
    movz x21, #0
nb_ready:
    ldrb w0, [x23, x21]
    add x21, x21, #1
    ret

; Read sector x20 via SDHCI PIO into buffer at x23
; QEMU TCG caches MMIO reads in loops. Must use fully unrolled reads.
; 128 sequential ldr/str pairs = 512 bytes. No function calls (all inline).
read_sector:
    ; Clear all interrupt status before new transfer
    movz w10, #0xFFFF
    str w10, [x22, #0x30]
    movz w10, #0x0200
    strh w10, [x22, #0x04]
    mov w10, #1
    strh w10, [x22, #0x06]
    lsl w10, w20, #9
    str w10, [x22, #0x08]
    movz w10, #0x0010
    movk w10, #0x113A, lsl #16
    str w10, [x22, #0x0C]
    ; Wait Buffer Read Ready (bit 5)
rs_brr:
    ldr w10, [x22, #0x30]
    and w11, w10, #0x20
    cbz w11, rs_brr
    mov x9, x23
    ; 128 sequential PIO reads
    ldr w10, [x22, #0x20]
    str w10, [x9, #0]
    ldr w10, [x22, #0x20]
    str w10, [x9, #4]
    ldr w10, [x22, #0x20]
    str w10, [x9, #8]
    ldr w10, [x22, #0x20]
    str w10, [x9, #12]
    ldr w10, [x22, #0x20]
    str w10, [x9, #16]
    ldr w10, [x22, #0x20]
    str w10, [x9, #20]
    ldr w10, [x22, #0x20]
    str w10, [x9, #24]
    ldr w10, [x22, #0x20]
    str w10, [x9, #28]
    ldr w10, [x22, #0x20]
    str w10, [x9, #32]
    ldr w10, [x22, #0x20]
    str w10, [x9, #36]
    ldr w10, [x22, #0x20]
    str w10, [x9, #40]
    ldr w10, [x22, #0x20]
    str w10, [x9, #44]
    ldr w10, [x22, #0x20]
    str w10, [x9, #48]
    ldr w10, [x22, #0x20]
    str w10, [x9, #52]
    ldr w10, [x22, #0x20]
    str w10, [x9, #56]
    ldr w10, [x22, #0x20]
    str w10, [x9, #60]
    ldr w10, [x22, #0x20]
    str w10, [x9, #64]
    ldr w10, [x22, #0x20]
    str w10, [x9, #68]
    ldr w10, [x22, #0x20]
    str w10, [x9, #72]
    ldr w10, [x22, #0x20]
    str w10, [x9, #76]
    ldr w10, [x22, #0x20]
    str w10, [x9, #80]
    ldr w10, [x22, #0x20]
    str w10, [x9, #84]
    ldr w10, [x22, #0x20]
    str w10, [x9, #88]
    ldr w10, [x22, #0x20]
    str w10, [x9, #92]
    ldr w10, [x22, #0x20]
    str w10, [x9, #96]
    ldr w10, [x22, #0x20]
    str w10, [x9, #100]
    ldr w10, [x22, #0x20]
    str w10, [x9, #104]
    ldr w10, [x22, #0x20]
    str w10, [x9, #108]
    ldr w10, [x22, #0x20]
    str w10, [x9, #112]
    ldr w10, [x22, #0x20]
    str w10, [x9, #116]
    ldr w10, [x22, #0x20]
    str w10, [x9, #120]
    ldr w10, [x22, #0x20]
    str w10, [x9, #124]
    ldr w10, [x22, #0x20]
    str w10, [x9, #128]
    ldr w10, [x22, #0x20]
    str w10, [x9, #132]
    ldr w10, [x22, #0x20]
    str w10, [x9, #136]
    ldr w10, [x22, #0x20]
    str w10, [x9, #140]
    ldr w10, [x22, #0x20]
    str w10, [x9, #144]
    ldr w10, [x22, #0x20]
    str w10, [x9, #148]
    ldr w10, [x22, #0x20]
    str w10, [x9, #152]
    ldr w10, [x22, #0x20]
    str w10, [x9, #156]
    ldr w10, [x22, #0x20]
    str w10, [x9, #160]
    ldr w10, [x22, #0x20]
    str w10, [x9, #164]
    ldr w10, [x22, #0x20]
    str w10, [x9, #168]
    ldr w10, [x22, #0x20]
    str w10, [x9, #172]
    ldr w10, [x22, #0x20]
    str w10, [x9, #176]
    ldr w10, [x22, #0x20]
    str w10, [x9, #180]
    ldr w10, [x22, #0x20]
    str w10, [x9, #184]
    ldr w10, [x22, #0x20]
    str w10, [x9, #188]
    ldr w10, [x22, #0x20]
    str w10, [x9, #192]
    ldr w10, [x22, #0x20]
    str w10, [x9, #196]
    ldr w10, [x22, #0x20]
    str w10, [x9, #200]
    ldr w10, [x22, #0x20]
    str w10, [x9, #204]
    ldr w10, [x22, #0x20]
    str w10, [x9, #208]
    ldr w10, [x22, #0x20]
    str w10, [x9, #212]
    ldr w10, [x22, #0x20]
    str w10, [x9, #216]
    ldr w10, [x22, #0x20]
    str w10, [x9, #220]
    ldr w10, [x22, #0x20]
    str w10, [x9, #224]
    ldr w10, [x22, #0x20]
    str w10, [x9, #228]
    ldr w10, [x22, #0x20]
    str w10, [x9, #232]
    ldr w10, [x22, #0x20]
    str w10, [x9, #236]
    ldr w10, [x22, #0x20]
    str w10, [x9, #240]
    ldr w10, [x22, #0x20]
    str w10, [x9, #244]
    ldr w10, [x22, #0x20]
    str w10, [x9, #248]
    ldr w10, [x22, #0x20]
    str w10, [x9, #252]
    ldr w10, [x22, #0x20]
    str w10, [x9, #256]
    ldr w10, [x22, #0x20]
    str w10, [x9, #260]
    ldr w10, [x22, #0x20]
    str w10, [x9, #264]
    ldr w10, [x22, #0x20]
    str w10, [x9, #268]
    ldr w10, [x22, #0x20]
    str w10, [x9, #272]
    ldr w10, [x22, #0x20]
    str w10, [x9, #276]
    ldr w10, [x22, #0x20]
    str w10, [x9, #280]
    ldr w10, [x22, #0x20]
    str w10, [x9, #284]
    ldr w10, [x22, #0x20]
    str w10, [x9, #288]
    ldr w10, [x22, #0x20]
    str w10, [x9, #292]
    ldr w10, [x22, #0x20]
    str w10, [x9, #296]
    ldr w10, [x22, #0x20]
    str w10, [x9, #300]
    ldr w10, [x22, #0x20]
    str w10, [x9, #304]
    ldr w10, [x22, #0x20]
    str w10, [x9, #308]
    ldr w10, [x22, #0x20]
    str w10, [x9, #312]
    ldr w10, [x22, #0x20]
    str w10, [x9, #316]
    ldr w10, [x22, #0x20]
    str w10, [x9, #320]
    ldr w10, [x22, #0x20]
    str w10, [x9, #324]
    ldr w10, [x22, #0x20]
    str w10, [x9, #328]
    ldr w10, [x22, #0x20]
    str w10, [x9, #332]
    ldr w10, [x22, #0x20]
    str w10, [x9, #336]
    ldr w10, [x22, #0x20]
    str w10, [x9, #340]
    ldr w10, [x22, #0x20]
    str w10, [x9, #344]
    ldr w10, [x22, #0x20]
    str w10, [x9, #348]
    ldr w10, [x22, #0x20]
    str w10, [x9, #352]
    ldr w10, [x22, #0x20]
    str w10, [x9, #356]
    ldr w10, [x22, #0x20]
    str w10, [x9, #360]
    ldr w10, [x22, #0x20]
    str w10, [x9, #364]
    ldr w10, [x22, #0x20]
    str w10, [x9, #368]
    ldr w10, [x22, #0x20]
    str w10, [x9, #372]
    ldr w10, [x22, #0x20]
    str w10, [x9, #376]
    ldr w10, [x22, #0x20]
    str w10, [x9, #380]
    ldr w10, [x22, #0x20]
    str w10, [x9, #384]
    ldr w10, [x22, #0x20]
    str w10, [x9, #388]
    ldr w10, [x22, #0x20]
    str w10, [x9, #392]
    ldr w10, [x22, #0x20]
    str w10, [x9, #396]
    ldr w10, [x22, #0x20]
    str w10, [x9, #400]
    ldr w10, [x22, #0x20]
    str w10, [x9, #404]
    ldr w10, [x22, #0x20]
    str w10, [x9, #408]
    ldr w10, [x22, #0x20]
    str w10, [x9, #412]
    ldr w10, [x22, #0x20]
    str w10, [x9, #416]
    ldr w10, [x22, #0x20]
    str w10, [x9, #420]
    ldr w10, [x22, #0x20]
    str w10, [x9, #424]
    ldr w10, [x22, #0x20]
    str w10, [x9, #428]
    ldr w10, [x22, #0x20]
    str w10, [x9, #432]
    ldr w10, [x22, #0x20]
    str w10, [x9, #436]
    ldr w10, [x22, #0x20]
    str w10, [x9, #440]
    ldr w10, [x22, #0x20]
    str w10, [x9, #444]
    ldr w10, [x22, #0x20]
    str w10, [x9, #448]
    ldr w10, [x22, #0x20]
    str w10, [x9, #452]
    ldr w10, [x22, #0x20]
    str w10, [x9, #456]
    ldr w10, [x22, #0x20]
    str w10, [x9, #460]
    ldr w10, [x22, #0x20]
    str w10, [x9, #464]
    ldr w10, [x22, #0x20]
    str w10, [x9, #468]
    ldr w10, [x22, #0x20]
    str w10, [x9, #472]
    ldr w10, [x22, #0x20]
    str w10, [x9, #476]
    ldr w10, [x22, #0x20]
    str w10, [x9, #480]
    ldr w10, [x22, #0x20]
    str w10, [x9, #484]
    ldr w10, [x22, #0x20]
    str w10, [x9, #488]
    ldr w10, [x22, #0x20]
    str w10, [x9, #492]
    ldr w10, [x22, #0x20]
    str w10, [x9, #496]
    ldr w10, [x22, #0x20]
    str w10, [x9, #500]
    ldr w10, [x22, #0x20]
    str w10, [x9, #504]
    ldr w10, [x22, #0x20]
    str w10, [x9, #508]
    movz w10, #0xFFFF
    str w10, [x22, #0x30]
    ret

; QEMU processes SDHCI commands instantly — no polling needed.
; Wait for Command Complete (bit 0) then clear status.
emmc_wait:
    ldr w10, [x22, #0x30]
    and w11, w10, #1
    cbz w11, emmc_wait
    movz w10, #0xFFFF
    str w10, [x22, #0x30]
    ret

park_core:
    wfe
    b park_core
