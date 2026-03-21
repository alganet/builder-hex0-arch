#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: Apache-2.0
"""Encode AArch64 instructions to hex2 fragments.

Standalone usage: python3 a64_asm.py <mnemonic> <arg1> <arg2> ...
Batch mode:      echo "add x0 x1 42" | python3 a64_asm.py
Library usage:   from a64_asm import emit, load_addr
"""
import sys

# ---------------------------------------------------------------------------
# Register encoding
# ---------------------------------------------------------------------------

REGS = {}
for _i in range(31):
    REGS[f'x{_i}'] = _i
    REGS[f'w{_i}'] = _i
REGS['sp'] = 31
REGS['xzr'] = 31
REGS['wzr'] = 31
REGS['lr'] = 30

# ---------------------------------------------------------------------------
# Condition codes for B.cond
# ---------------------------------------------------------------------------

CONDS = {
    'eq': 0x0, 'ne': 0x1, 'cs': 0x2, 'hs': 0x2, 'cc': 0x3, 'lo': 0x3,
    'mi': 0x4, 'pl': 0x5, 'vs': 0x6, 'vc': 0x7,
    'hi': 0x8, 'ls': 0x9, 'ge': 0xA, 'lt': 0xB,
    'gt': 0xC, 'le': 0xD, 'al': 0xE,
}

# ---------------------------------------------------------------------------
# System register encodings (15-bit: o0:op1:CRn:CRm:op2)
#
# o0 = 1 when op0=3, o0 = 0 when op0=2
# encoding = (o0 << 14) | (op1 << 11) | (CRn << 7) | (CRm << 3) | op2
# ---------------------------------------------------------------------------

