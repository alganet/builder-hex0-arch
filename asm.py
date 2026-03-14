#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: Apache-2.0
"""Encode RISC-V instructions to hex2 fragments.

Standalone usage: python3 asm.py <mnemonic> <arg1> <arg2> ...
Batch mode:      echo "addi a0, a0, 1" | python3 asm.py
Library usage:   from asm import emit, load_addr
"""
import sys

REGS = {
    'zero':0, 'ra':1, 'sp':2, 'gp':3, 'tp':4,
    't0':5, 't1':6, 't2':7,
    's0':8, 'fp':8, 's1':9,
    'a0':10, 'a1':11, 'a2':12, 'a3':13, 'a4':14, 'a5':15, 'a6':16, 'a7':17,
    's2':18, 's3':19, 's4':20, 's5':21, 's6':22, 's7':23,
    's8':24, 's9':25, 's10':26, 's11':27,
    't3':28, 't4':29, 't5':30, 't6':31,
}

def to_le_hex(val, nbytes=4):
    val = val & ((1 << (nbytes*8)) - 1)
    return ''.join(f'{(val >> (i*8)) & 0xFF:02X}' for i in range(nbytes))

def rd(r): return to_le_hex(REGS[r] << 7)
def rs1(r): return to_le_hex(REGS[r] << 15)
def rs1_raw(v): return to_le_hex((v & 0x1F) << 15)
def rs2(r): return to_le_hex(REGS[r] << 20)
def itype_imm(imm): return to_le_hex((imm & 0xFFF) << 20)
def stype_imm(imm):
    imm = imm & 0xFFF
    lo = (imm & 0x1F) << 7
    hi = ((imm >> 5) & 0x7F) << 25
    return to_le_hex(lo | hi)
def utype_imm(imm):
    """For lui/auipc: imm is the value to load into upper 20 bits."""
    return to_le_hex((imm & 0xFFFFF) << 12)

OPCODES = {
    'lui': '37000000', 'auipc': '17000000',
    'jal': '6F000000', 'jalr': '67000000',
    'beq': '63000000', 'bne': '63100000',
    'blt': '63400000', 'bge': '63500000',
    'bltu': '63600000', 'bgeu': '63700000',
    'lb': '03000000', 'lh': '03100000', 'lw': '03200000',
    'ld': '03300000', 'lbu': '03400000', 'lhu': '03500000',
    'sb': '23000000', 'sh': '23100000', 'sw': '23200000', 'sd': '23300000',
    'addi': '13000000', 'slti': '13200000', 'sltiu': '13300000',
    'xori': '13400000', 'ori': '13600000', 'andi': '13700000',
    'slli': '13100000', 'srli': '13500000', 'srai': '13500040',
    'add': '33000000', 'sub': '33000040',
    'sll': '33100000', 'slt': '33200000', 'sltu': '33300000',
    'xor': '33400000', 'srl': '33500000', 'sra': '33500040',
    'or': '33600000', 'and': '33700000',
    'ecall': '73000000', 'ebreak': '73001000',
    'sret': '73000020',
    'ret': '67800000',
    'fence': '0F00F00F',
    'addiw': '1B000000',
    'csrrw': '73100000', 'csrrs': '73200000', 'csrrc': '73300000',
    'csrrwi': '73500000', 'csrrsi': '73600000', 'csrrci': '73700000',
}

CSRS = {
    'sstatus': 0x100, 'sie': 0x104, 'stvec': 0x105,
    'sscratch': 0x140, 'sepc': 0x141, 'scause': 0x142,
    'stval': 0x143, 'sip': 0x144, 'satp': 0x180,
    'mstatus': 0x300, 'mie': 0x304, 'mtvec': 0x305,
    'mscratch': 0x340, 'mepc': 0x341, 'mcause': 0x342,
    'mtval': 0x343, 'mip': 0x344,
}

def csr_imm(csr):
    """Encode CSR number into imm[31:20] field (same position as I-type imm)."""
    if isinstance(csr, str):
        csr = CSRS[csr]
    return to_le_hex((csr & 0xFFF) << 20)

def lui_addr(addr):
    """Compute lui immediate and addi correction for loading an address.
    Returns (lui_upper20, addi_imm12) such that:
      lui rd, upper20  → rd = upper20 << 12
      addi rd, rd, imm12 → rd = addr
    """
    if addr & 0x800:  # bit 11 set, addi will subtract, need to add 1 to lui
        upper = ((addr >> 12) + 1) & 0xFFFFF
    else:
        upper = (addr >> 12) & 0xFFFFF
    lower = addr & 0xFFF
    if lower & 0x800:  # sign extend
        lower = lower - 0x1000
    return upper, lower & 0xFFF

