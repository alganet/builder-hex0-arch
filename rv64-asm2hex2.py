#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: Apache-2.0
"""Convert RISC-V assembly to hex2 format for the stage0 hex2 linker.

Reads RISC-V assembly from stdin, outputs hex2 to stdout.
Labels become hex2 label definitions (:name).
Branch targets become hex2 relative references (@label).
Jump targets become hex2 absolute references ($label).

Usage: python3 rv64-asm2hex2.py < kernel.S > kernel.hex2
"""
import sys
import re

REGS = {
    'zero':0, 'ra':1, 'sp':2, 'gp':3, 'tp':4,
    't0':5, 't1':6, 't2':7,
    's0':8, 'fp':8, 's1':9,
    'a0':10, 'a1':11, 'a2':12, 'a3':13, 'a4':14, 'a5':15, 'a6':16, 'a7':17,
    's2':18, 's3':19, 's4':20, 's5':21, 's6':22, 's7':23,
    's8':24, 's9':25, 's10':26, 's11':27,
    't3':28, 't4':29, 't5':30, 't6':31,
}

CSRS = {
    'sstatus': 0x100, 'sie': 0x104, 'stvec': 0x105,
    'sscratch': 0x140, 'sepc': 0x141, 'scause': 0x142,
    'stval': 0x143, 'sip': 0x144, 'satp': 0x180,
    'mstatus': 0x300, 'mie': 0x304, 'mtvec': 0x305,
    'mscratch': 0x340, 'mepc': 0x341, 'mcause': 0x342,
    'mtval': 0x343, 'mip': 0x344,
}

def to_le_hex(val, nbytes=4):
    val = val & ((1 << (nbytes*8)) - 1)
    return ''.join(f'{(val >> (i*8)) & 0xFF:02X}' for i in range(nbytes))

def frag(val):
    """Return a hex2 fragment like .00800200"""
    return f'.{to_le_hex(val)}'

def rd_f(r): return frag(REGS[r] << 7)
def rs1_f(r): return frag(REGS[r] << 15)
def rs2_f(r): return frag(REGS[r] << 20)
def rs1_raw_f(v): return frag((v & 0x1F) << 15)
def itype_f(imm): return frag((imm & 0xFFF) << 20)
def stype_f(imm):
    imm = imm & 0xFFF
    lo = (imm & 0x1F) << 7
    hi = ((imm >> 5) & 0x7F) << 25
    return frag(lo | hi)
def utype_f(imm): return frag((imm & 0xFFFFF) << 12)
def csr_f(csr):
    if isinstance(csr, str):
        csr = CSRS[csr]
    return frag((csr & 0xFFF) << 20)

OPCODES = {
    'lui': '37000000', 'auipc': '17000000',
    'jal': '6F000000', 'jalr': '67000000',
    'beq': '63000000', 'bne': '63100000',
    'blt': '63400000', 'bge': '63500000',
    'bltu': '63600000', 'bgeu': '63700000',
    'lb': '03000000', 'lh': '03100000', 'lw': '03200000',
    'ld': '03300000', 'lbu': '03400000', 'lhu': '03500000', 'lwu': '03600000',
    'sb': '23000000', 'sh': '23100000', 'sw': '23200000', 'sd': '23300000',
    'addi': '13000000', 'slti': '13200000', 'sltiu': '13300000',
    'xori': '13400000', 'ori': '13600000', 'andi': '13700000',
    'slli': '13100000', 'srli': '13500000', 'srai': '13500040',
    'add': '33000000', 'sub': '33000040',
    'sll': '33100000', 'slt': '33200000', 'sltu': '33300000',
    'xor': '33400000', 'srl': '33500000', 'sra': '33500040',
    'or': '33600000', 'and': '33700000',
    'ecall': '73000000', 'ebreak': '73001000',
    'sret': '73002010',
    'ret': '67800000',
    'fence': '0F00F00F', 'fence.i': '0F100000',
    'addiw': '1B000000',
    'csrrw': '73100000', 'csrrs': '73200000', 'csrrc': '73300000',
    'csrrwi': '73500000', 'csrrsi': '73600000', 'csrrci': '73700000',
    'mulw': '3B000002', 'divw': '3B400002', 'remw': '3B600002',
    'mul': '33000002', 'div': '33400002', 'rem': '33600002',
}