SYSREGS = {
    'sctlr_el1':  0x4080,  # S3_0_C1_C0_0
    'tcr_el1':    0x4102,  # S3_0_C2_C0_2
    'ttbr0_el1':  0x4100,  # S3_0_C2_C0_0
    'ttbr1_el1':  0x4101,  # S3_0_C2_C0_1
    'mair_el1':   0x4510,  # S3_0_C10_C2_0
    'vbar_el1':   0x4600,  # S3_0_C12_C0_0
    'elr_el1':    0x4201,  # S3_0_C4_C0_1
    'spsr_el1':   0x4200,  # S3_0_C4_C0_0
    'esr_el1':    0x4290,  # S3_0_C5_C2_0
    'far_el1':    0x4300,  # S3_0_C6_C0_0
    'sp_el0':     0x4208,  # S3_0_C4_C1_0
    'spsel':      0x4210,  # S3_0_C4_C2_0
    'currentel':  0x4212,  # S3_0_C4_C2_2
    'daif':       0x5A11,  # S3_3_C4_C2_1
    'mpidr_el1':  0x4005,  # S3_0_C0_C0_5
    # EL2 registers (for raspi3b EL2->EL1 drop)
    'hcr_el2':     0x6088,  # S3_4_C1_C1_0
    'sctlr_el2':   0x6080,  # S3_4_C1_C0_0
    'spsr_el2':    0x6200,  # S3_4_C4_C0_0
    'elr_el2':     0x6201,  # S3_4_C4_C0_1
    'cnthctl_el2': 0x6708,  # S3_4_C14_C1_0
    'cptr_el2':    0x608A,  # S3_4_C1_C1_2
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def to_le_hex(val):
    """Convert a 32-bit instruction word to 8 hex chars in little-endian."""
    val = val & 0xFFFFFFFF
    return ''.join(f'{(val >> (i * 8)) & 0xFF:02X}' for i in range(4))


def _reg(name):
    """Resolve register name to 5-bit encoding."""
    return REGS[name]


def _sysreg(name):
    """Resolve system register name to 15-bit encoding."""
    if isinstance(name, int):
        return name
    return SYSREGS[name.lower()]


def encode_bitmask_imm(value, is_64bit):
    """Encode a bitmask immediate as (N, immr, imms) for logical immediates.

    AArch64 logical immediates encode repeating bit patterns.
    Returns (N, immr, imms) or raises ValueError.
    """
    reg_size = 64 if is_64bit else 32
    value = value & ((1 << reg_size) - 1)
    if value == 0 or value == (1 << reg_size) - 1:
        raise ValueError(f"Cannot encode bitmask: {value:#x}")

    # Replicate 32-bit to 64-bit for uniform handling
    if not is_64bit:
        value = value | (value << 32)

    for element_size in [2, 4, 8, 16, 32, 64]:
        mask = (1 << element_size) - 1
        element = value & mask

        # Check pattern repeats across 64 bits
        ok = True
        for i in range(0, 64, element_size):
            if ((value >> i) & mask) != element:
                ok = False
                break
        if not ok:
            continue

        # Try each rotation to find consecutive 1s from bit 0
        for rotation in range(element_size):
            rotated = ((element >> rotation) |
                       (element << (element_size - rotation))) & mask
            if not (rotated & 1):
                continue
            ones = 0
            while ones < element_size and ((rotated >> ones) & 1):
                ones += 1
            if ones == element_size or rotated != (1 << ones) - 1:
                continue

            # ARM uses right-rotation: ror(normalized, immr) = value
            # We found left-rotation, so immr = element_size - rotation
            immr = (element_size - rotation) % element_size
            if element_size == 64:
                return (1, immr, ones - 1)
            else:
                # Upper bits of imms encode element size
                len_val = element_size.bit_length() - 1
                upper = 0
                for bit in range(len_val + 1, 6):
                    upper |= (1 << bit)
                imms = upper | ((ones - 1) & ((1 << len_val) - 1))
                return (0, immr, imms)

    raise ValueError(f"Cannot encode bitmask: {value:#x}")


# ---------------------------------------------------------------------------
# Instruction encoder
# ---------------------------------------------------------------------------

def emit(mnemonic, *args):
    """Encode one AArch64 instruction and return its little-endian hex string."""
    mn = mnemonic.lower()

    # ---- Fixed encodings ----
    if mn == 'ret':
        return to_le_hex(0xD65F03C0)
    if mn == 'eret':
        return to_le_hex(0xD69F03E0)
    if mn == 'nop':
        return to_le_hex(0xD503201F)
    if mn == 'wfe':
        return to_le_hex(0xD503205F)
    if mn == 'dsb_sy':
        return to_le_hex(0xD5033F9F)
    if mn == 'isb':
        return to_le_hex(0xD5033FDF)
    if mn == 'tlbi_vmalle1':
        return to_le_hex(0xD508871F)
    if mn == 'ic_iallu':
        # IC IALLU - invalidate all instruction caches
        return to_le_hex(0xD508751F)
    if mn == 'msr_spsel':
        # MSR SPSel, #imm: op1=0, op2=5
        # 1101_0101_0000_0000_0100_CRm_101_11111
        imm = args[0]
        return to_le_hex(0xD50040BF | ((imm & 0x1) << 8))
    if mn == 'msr_daifset':
        # MSR DAIFSet, #imm4: op1=3, op2=6
        # 1101_0101_0000_0011_0100_CRm_110_11111
        imm = args[0]
        return to_le_hex(0xD50340DF | ((imm & 0xF) << 8))
    if mn == 'msr_daifclr':
        # MSR DAIFClr, #imm4: op1=3, op2=7
        # 1101_0101_0000_0011_0100_CRm_111_11111
        imm = args[0]
        return to_le_hex(0xD50340FF | ((imm & 0xF) << 8))

    # ---- Byte reversal ----

    if mn == 'rev_w':
        # REV Wd, Wn (32-bit byte reverse)
        rd, rn = args
        return to_le_hex(0x5AC00800 | (_reg(rn) << 5) | _reg(rd))
    if mn == 'rev':
        # REV Xd, Xn (64-bit byte reverse)
        rd, rn = args
        return to_le_hex(0xDAC00C00 | (_reg(rn) << 5) | _reg(rd))

    # ---- Data Processing (Immediate) ----

    def _encode_addsub_imm(imm):
        """Encode ADD/SUB immediate: returns (sh, imm12).
        sh=0: imm12 applied directly (0-4095)
        sh=1: imm12 shifted left by 12 (multiples of 4096, up to 4095*4096)"""
        if 0 <= imm <= 4095:
            return (0, imm)
        elif (imm & 0xFFF) == 0 and 0 < (imm >> 12) <= 4095:
            return (1, imm >> 12)
        else:
            raise ValueError(f"ADD/SUB immediate {imm:#x} out of range")

    if mn == 'add_imm':
        # ADD Xd, Xn, #imm (supports LSL #0 or LSL #12)
        rd, rn, imm = args
        sh, imm12 = _encode_addsub_imm(imm)
        return to_le_hex(0x91000000 | (sh << 22) | (imm12 << 10) |
                         (_reg(rn) << 5) | _reg(rd))

    if mn == 'sub_imm':
        # SUB Xd, Xn, #imm
        rd, rn, imm = args
        sh, imm12 = _encode_addsub_imm(imm)
        return to_le_hex(0xD1000000 | (sh << 22) | (imm12 << 10) |
                         (_reg(rn) << 5) | _reg(rd))

    if mn == 'adds_imm':
        # ADDS Xd, Xn, #imm
        rd, rn, imm = args
        sh, imm12 = _encode_addsub_imm(imm)
        return to_le_hex(0xB1000000 | (sh << 22) | (imm12 << 10) |
                         (_reg(rn) << 5) | _reg(rd))

    if mn == 'subs_imm':
        # SUBS Xd, Xn, #imm
        rd, rn, imm = args
        sh, imm12 = _encode_addsub_imm(imm)
        return to_le_hex(0xF1000000 | (sh << 22) | (imm12 << 10) |
                         (_reg(rn) << 5) | _reg(rd))

    if mn == 'cmp_imm':
        # CMP Xn, #imm = SUBS xzr, Xn, #imm
        rn, imm = args
        sh, imm12 = _encode_addsub_imm(imm)
        return to_le_hex(0xF100001F | (sh << 22) | (imm12 << 10) | (_reg(rn) << 5))

    if mn == 'cmn_imm':
        # CMN Xn, #imm = ADDS xzr, Xn, #imm (supports LSL #0 or LSL #12)
        rn, imm = args
        sh, imm12 = _encode_addsub_imm(imm)
        return to_le_hex(0xB100001F | (sh << 22) | (imm12 << 10) | (_reg(rn) << 5))

    if mn == 'movz':
        # MOVZ Xd, #imm16, LSL #shift
        rd, imm16 = args[:2]
        shift = args[2] if len(args) > 2 else 0
        hw = shift // 16
        return to_le_hex(0xD2800000 | (hw << 21) | ((imm16 & 0xFFFF) << 5) | _reg(rd))

    if mn == 'movk':
        # MOVK Xd, #imm16, LSL #shift
        rd, imm16 = args[:2]
        shift = args[2] if len(args) > 2 else 0
        hw = shift // 16
        return to_le_hex(0xF2800000 | (hw << 21) | ((imm16 & 0xFFFF) << 5) | _reg(rd))

    if mn == 'movn':
        # MOVN Xd, #imm16, LSL #shift
        rd, imm16 = args[:2]
        shift = args[2] if len(args) > 2 else 0
        hw = shift // 16
        return to_le_hex(0x92800000 | (hw << 21) | ((imm16 & 0xFFFF) << 5) | _reg(rd))

    # ---- Data Processing (Register) ----

    if mn == 'add':
        # ADD Xd, Xn, Xm
        rd, rn, rm = args
        return to_le_hex(0x8B000000 | (_reg(rm) << 16) | (_reg(rn) << 5) | _reg(rd))

    if mn == 'sub':
        # SUB Xd, Xn, Xm
        rd, rn, rm = args
        return to_le_hex(0xCB000000 | (_reg(rm) << 16) | (_reg(rn) << 5) | _reg(rd))

    if mn == 'adds':
        # ADDS Xd, Xn, Xm
        rd, rn, rm = args
        return to_le_hex(0xAB000000 | (_reg(rm) << 16) | (_reg(rn) << 5) | _reg(rd))

    if mn == 'subs':
        # SUBS Xd, Xn, Xm
        rd, rn, rm = args
        return to_le_hex(0xEB000000 | (_reg(rm) << 16) | (_reg(rn) << 5) | _reg(rd))

    if mn == 'cmp':
        # CMP Xn, Xm = SUBS xzr, Xn, Xm
        rn, rm = args
        return to_le_hex(0xEB00001F | (_reg(rm) << 16) | (_reg(rn) << 5))

    if mn == 'cmn':
        # CMN Xn, Xm = ADDS xzr, Xn, Xm
        rn, rm = args
        return to_le_hex(0xAB00001F | (_reg(rm) << 16) | (_reg(rn) << 5))

    if mn == 'and':
        rd, rn, rm = args
        return to_le_hex(0x8A000000 | (_reg(rm) << 16) | (_reg(rn) << 5) | _reg(rd))

    if mn == 'orr':
        rd, rn, rm = args
        return to_le_hex(0xAA000000 | (_reg(rm) << 16) | (_reg(rn) << 5) | _reg(rd))

    if mn == 'eor':
        rd, rn, rm = args
        return to_le_hex(0xCA000000 | (_reg(rm) << 16) | (_reg(rn) << 5) | _reg(rd))

    if mn == 'ands':
        rd, rn, rm = args
        return to_le_hex(0xEA000000 | (_reg(rm) << 16) | (_reg(rn) << 5) | _reg(rd))

    if mn == 'tst':
        # TST Xn, Xm = ANDS xzr, Xn, Xm
        rn, rm = args
        return to_le_hex(0xEA00001F | (_reg(rm) << 16) | (_reg(rn) << 5))

    # ---- Logical (Immediate) ----

    if mn in ('and_imm', 'orr_imm', 'eor_imm', 'ands_imm', 'tst_imm'):
        # AND/ORR/EOR/ANDS Xd, Xn, #imm  (bitmask immediate)
        # tst_imm is ANDS xzr, Xn, #imm
        is_tst = (mn == 'tst_imm')
        if is_tst:
            rn, imm = args
            rd = 'xzr'
        else:
            rd, rn, imm = args
        is_64 = str(rd).startswith('x') or rd in ('sp', 'xzr')
        N, immr, imms = encode_bitmask_imm(imm, is_64)
        sf = 1 if is_64 else 0
        base_map = {'and_imm': 0, 'orr_imm': 1, 'eor_imm': 2,
                     'ands_imm': 3, 'tst_imm': 3}
        opc = base_map[mn]
        base = (sf << 31) | (opc << 29) | (0x24 << 23) | (N << 22) | \
               (immr << 16) | (imms << 10) | (_reg(rn) << 5) | _reg(rd)
        return to_le_hex(base)

    if mn == 'mov':
        # MOV Xd, Xn
        # If Rd or Rn is SP, use ADD Xd, Xn, #0 (reg 31 = SP in ADD)
        # Otherwise use ORR Xd, XZR, Xn (reg 31 = XZR in ORR)
        rd, rn = args
        if rd == 'sp' or rn == 'sp':
            return to_le_hex(0x91000000 | (_reg(rn) << 5) | _reg(rd))
        return to_le_hex(0xAA0003E0 | (_reg(rn) << 16) | _reg(rd))

    if mn == 'neg':
        # NEG Xd, Xm = SUB Xd, xzr, Xm
        rd, rm = args
        return to_le_hex(0xCB0003E0 | (_reg(rm) << 16) | _reg(rd))

    if mn == 'mul':
        # MUL Xd, Xn, Xm = MADD Xd, Xn, Xm, xzr
        rd, rn, rm = args
        return to_le_hex(0x9B007C00 | (_reg(rm) << 16) | (_reg(rn) << 5) | _reg(rd))

    if mn == 'udiv':
        rd, rn, rm = args
        return to_le_hex(0x9AC00800 | (_reg(rm) << 16) | (_reg(rn) << 5) | _reg(rd))

    if mn == 'sdiv':
        rd, rn, rm = args
        return to_le_hex(0x9AC00C00 | (_reg(rm) << 16) | (_reg(rn) << 5) | _reg(rd))

    # ---- Shifts (register) ----

    if mn == 'lslv':
        rd, rn, rm = args
        return to_le_hex(0x9AC02000 | (_reg(rm) << 16) | (_reg(rn) << 5) | _reg(rd))

    if mn == 'lsrv':
        rd, rn, rm = args
        return to_le_hex(0x9AC02400 | (_reg(rm) << 16) | (_reg(rn) << 5) | _reg(rd))

    if mn == 'asrv':
        rd, rn, rm = args
        return to_le_hex(0x9AC02800 | (_reg(rm) << 16) | (_reg(rn) << 5) | _reg(rd))

    # ---- Shifts (immediate) ----

    if mn == 'lsl_imm':
        # LSL Xd, Xn, #imm = UBFM Xd, Xn, #(-imm MOD 64), #(63-imm)
        rd, rn, imm = args
        immr = (-imm) & 63
        imms = 63 - imm
        return to_le_hex(0xD3400000 | (immr << 16) | (imms << 10) | (_reg(rn) << 5) | _reg(rd))

    if mn == 'lsr_imm':
        # LSR Xd, Xn, #imm = UBFM Xd, Xn, #imm, #63
        rd, rn, imm = args
        return to_le_hex(0xD340FC00 | (imm << 16) | (_reg(rn) << 5) | _reg(rd))

    if mn == 'asr_imm':
        # ASR Xd, Xn, #imm = SBFM Xd, Xn, #imm, #63
        rd, rn, imm = args
        return to_le_hex(0x9340FC00 | (imm << 16) | (_reg(rn) << 5) | _reg(rd))

    if mn == 'sxtw':
        # SXTW Xd, Wn = SBFM Xd, Xn, #0, #31
        rd, rn = args
        return to_le_hex(0x93407C00 | (_reg(rn) << 5) | _reg(rd))

    # ---- Load/Store (unsigned offset) ----

    if mn == 'ldr':
        # LDR Xt, [Xn, #imm] (64-bit, unsigned offset, imm must be 8-aligned)
        rt, rn, imm = args
        if imm % 8 != 0:
            raise ValueError(f"LDR offset {imm:#x} not 8-byte aligned")
        return to_le_hex(0xF9400000 | ((imm // 8) << 10) | (_reg(rn) << 5) | _reg(rt))

    if mn == 'str':
        # STR Xt, [Xn, #imm] (64-bit)
        rt, rn, imm = args
        if imm % 8 != 0:
            raise ValueError(f"STR offset {imm:#x} not 8-byte aligned")
        return to_le_hex(0xF9000000 | ((imm // 8) << 10) | (_reg(rn) << 5) | _reg(rt))

    if mn == 'ldr_w':
        # LDR Wt, [Xn, #imm] (32-bit, unsigned offset, imm must be 4-aligned)
        rt, rn, imm = args
        if imm % 4 != 0:
            raise ValueError(f"LDR (32-bit) offset {imm:#x} not 4-byte aligned")
        return to_le_hex(0xB9400000 | ((imm // 4) << 10) | (_reg(rn) << 5) | _reg(rt))

    if mn == 'str_w':
        # STR Wt, [Xn, #imm] (32-bit)
        rt, rn, imm = args
        if imm % 4 != 0:
            raise ValueError(f"STR (32-bit) offset {imm:#x} not 4-byte aligned")
        return to_le_hex(0xB9000000 | ((imm // 4) << 10) | (_reg(rn) << 5) | _reg(rt))

    if mn == 'ldrb':
        # LDRB Wt, [Xn, #imm]
        rt, rn, imm = args
        return to_le_hex(0x39400000 | (imm << 10) | (_reg(rn) << 5) | _reg(rt))

    if mn == 'strb':
        # STRB Wt, [Xn, #imm]
        rt, rn, imm = args
        return to_le_hex(0x39000000 | (imm << 10) | (_reg(rn) << 5) | _reg(rt))

    if mn == 'ldrh':
        # LDRH Wt, [Xn, #imm]
        rt, rn, imm = args
        if imm % 2 != 0:
            raise ValueError(f"LDRH offset {imm:#x} not 2-byte aligned")
        return to_le_hex(0x79400000 | ((imm // 2) << 10) | (_reg(rn) << 5) | _reg(rt))

    if mn == 'strh':
        # STRH Wt, [Xn, #imm]
        rt, rn, imm = args
        if imm % 2 != 0:
            raise ValueError(f"STRH offset {imm:#x} not 2-byte aligned")
        return to_le_hex(0x79000000 | ((imm // 2) << 10) | (_reg(rn) << 5) | _reg(rt))

    if mn == 'ldrsw':
        # LDRSW Xt, [Xn, #imm] (sign-extend 32->64, imm must be 4-aligned)
        rt, rn, imm = args
        if imm % 4 != 0:
            raise ValueError(f"LDRSW offset {imm:#x} not 4-byte aligned")
        return to_le_hex(0xB9800000 | ((imm // 4) << 10) | (_reg(rn) << 5) | _reg(rt))

    # ---- Load/Store (register offset) ----

    if mn == 'ldr_reg':
        # LDR Xt, [Xn, Xm] (64-bit, register offset)
        rt, rn, rm = args
        return to_le_hex(0xF8606800 | (_reg(rm) << 16) | (_reg(rn) << 5) | _reg(rt))

    if mn == 'str_reg':
        # STR Xt, [Xn, Xm] (64-bit)
        rt, rn, rm = args
        return to_le_hex(0xF8206800 | (_reg(rm) << 16) | (_reg(rn) << 5) | _reg(rt))

    if mn == 'ldrb_reg':
        # LDRB Wt, [Xn, Xm]
        rt, rn, rm = args
        return to_le_hex(0x38606800 | (_reg(rm) << 16) | (_reg(rn) << 5) | _reg(rt))

    if mn == 'strb_reg':
        # STRB Wt, [Xn, Xm]
        rt, rn, rm = args
        return to_le_hex(0x38206800 | (_reg(rm) << 16) | (_reg(rn) << 5) | _reg(rt))

    if mn == 'ldrh_reg':
        # LDRH Wt, [Xn, Xm]
        rt, rn, rm = args
        return to_le_hex(0x78606800 | (_reg(rm) << 16) | (_reg(rn) << 5) | _reg(rt))

    if mn == 'strh_reg':
        # STRH Wt, [Xn, Xm]
        rt, rn, rm = args
        return to_le_hex(0x78206800 | (_reg(rm) << 16) | (_reg(rn) << 5) | _reg(rt))

    if mn == 'ldr_w_reg':
        # LDR Wt, [Xn, Xm] (32-bit, register offset)
        rt, rn, rm = args
        return to_le_hex(0xB8606800 | (_reg(rm) << 16) | (_reg(rn) << 5) | _reg(rt))

    if mn == 'str_w_reg':
        # STR Wt, [Xn, Xm] (32-bit)
        rt, rn, rm = args
        return to_le_hex(0xB8206800 | (_reg(rm) << 16) | (_reg(rn) << 5) | _reg(rt))

    # ---- Load/Store Pair ----

    if mn == 'stp_pre':
        # STP Xt1, Xt2, [Xn, #imm]! (pre-index, 64-bit)
        rt1, rt2, rn, imm = args
        return to_le_hex(0xA9800000 | (((imm // 8) & 0x7F) << 15) | (_reg(rt2) << 10) | (_reg(rn) << 5) | _reg(rt1))

    if mn == 'ldp_post':
        # LDP Xt1, Xt2, [Xn], #imm (post-index, 64-bit)
        rt1, rt2, rn, imm = args
        return to_le_hex(0xA8C00000 | (((imm // 8) & 0x7F) << 15) | (_reg(rt2) << 10) | (_reg(rn) << 5) | _reg(rt1))

    if mn == 'stp':
        # STP Xt1, Xt2, [Xn, #imm] (signed offset, 64-bit)
        rt1, rt2, rn, imm = args
        return to_le_hex(0xA9000000 | (((imm // 8) & 0x7F) << 15) | (_reg(rt2) << 10) | (_reg(rn) << 5) | _reg(rt1))

    if mn == 'ldp':
        # LDP Xt1, Xt2, [Xn, #imm] (signed offset, 64-bit)
        rt1, rt2, rn, imm = args
        return to_le_hex(0xA9400000 | (((imm // 8) & 0x7F) << 15) | (_reg(rt2) << 10) | (_reg(rn) << 5) | _reg(rt1))

    # ---- Branch ----

    if mn == 'b':
        # B offset (byte offset, must be 4-aligned)
        offset = args[0]
        imm26 = offset // 4
        return to_le_hex(0x14000000 | (imm26 & 0x3FFFFFF))

    if mn == 'bl':
        # BL offset
        offset = args[0]
        imm26 = offset // 4
        return to_le_hex(0x94000000 | (imm26 & 0x3FFFFFF))

    if mn.startswith('b.'):
        # B.cond offset
        cond_name = mn[2:]
        cond = CONDS[cond_name]
        offset = args[0]
        imm19 = offset // 4
        return to_le_hex(0x54000000 | ((imm19 & 0x7FFFF) << 5) | cond)

    if mn == 'cbz':
        # CBZ Xt, offset
        rt, offset = args
        imm19 = offset // 4
        return to_le_hex(0xB4000000 | ((imm19 & 0x7FFFF) << 5) | _reg(rt))

    if mn == 'cbnz':
        # CBNZ Xt, offset
        rt, offset = args
        imm19 = offset // 4
        return to_le_hex(0xB5000000 | ((imm19 & 0x7FFFF) << 5) | _reg(rt))

    if mn == 'br':
        # BR Xn
        rn = args[0]
        return to_le_hex(0xD61F0000 | (_reg(rn) << 5))

    if mn == 'blr':
        # BLR Xn
        rn = args[0]
        return to_le_hex(0xD63F0000 | (_reg(rn) << 5))

    # ---- System ----

    if mn == 'svc':
        imm16 = args[0]
        return to_le_hex(0xD4000001 | ((imm16 & 0xFFFF) << 5))

    if mn == 'hvc':
        imm16 = args[0]
        return to_le_hex(0xD4000002 | ((imm16 & 0xFFFF) << 5))

    if mn == 'msr':
        # MSR sysreg, Xt
        sysreg, rt = args
        enc = _sysreg(sysreg)
        return to_le_hex(0xD5100000 | (enc << 5) | _reg(rt))

    if mn == 'mrs':
        # MRS Xt, sysreg
        rt, sysreg = args
        enc = _sysreg(sysreg)
        return to_le_hex(0xD5300000 | (enc << 5) | _reg(rt))

    raise ValueError(f"Unknown mnemonic: {mnemonic}")

# ---------------------------------------------------------------------------
# Address loading helper
# ---------------------------------------------------------------------------

def load_addr(reg, addr):
    """Generate a MOVZ/MOVK sequence to load a 64-bit address into reg.

    Uses the minimum number of instructions needed:
      1 instruction  for addr <= 0xFFFF
      2 instructions for addr <= 0xFFFFFFFF
      3 instructions for addr <= 0xFFFFFFFFFFFF
      4 instructions for anything larger
    """
    addr = addr & 0xFFFFFFFFFFFFFFFF
    chunks = []
    for i in range(4):
        hw = (addr >> (i * 16)) & 0xFFFF
        chunks.append((hw, i * 16))

    # Find the lowest non-zero chunk for MOVZ, rest use MOVK
    result = []
    first = True
    for hw, shift in chunks:
        if hw == 0 and first:
            continue  # skip leading zeros; MOVZ will zero the rest
        if first:
            result.append(emit('movz', reg, hw, shift))
            first = True  # already set, but mark that we emitted movz
            first = False
        else:
            if hw != 0:
                result.append(emit('movk', reg, hw, shift))

    if not result:
        # addr is 0
        result.append(emit('movz', reg, 0, 0))

    return result

# ---------------------------------------------------------------------------
# CLI interface
# ---------------------------------------------------------------------------

def _parse_arg(a):
    """Parse a single CLI argument as register name, sysreg, or integer."""
    al = a.lower()
    if al in REGS:
        return al
    if al in SYSREGS:
        return al
    if al in CONDS:
        return al
    return int(a, 0)


if __name__ == '__main__':
    if len(sys.argv) > 1 and sys.argv[1] == 'load_addr':
        reg = sys.argv[2]
        addr = int(sys.argv[3], 0)
        for line in load_addr(reg, addr):
            print(line)
    elif len(sys.argv) > 1:
        mnemonic = sys.argv[1]
        args = [_parse_arg(a) for a in sys.argv[2:]]
        print(emit(mnemonic, *args))
    else:
        # Batch mode from stdin
        for line in sys.stdin:
            line = line.strip()
            if not line or line.startswith('#'):
                continue
            parts = line.split()
            mnemonic = parts[0]
            args = [_parse_arg(a) for a in parts[1:]]
            result = emit(mnemonic, *args)
            comment = f"# {line}"
            print(f"{result}  {comment}")