def emit(mnemonic, *args):
    """Generate hex2 instruction line."""
    parts = []
    op = OPCODES.get(mnemonic, None)

    if mnemonic == 'ecall':
        return '73000000'
    elif mnemonic == 'ret':
        return '67800000'
    elif mnemonic == 'fence':
        return '0F00F00F'
    elif mnemonic == 'lui':
        # lui rd, imm20
        r, imm = args
        parts = [f'.{rd(r)}', f'.{utype_imm(imm)}', op]
    elif mnemonic in ('addi', 'andi', 'ori', 'xori', 'slti', 'sltiu', 'addiw'):
        # I-type: op rd, rs1, imm12
        r_d, r_s1, imm = args
        parts = [f'.{rd(r_d)}', f'.{rs1(r_s1)}', f'.{itype_imm(imm)}', op]
    elif mnemonic in ('slli', 'srli', 'srai'):
        # Shift: op rd, rs1, shamt
        r_d, r_s1, shamt = args
        parts = [f'.{rd(r_d)}', f'.{rs1(r_s1)}', f'.{itype_imm(shamt)}', op]
    elif mnemonic in ('lb', 'lh', 'lw', 'ld', 'lbu', 'lhu'):
        # Load: op rd, imm(rs1)
        r_d, r_s1, imm = args
        parts = [f'.{rd(r_d)}', f'.{rs1(r_s1)}', f'.{itype_imm(imm)}', op]
    elif mnemonic in ('sb', 'sh', 'sw', 'sd'):
        # Store: op rs2, imm(rs1)
        r_s2, r_s1, imm = args
        parts = [f'.{rs1(r_s1)}', f'.{rs2(r_s2)}', f'.{stype_imm(imm)}', op]
    elif mnemonic == 'jalr':
        # jalr rd, rs1, imm
        r_d, r_s1, imm = args
        parts = [f'.{rd(r_d)}', f'.{rs1(r_s1)}', f'.{itype_imm(imm)}', op]
    elif mnemonic in ('add', 'sub', 'sll', 'slt', 'sltu', 'xor', 'srl', 'sra', 'or', 'and'):
        # R-type: op rd, rs1, rs2
        r_d, r_s1, r_s2 = args
        parts = [f'.{rd(r_d)}', f'.{rs1(r_s1)}', f'.{rs2(r_s2)}', op]
    elif mnemonic == 'sret':
        return '73002010'
    elif mnemonic in ('csrrw', 'csrrs', 'csrrc'):
        # CSR: op rd, csr, rs1
        r_d, csr, r_s1 = args
        parts = [f'.{rd(r_d)}', f'.{rs1(r_s1)}', f'.{csr_imm(csr)}', op]
    elif mnemonic in ('csrrwi', 'csrrsi', 'csrrci'):
        # CSR immediate: op rd, csr, zimm[4:0]
        r_d, csr, zimm = args
        parts = [f'.{rd(r_d)}', f'.{rs1_raw(zimm)}', f'.{csr_imm(csr)}', op]
    elif mnemonic in ('beq', 'bne', 'blt', 'bge', 'bltu', 'bgeu'):
        # B-type: op rs1, rs2 (offset handled by hex2 @label)
        r_s1, r_s2 = args[:2]
        parts = [f'.{rs1(r_s1)}', f'.{rs2(r_s2)}', op]
    elif mnemonic == 'mv':
        # pseudo: addi rd, rs1, 0
        r_d, r_s1 = args
        parts = [f'.{rd(r_d)}', f'.{rs1(r_s1)}', OPCODES['addi']]
    elif mnemonic == 'li':
        # pseudo: addi rd, zero, imm
        r_d, imm = args
        parts = [f'.{rd(r_d)}', f'.{itype_imm(imm)}', OPCODES['addi']]
    elif mnemonic == 'neg':
        # pseudo: sub rd, zero, rs2
        r_d, r_s2 = args
        parts = [f'.{rd(r_d)}', f'.{rs2(r_s2)}', OPCODES['sub']]
    elif mnemonic == 'not':
        # pseudo: xori rd, rs1, -1
        r_d, r_s1 = args
        parts = [f'.{rd(r_d)}', f'.{rs1(r_s1)}', f'.{itype_imm(-1)}', OPCODES['xori']]
    elif mnemonic == 'seqz':
        # pseudo: sltiu rd, rs1, 1
        r_d, r_s1 = args
        parts = [f'.{rd(r_d)}', f'.{rs1(r_s1)}', f'.{itype_imm(1)}', OPCODES['sltiu']]
    elif mnemonic == 'snez':
        # pseudo: sltu rd, zero, rs2
        r_d, r_s2 = args
        parts = [f'.{rd(r_d)}', f'.{rs2(r_s2)}', OPCODES['sltu']]
    else:
        raise ValueError(f"Unknown mnemonic: {mnemonic}")

    return ' '.join(parts)

# Process command line
if len(sys.argv) > 1:
    mnemonic = sys.argv[1]
    args = []
    for a in sys.argv[2:]:
        if a in REGS:
            args.append(a)
        elif a in CSRS:
            args.append(a)
        else:
            args.append(int(a, 0))
    print(emit(mnemonic, *args))
else:
    # Interactive/batch mode - read from stdin
    for line in sys.stdin:
        line = line.strip()
        if not line or line.startswith('#'):
            continue
        parts = line.split()
        mnemonic = parts[0]
        args = []
        for a in parts[1:]:
            if a in REGS:
                args.append(a)
            elif a in CSRS:
                args.append(a)
            else:
                args.append(int(a, 0))
        result = emit(mnemonic, *args)
        # Also show lui_addr helper if needed
        comment = f"# {line}"
        print(f"{result}  {comment}")

def load_addr(reg, addr):
    """Generate hex2 to load a 32-bit address into reg on RV64.
    For addresses with bit 31 set, uses 3 instructions to avoid sign extension.
    For addresses without bit 31, uses standard lui+addi."""
    if addr & 0x80000000:
        # Shift right by 1 to clear bit 31
        half = addr >> 1  # bit 31 is now 0
        upper, lower = lui_addr(half)
        result = []
        if lower == 0:
            result.append(emit('lui', 't0', upper))
        else:
            result.append(emit('lui', 't0', upper))
            result.append(emit('addi', 't0', 't0', lower))
        result.append(emit('slli', reg, 't0', 1))
        return result
    else:
        upper, lower = lui_addr(addr)
        result = [emit('lui', reg, upper)]
        if lower:
            result.append(emit('addi', reg, reg, lower))
        return result

if __name__ == '__main__' and len(sys.argv) > 1 and sys.argv[1] == 'load_addr':
    reg = sys.argv[2]
    addr = int(sys.argv[3], 0)
    for line in load_addr(reg, addr):
        print(line)