def parse_args(args_str):
    """Parse comma/space-separated args, handling offset(reg) syntax."""
    args_str = args_str.strip()
    if not args_str:
        return []
    # Handle offset(reg) syntax: e.g., "0x10(sp)" → ["sp", "0x10"] (rs1, imm)
    # Replace "imm(reg)" with "reg imm" for load/store
    args_str = re.sub(r'(-?(?:0x[0-9a-fA-F]+|\d+))\((\w+)\)', r'\2 \1', args_str)
    parts = [x.strip() for x in args_str.replace(',', ' ').split() if x.strip()]
    result = []
    for p in parts:
        if p in REGS:
            result.append(('reg', p))
        elif p in CSRS:
            result.append(('csr', p))
        else:
            try:
                result.append(('imm', int(p, 0)))
            except ValueError:
                result.append(('label', p))
    return result

def emit(mnemonic, args, comment=''):
    """Generate hex2 line(s) from instruction."""
    pad = f'  # {comment}' if comment else ''

    # No-argument instructions
    if mnemonic == 'sfence.vma':
        return f'73000012{pad}'  # sfence.vma x0, x0
    if mnemonic in ('ecall', 'sret', 'ret', 'fence', 'fence.i', 'ebreak'):
        return f'{OPCODES[mnemonic]}{pad}'

    op = OPCODES.get(mnemonic)

    # --- R-type ---
    if mnemonic in ('add', 'sub', 'sll', 'slt', 'sltu', 'xor', 'srl', 'sra', 'or', 'and',
                     'mul', 'div', 'rem', 'mulw', 'divw', 'remw'):
        _, r_d = args[0]
        _, r_s1 = args[1]
        _, r_s2 = args[2]
        return f'{rd_f(r_d)} {rs1_f(r_s1)} {rs2_f(r_s2)} {op}{pad}'

    # --- I-type (arithmetic) ---
    if mnemonic in ('addi', 'andi', 'ori', 'xori', 'slti', 'sltiu', 'addiw'):
        _, r_d = args[0]
        _, r_s1 = args[1]
        _, imm = args[2]
        return f'{rd_f(r_d)} {rs1_f(r_s1)} {itype_f(imm)} {op}{pad}'

    # --- Shifts ---
    if mnemonic in ('slli', 'srli', 'srai'):
        _, r_d = args[0]
        _, r_s1 = args[1]
        _, shamt = args[2]
        return f'{rd_f(r_d)} {rs1_f(r_s1)} {itype_f(shamt)} {op}{pad}'

    # --- Loads ---
    if mnemonic in ('lb', 'lh', 'lw', 'ld', 'lbu', 'lhu', 'lwu'):
        _, r_d = args[0]
        _, r_s1 = args[1]
        imm = args[2][1] if len(args) > 2 else 0
        return f'{rd_f(r_d)} {rs1_f(r_s1)} {itype_f(imm)} {op}{pad}'

    # --- Stores ---
    if mnemonic in ('sb', 'sh', 'sw', 'sd'):
        _, r_s2 = args[0]
        _, r_s1 = args[1]
        imm = args[2][1] if len(args) > 2 else 0
        return f'{rs1_f(r_s1)} {rs2_f(r_s2)} {stype_f(imm)} {op}{pad}'

    # --- LUI/AUIPC ---
    if mnemonic in ('lui', 'auipc'):
        _, r_d = args[0]
        _, imm = args[1]
        return f'{rd_f(r_d)} {utype_f(imm)} {op}{pad}'

    # --- JAL with label ---
    if mnemonic == 'jal':
        _, r_d = args[0]
        if args[1][0] == 'label':
            label = args[1][1]
            return f'{rd_f(r_d)} ${label} {op}{pad}'
        else:
            raise ValueError(f"jal needs label target")

    # --- JALR ---
    if mnemonic == 'jalr':
        _, r_d = args[0]
        _, r_s1 = args[1]
        imm = args[2][1] if len(args) > 2 else 0
        return f'{rd_f(r_d)} {rs1_f(r_s1)} {itype_f(imm)} {op}{pad}'

    # --- Branches ---
    if mnemonic in ('beq', 'bne', 'blt', 'bge', 'bltu', 'bgeu'):
        _, r_s1 = args[0]
        _, r_s2 = args[1]
        label = args[2][1]
        return f'{rs1_f(r_s1)} {rs2_f(r_s2)} @{label} {op}{pad}'

    # --- CSR ---
    if mnemonic in ('csrrw', 'csrrs', 'csrrc'):
        _, r_d = args[0]
        csr = args[1][1] if args[1][0] == 'csr' else args[1][1]
        _, r_s1 = args[2]
        return f'{rd_f(r_d)} {rs1_f(r_s1)} {csr_f(csr)} {op}{pad}'

    if mnemonic in ('csrrwi', 'csrrsi', 'csrrci'):
        _, r_d = args[0]
        csr = args[1][1] if args[1][0] == 'csr' else args[1][1]
        _, zimm = args[2]
        return f'{rd_f(r_d)} {rs1_raw_f(zimm)} {csr_f(csr)} {op}{pad}'

    # --- Pseudo-instructions ---
    if mnemonic == 'mv':
        _, r_d = args[0]
        _, r_s1 = args[1]
        return f'{rd_f(r_d)} {rs1_f(r_s1)} {OPCODES["addi"]}{pad}'

    if mnemonic == 'li':
        _, r_d = args[0]
        _, imm = args[1]
        if -2048 <= imm <= 2047:
            return f'{rd_f(r_d)} {itype_f(imm)} {OPCODES["addi"]}{pad}'
        else:
            # Need lui + addi for larger values
            upper = (imm + 0x800) >> 12
            lower = imm - (upper << 12)
            lines = [f'{rd_f(r_d)} {utype_f(upper)} {OPCODES["lui"]}  # li {r_d}, {imm} (upper)']
            if lower != 0:
                lines.append(f'{rd_f(r_d)} {rs1_f(r_d)} {itype_f(lower)} {OPCODES["addi"]}  # li {r_d}, {imm} (lower)')
            return '\n'.join(lines)

    if mnemonic == 'la':
        # Load address label (use $label with jal-like encoding but we'll use auipc+addi)
        # For hex2, labels resolve at link time. Use special handling.
        _, r_d = args[0]
        label = args[1][1]
        # This is tricky in hex2... skip for now
        raise ValueError(f"la not supported, use lui/addi or load from global")

    if mnemonic == 'j':
        # j label = jal zero, label
        label = args[0][1]
        return f'${label} {OPCODES["jal"]}' + pad

    if mnemonic == 'jr':
        # jr rs1 = jalr zero, rs1, 0
        _, r_s1 = args[0]
        return f'{rs1_f(r_s1)} {OPCODES["jalr"]}{pad}'

    if mnemonic == 'call':
        # call label = jal ra, label
        label = args[0][1]
        return f'{rd_f("ra")} ${label} {OPCODES["jal"]}{pad}'

    if mnemonic == 'beqz':
        _, r_s1 = args[0]
        label = args[1][1]
        return f'{rs1_f(r_s1)} @{label} {OPCODES["beq"]}{pad}'

    if mnemonic == 'bnez':
        _, r_s1 = args[0]
        label = args[1][1]
        return f'{rs1_f(r_s1)} @{label} {OPCODES["bne"]}{pad}'

    if mnemonic == 'bgez':
        _, r_s1 = args[0]
        label = args[1][1]
        return f'{rs1_f(r_s1)} @{label} {OPCODES["bge"]}{pad}'

    if mnemonic == 'blez':
        # blez rs1, label = bge zero, rs1, label
        _, r_s1 = args[0]
        label = args[1][1]
        return f'{rs2_f(r_s1)} @{label} {OPCODES["bge"]}{pad}'

    if mnemonic == 'bgtz':
        # bgtz rs1, label = blt zero, rs1, label
        _, r_s1 = args[0]
        label = args[1][1]
        return f'{rs2_f(r_s1)} @{label} {OPCODES["blt"]}{pad}'

    if mnemonic == 'bltz':
        _, r_s1 = args[0]
        label = args[1][1]
        return f'{rs1_f(r_s1)} @{label} {OPCODES["blt"]}{pad}'

    if mnemonic == 'neg':
        _, r_d = args[0]
        _, r_s2 = args[1]
        return f'{rd_f(r_d)} {rs2_f(r_s2)} {OPCODES["sub"]}{pad}'

    if mnemonic == 'not':
        _, r_d = args[0]
        _, r_s1 = args[1]
        return f'{rd_f(r_d)} {rs1_f(r_s1)} {itype_f(-1)} {OPCODES["xori"]}{pad}'

    if mnemonic == 'seqz':
        _, r_d = args[0]
        _, r_s1 = args[1]
        return f'{rd_f(r_d)} {rs1_f(r_s1)} {itype_f(1)} {OPCODES["sltiu"]}{pad}'

    if mnemonic == 'snez':
        _, r_d = args[0]
        _, r_s2 = args[1]
        return f'{rd_f(r_d)} {rs2_f(r_s2)} {OPCODES["sltu"]}{pad}'

    if mnemonic == 'nop':
        return f'{OPCODES["addi"]}{pad}'  # addi zero, zero, 0

    if mnemonic == '.word':
        # Emit raw 32-bit word in little-endian hex
        _, val = args[0]
        return f'{to_le_hex(val)}{pad}'

    if mnemonic == '.dword':
        # Emit raw 64-bit word in little-endian hex
        _, val = args[0]
        return f'{to_le_hex(val, 8)}{pad}'

    raise ValueError(f"Unknown mnemonic: {mnemonic}")


def process_line(raw_line):
    """Process one line of assembly input."""
    # Preserve raw hex2 lines (starting with hex digits or dots)
    stripped = raw_line.strip()
    if not stripped:
        return ''

    # Pass through pure comments
    if stripped.startswith('#') or stripped.startswith(';'):
        return stripped

    # Pass through raw hex2 (lines starting with . or hex digits or containing only hex+spaces)
    if re.match(r'^[0-9A-Fa-f.\s@$:&%]+$', stripped.split('#')[0].strip()):
        return raw_line.rstrip()

    # Extract comment
    comment_idx = stripped.find('#')
    if comment_idx >= 0:
        comment = stripped[comment_idx+1:].strip()
        code = stripped[:comment_idx].strip()
    else:
        comment = ''
        code = stripped

    if not code:
        return f'# {comment}' if comment else ''

    # Handle label definitions
    if code.endswith(':') and ' ' not in code:
        return f':{code[:-1]}'

    # Parse instruction
    parts = code.split(None, 1)
    mnemonic = parts[0].lower()
    args_str = parts[1] if len(parts) > 1 else ''
    args = parse_args(args_str)

    # Handle 'j' pseudo with special parsing (no reg arg)
    if mnemonic == 'j':
        label = args_str.strip().rstrip(',')
        args = [('label', label)]
    elif mnemonic == 'call':
        label = args_str.strip().rstrip(',')
        args = [('label', label)]
    elif mnemonic == 'jr':
        reg = args_str.strip().rstrip(',')
        args = [('reg', reg)]

    full_comment = f'{code}'
    try:
        result = emit(mnemonic, args, full_comment)
        return result
    except Exception as e:
        print(f"# ERROR: {e} on line: {raw_line.rstrip()}", file=sys.stderr)
        return f'# ERROR: {raw_line.rstrip()}'


def main():
    for line in sys.stdin:
        result = process_line(line)
        if result is not None:
            print(result)

if __name__ == '__main__':
    main()
