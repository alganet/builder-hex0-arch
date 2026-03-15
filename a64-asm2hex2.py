#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: Apache-2.0
"""Convert AArch64 assembly to hex2 format for the stage0 hex2 linker.

Reads AArch64 assembly from stdin, outputs hex2 to stdout.
Labels become hex2 label definitions (:name).
Branch targets are resolved by the converter (two-pass) since hex2's
@/$/~/! reference types use RISC-V-specific encoding.

Usage: python3 a64-asm2hex2.py < input.S > output.hex2
"""
import sys
import re

from a64_asm import emit as a64_emit, to_le_hex, REGS

# ---------------------------------------------------------------------------
# Register helpers
# ---------------------------------------------------------------------------

def normalize_reg(name):
    """Normalize a register name: strip leading w/x prefix for emit() mapping.

    For emit() calls, we always pass the x-form register name.
    w0-w30 map to x0-x30.  sp, xzr, wzr, lr stay as-is.
    """
    name = name.lower().strip()
    if name in ('sp', 'xzr', 'wzr', 'lr'):
        return name
    # w0..w30 -> x0..x30 for emit register name mapping
    m = re.match(r'^w(\d+)$', name)
    if m:
        return f'x{m.group(1)}'
    return name


def is_reg(tok):
    """Check if token is a register name."""
    return tok.lower().strip() in REGS


def parse_int(s):
    """Parse an integer literal (decimal or hex)."""
    s = s.strip()
    if s.startswith('-'):
        return -parse_int(s[1:])
    return int(s, 0)


# ---------------------------------------------------------------------------
# Offset validation helpers
# ---------------------------------------------------------------------------

def check_offset(offset, bits, name):
    """Validate a PC-relative offset is aligned and in range.

    bits: number of signed immediate bits AFTER dividing by 4.
    For ADR, pass bits=21 and align=1 (byte-granular).
    """
    lo = -(1 << (bits - 1))
    hi = (1 << (bits - 1)) - 1
    if name != 'adr' and (offset & 0x3) != 0:
        raise ValueError(f"{name}: offset {offset:#x} is not 4-byte aligned")
    if name == 'adr':
        if offset < -(1 << 20) or offset >= (1 << 20):
            raise ValueError(f"{name}: offset {offset:#x} out of ±1MB range")
    else:
        imm = offset // 4
        if imm < lo or imm > hi:
            raise ValueError(
                f"{name}: offset {offset:#x} out of range "
                f"(needs {bits}-bit signed immediate)")

# ---------------------------------------------------------------------------
# Tokenizing helpers
# ---------------------------------------------------------------------------

def split_args(args_str):
    """Split comma-separated arguments, respecting brackets.

    Returns a list of stripped argument strings.
    E.g. "x0, [x1, #8]" -> ["x0", "[x1, #8]"]
    """
    args = []
    depth = 0
    current = []
    for ch in args_str:
        if ch == '[':
            depth += 1
            current.append(ch)
        elif ch == ']':
            depth -= 1
            current.append(ch)
        elif ch == ',' and depth == 0:
            args.append(''.join(current).strip())
            current = []
        else:
            current.append(ch)
    tail = ''.join(current).strip()
    if tail:
        args.append(tail)
    return args


def parse_mem_operand(tok):
    """Parse a memory operand like [x1, #8] or [x1] or [x1, x2].

    Returns (base_reg, offset_or_reg, is_reg_offset).
    For [x1, #8]  -> ('x1', 8, False)
    For [x1]      -> ('x1', 0, False)
    For [x1, x2]  -> ('x1', 'x2', True)
    """
    tok = tok.strip()
    # Handle pre-index: [Xn, #imm]!
    pre_index = tok.endswith('!')
    if pre_index:
        tok = tok[:-1].strip()
    # Strip brackets
    inner = tok.strip('[]').strip()
    parts = [p.strip() for p in inner.split(',')]
    base = normalize_reg(parts[0])
    if len(parts) == 1:
        return base, 0, False, pre_index
    second = parts[1].strip()
    if second.startswith('#'):
        return base, parse_int(second[1:]), False, pre_index
    else:
        return base, normalize_reg(second), True, pre_index


def parse_post_index(args):
    """Parse post-index form: [Xn], #imm.

    args should be like ["[sp]", "#16"] after the register pair.
    Returns (base_reg, offset).
    """
    mem = args[0].strip().strip('[]').strip()
    base = normalize_reg(mem)
    offset = parse_int(args[1].strip().lstrip('#'))
    return base, offset


# ---------------------------------------------------------------------------
# Line classification
# ---------------------------------------------------------------------------

def is_raw_hex2(stripped):
    """Check if a line is raw hex2 (hex digits, dots, spaces, colons, etc.)."""
    # Get the code part (before any comment)
    code = stripped.split('#')[0].strip()
    if not code:
        return False
    if re.match(r'^[0-9A-Fa-f.\s:@$&%~!]+$', code):
        return True
    return False


def count_hex_bytes(stripped):
    """Count the number of hex byte pairs in a raw hex2 line."""
    code = stripped.split('#')[0].strip()
    # Remove labels (:name), references (@name $name etc.), dots
    # Count consecutive hex digit pairs
    count = 0
    i = 0
    clean = re.sub(r'[:@$~!]\w+', '', code)  # remove label/ref tokens
    clean = clean.replace('.', '')  # dots are fragment separators
    hex_digits = re.findall(r'[0-9A-Fa-f]{2}', clean)
    return len(hex_digits)


# ---------------------------------------------------------------------------
# Pass 1: Compute label addresses
# ---------------------------------------------------------------------------

def pass1(lines):
    """First pass: compute byte address of each label.

    Returns (labels_dict, parsed_lines) where parsed_lines contains
    tuples of (line_type, data, original_line).
    """
    labels = {}
    parsed = []
    addr = 0

    for raw_line in lines:
        stripped = raw_line.strip()

        # Blank lines
        if not stripped:
            parsed.append(('blank', None, raw_line))
            continue

        # Pure comments
        if stripped.startswith('#') or stripped.startswith(';'):
            parsed.append(('comment', None, raw_line))
            continue

        # Extract comment from code.
        # In AArch64, '#' is used for immediates (#42, #0x1234, #-1).
        # A '#' is a comment if: it's followed by a space or letter (not
        # a digit, minus sign, or 'x' for hex), OR it's at end of line.
        # A ';' is always a comment character.
        comment_idx = -1
        for ci, ch in enumerate(stripped):
            if ch == ';':
                comment_idx = ci
                break
            if ch == '#':
                # Check if this is an immediate value prefix
                rest = stripped[ci + 1:] if ci + 1 < len(stripped) else ''
                rest_stripped = rest.lstrip()
                if rest_stripped and (rest_stripped[0].isdigit() or
                                     rest_stripped[0] == '-' or
                                     rest_stripped[0] == '+'):
                    continue  # This is an immediate, not a comment
                comment_idx = ci
                break

        if comment_idx >= 0:
            code = stripped[:comment_idx].strip()
            comment = stripped[comment_idx + 1:].strip()
        else:
            code = stripped
            comment = ''

        if not code:
            parsed.append(('comment', None, raw_line))
            continue

        # Label definition
        if code.endswith(':') and ' ' not in code and '\t' not in code:
            label_name = code[:-1]
            labels[label_name] = addr
            parsed.append(('label', label_name, raw_line))
            continue

        # Raw hex2 passthrough
        if is_raw_hex2(code):
            nbytes = count_hex_bytes(code)
            parsed.append(('raw', None, raw_line))
            addr += nbytes
            continue

        # Directives
        lower_code = code.lower()
        if lower_code.startswith('.word'):
            parsed.append(('directive', ('word', code, comment), raw_line))
            addr += 4
            continue

        if lower_code.startswith('.dword'):
            parsed.append(('directive', ('dword', code, comment), raw_line))
            addr += 8
            continue

        if lower_code.startswith('.zero'):
            parts = code.split(None, 1)
            n = parse_int(parts[1])
            parsed.append(('directive', ('zero', n, comment), raw_line))
            addr += n
            continue

        if lower_code.startswith('.align'):
            parts = code.split(None, 1)
            power = parse_int(parts[1])
            alignment = 1 << power  # GAS-style: .align N means align to 2^N bytes
            padding = (alignment - (addr % alignment)) % alignment
            parsed.append(('directive', ('align', alignment, padding, comment), raw_line))
            addr += padding
            continue

        # Instruction: 4 bytes
        parsed.append(('insn', (code, comment), raw_line))
        addr += 4

    return labels, parsed


# ---------------------------------------------------------------------------
# Pass 2: Emit hex2 output
# ---------------------------------------------------------------------------

def encode_instruction(code, comment, addr, labels):
    """Parse an AArch64 instruction and encode it via a64_asm.emit().

    Returns hex2 string for the instruction.
    """
    # Split mnemonic from operands
    parts = code.split(None, 1)
    mnemonic = parts[0].lower()
    args_str = parts[1] if len(parts) > 1 else ''
    args = split_args(args_str) if args_str else []

    full_comment = code
    if comment:
        full_comment = f'{code} # {comment}'

    try:
        hex_str = encode_mnemonic(mnemonic, args, addr, labels)
        return f'{hex_str}  # {full_comment}'
    except Exception as e:
        print(f"# ERROR: {e} on: {code}", file=sys.stderr)
        return f'# ERROR: {code}'


def encode_mnemonic(mnemonic, args, addr, labels):
    """Dispatch mnemonic to the correct a64_asm.emit() call."""

    # ---- No-operand instructions ----
    if mnemonic == 'ret':
        return a64_emit('ret')
    if mnemonic == 'eret':
        return a64_emit('eret')
    if mnemonic == 'nop':
        return a64_emit('nop')
    if mnemonic == 'wfe':
        return a64_emit('wfe')
    if mnemonic == 'isb':
        return a64_emit('isb')

    # ---- IC (instruction cache) ----
    if mnemonic == 'ic':
        variant = args[0].strip().lower() if args else 'iallu'
        return a64_emit(f'ic_{variant}')

    # ---- REV (byte reverse) ----
    if mnemonic == 'rev':
        rd = normalize_reg(args[0])
        rn = normalize_reg(args[1])
        if args[0].strip().startswith('w'):
            return a64_emit('rev_w', rd, rn)
        return a64_emit('rev', rd, rn)

    # ---- System (no-arg or special) ----
    if mnemonic == 'dsb':
        # dsb sy -> dsb_sy
        variant = args[0].strip().lower() if args else 'sy'
        return a64_emit(f'dsb_{variant}')

    if mnemonic == 'tlbi':
        variant = args[0].strip().lower() if args else 'vmalle1'
        return a64_emit(f'tlbi_{variant}')

    # ---- SVC / HVC ----
    if mnemonic == 'svc':
        imm = parse_int(args[0].lstrip('#'))
        return a64_emit('svc', imm)

    if mnemonic == 'hvc':
        imm = parse_int(args[0].lstrip('#'))
        return a64_emit('hvc', imm)

    # ---- MSR / MRS ----
    if mnemonic == 'msr':
        sysreg = args[0].strip().lower()
        # Special pstate fields: msr spsel, #imm / msr daifset, #imm
        if sysreg == 'spsel':
            imm = parse_int(args[1].strip().lstrip('#'))
            return a64_emit('msr_spsel', imm)
        if sysreg == 'daifset':
            imm = parse_int(args[1].strip().lstrip('#'))
            return a64_emit('msr_daifset', imm)
        if sysreg == 'daifclr':
            imm = parse_int(args[1].strip().lstrip('#'))
            return a64_emit('msr_daifclr', imm)
        rt = normalize_reg(args[1])
        return a64_emit('msr', sysreg, rt)

    if mnemonic == 'mrs':
        rt = normalize_reg(args[0])
        sysreg = args[1].strip().lower()
        return a64_emit('mrs', rt, sysreg)

    # ---- ADR (PC-relative address, with label resolution) ----
    if mnemonic == 'adr':
        rd = normalize_reg(args[0])
        target_label = args[1].strip()
        if target_label not in labels:
            raise ValueError(f"Unknown label: {target_label}")
        offset = labels[target_label] - addr
        check_offset(offset, 21, 'adr')
        # ADR Xd, offset: 0 immlo[1:0] 10000 immhi[18:0] Rd
        # immhi = offset[20:2], immlo = offset[1:0]
        immlo = offset & 0x3
        immhi = (offset >> 2) & 0x7FFFF
        val = (immlo << 29) | (0x10 << 24) | (immhi << 5) | REGS[rd]
        return to_le_hex(val)

    # ---- Branch (with label resolution) ----
    if mnemonic == 'b' and args and not is_reg(args[0]):
        target_label = args[0].strip()
        if target_label not in labels:
            raise ValueError(f"Unknown label: {target_label}")
        offset = labels[target_label] - addr
        check_offset(offset, 26, 'b')
        return a64_emit('b', offset)

    if mnemonic == 'bl':
        target_label = args[0].strip()
        if target_label not in labels:
            raise ValueError(f"Unknown label: {target_label}")
        offset = labels[target_label] - addr
        check_offset(offset, 26, 'bl')
        return a64_emit('bl', offset)

    if mnemonic.startswith('b.'):
        target_label = args[0].strip()
        if target_label not in labels:
            raise ValueError(f"Unknown label: {target_label}")
        offset = labels[target_label] - addr
        check_offset(offset, 19, mnemonic)
        return a64_emit(mnemonic, offset)

    if mnemonic == 'cbz':
        rt = normalize_reg(args[0])
        target_label = args[1].strip()
        if target_label not in labels:
            raise ValueError(f"Unknown label: {target_label}")
        offset = labels[target_label] - addr
        check_offset(offset, 19, 'cbz')
        return a64_emit('cbz', rt, offset)

    if mnemonic == 'cbnz':
        rt = normalize_reg(args[0])
        target_label = args[1].strip()
        if target_label not in labels:
            raise ValueError(f"Unknown label: {target_label}")
        offset = labels[target_label] - addr
        check_offset(offset, 19, 'cbnz')
        return a64_emit('cbnz', rt, offset)

    if mnemonic == 'br':
        rn = normalize_reg(args[0])
        return a64_emit('br', rn)

    if mnemonic == 'blr':
        rn = normalize_reg(args[0])
        return a64_emit('blr', rn)

    # ---- MOV (register) ----
    if mnemonic == 'mov':
        rd = normalize_reg(args[0])
        src = args[1].strip()
        if src.startswith('#'):
            imm = parse_int(src[1:])
            if 0 <= imm <= 0xFFFF:
                return a64_emit('movz', rd, imm, 0)
            else:
                from a64_asm import load_addr
                lines = load_addr(rd, imm)
                return '\n'.join(f'{line}  # mov {rd}, {src}'
                                for line in lines)
        else:
            rs = normalize_reg(src)
            return a64_emit('mov', rd, rs)

    # ---- MOVZ / MOVK / MOVN ----
    if mnemonic in ('movz', 'movk', 'movn'):
        rd = normalize_reg(args[0])
        imm16 = parse_int(args[1].lstrip('#'))
        shift = 0
        if len(args) > 2:
            # Parse "lsl #N"
            lsl_arg = args[2].strip().lower()
            m = re.match(r'lsl\s+#?(\d+)', lsl_arg)
            if m:
                shift = int(m.group(1))
        return a64_emit(mnemonic, rd, imm16, shift)

    # ---- NEG ----
    if mnemonic == 'neg':
        rd = normalize_reg(args[0])
        rm = normalize_reg(args[1])
        return a64_emit('neg', rd, rm)

    # ---- CMP / CMN / TST (2-operand) ----
    if mnemonic == 'cmp':
        rn = normalize_reg(args[0])
        second = args[1].strip()
        if second.startswith('#'):
            imm = parse_int(second[1:])
            return a64_emit('cmp_imm', rn, imm)
        else:
            rm = normalize_reg(second)
            return a64_emit('cmp', rn, rm)

    if mnemonic == 'cmn':
        rn = normalize_reg(args[0])
        second = args[1].strip()
        if second.startswith('#'):
            imm = parse_int(second[1:])
            return a64_emit('cmn_imm', rn, imm)
        else:
            rm = normalize_reg(second)
            return a64_emit('cmn', rn, rm)

    if mnemonic == 'tst':
        rn = normalize_reg(args[0])
        if args[1].strip().startswith('#'):
            imm = parse_int(args[1].strip()[1:])
            return a64_emit('tst_imm', rn, imm)
        rm = normalize_reg(args[1])
        return a64_emit('tst', rn, rm)

    # ---- ADD / SUB / ADDS / SUBS (3-operand, reg or imm) ----
    if mnemonic in ('add', 'sub', 'adds', 'subs'):
        rd = normalize_reg(args[0])
        rn = normalize_reg(args[1])
        third = args[2].strip()
        if third.startswith('#'):
            imm = parse_int(third[1:])
            return a64_emit(f'{mnemonic}_imm', rd, rn, imm)
        else:
            rm = normalize_reg(third)
            return a64_emit(mnemonic, rd, rn, rm)

    # ---- AND / ORR / EOR / ANDS (3-operand, register or immediate) ----
    if mnemonic in ('and', 'orr', 'eor', 'ands'):
        rd = normalize_reg(args[0])
        rn = normalize_reg(args[1])
        if args[2].strip().startswith('#'):
            imm = parse_int(args[2].strip()[1:])
            return a64_emit(mnemonic + '_imm', rd, rn, imm)
        rm = normalize_reg(args[2])
        return a64_emit(mnemonic, rd, rn, rm)

    # ---- MUL / UDIV / SDIV (3-operand register) ----
    if mnemonic in ('mul', 'udiv', 'sdiv'):
        rd = normalize_reg(args[0])
        rn = normalize_reg(args[1])
        rm = normalize_reg(args[2])
        return a64_emit(mnemonic, rd, rn, rm)

    # ---- SXTW (2-operand) ----
    if mnemonic == 'sxtw':
        rd = normalize_reg(args[0])
        rn = normalize_reg(args[1])
        return a64_emit('sxtw', rd, rn)

    # ---- Shifts: LSL / LSR / ASR ----
    if mnemonic in ('lsl', 'lsr', 'asr'):
        rd = normalize_reg(args[0])
        rn = normalize_reg(args[1])
        third = args[2].strip()
        if third.startswith('#'):
            imm = parse_int(third[1:])
            return a64_emit(f'{mnemonic}_imm', rd, rn, imm)
        else:
            rm = normalize_reg(third)
            return a64_emit(f'{mnemonic}v', rd, rn, rm)

    # ---- Load/Store Pair ----
    if mnemonic in ('stp', 'ldp'):
        rt1 = normalize_reg(args[0])
        rt2 = normalize_reg(args[1])
        mem_arg = args[2].strip()

        # Check for pre-index: [Xn, #imm]! (only stp_pre is implemented)
        if mem_arg.endswith('!'):
            if mnemonic != 'stp':
                raise ValueError(f'{mnemonic} pre-index not implemented')
            base, offset, is_reg_off, pre = parse_mem_operand(mem_arg)
            return a64_emit('stp_pre', rt1, rt2, base, offset)

        # Check for post-index: [Xn], #imm (only ldp_post is implemented)
        if len(args) > 3:
            if mnemonic != 'ldp':
                raise ValueError(f'{mnemonic} post-index not implemented')
            base_tok = mem_arg.strip('[]').strip()
            base = normalize_reg(base_tok)
            offset = parse_int(args[3].strip().lstrip('#'))
            return a64_emit('ldp_post', rt1, rt2, base, offset)

        # Signed offset: [Xn, #imm] or [Xn]
        base, offset, is_reg_off, pre = parse_mem_operand(mem_arg)
        return a64_emit(mnemonic, rt1, rt2, base, offset)

    # ---- Load/Store (single register) ----
    if mnemonic in ('ldr', 'str', 'ldrb', 'strb', 'ldrh', 'strh', 'ldrsw'):
        rt_raw = args[0].strip().lower()
        is_w_dest = rt_raw.startswith('w')
        rt = normalize_reg(rt_raw)

        base, off_or_reg, is_reg_off, pre_index = parse_mem_operand(args[1])

        if is_reg_off:
            # Register offset form
            if mnemonic == 'ldr':
                if is_w_dest:
                    return a64_emit('ldr_w_reg', rt, base, off_or_reg)
                return a64_emit('ldr_reg', rt, base, off_or_reg)
            elif mnemonic == 'str':
                if is_w_dest:
                    return a64_emit('str_w_reg', rt, base, off_or_reg)
                return a64_emit('str_reg', rt, base, off_or_reg)
            elif mnemonic == 'ldrb':
                return a64_emit('ldrb_reg', rt, base, off_or_reg)
            elif mnemonic == 'strb':
                return a64_emit('strb_reg', rt, base, off_or_reg)
            elif mnemonic == 'ldrh':
                return a64_emit('ldrh_reg', rt, base, off_or_reg)
            elif mnemonic == 'strh':
                return a64_emit('strh_reg', rt, base, off_or_reg)
            else:
                raise ValueError(f"Register offset not supported for {mnemonic}")
        else:
            # Immediate offset form
            offset = off_or_reg
            if mnemonic == 'ldr':
                if is_w_dest:
                    return a64_emit('ldr_w', rt, base, offset)
                return a64_emit('ldr', rt, base, offset)
            elif mnemonic == 'str':
                if is_w_dest:
                    return a64_emit('str_w', rt, base, offset)
                return a64_emit('str', rt, base, offset)
            elif mnemonic == 'ldrb':
                return a64_emit('ldrb', rt, base, offset)
            elif mnemonic == 'strb':
                return a64_emit('strb', rt, base, offset)
            elif mnemonic == 'ldrh':
                return a64_emit('ldrh', rt, base, offset)
            elif mnemonic == 'strh':
                return a64_emit('strh', rt, base, offset)
            elif mnemonic == 'ldrsw':
                return a64_emit('ldrsw', rt, base, offset)

    raise ValueError(f"Unknown mnemonic: {mnemonic}")


def emit_directive(directive_data):
    """Emit hex2 output for a directive."""
    kind = directive_data[0]

    if kind == 'word':
        _, code, comment = directive_data
        parts = code.split(None, 1)
        val = parse_int(parts[1])
        hex_str = to_le_hex(val)
        c = f'  # {code}' if code else ''
        return f'{hex_str}{c}'

    if kind == 'dword':
        _, code, comment = directive_data
        parts = code.split(None, 1)
        val = parse_int(parts[1])
        val = val & 0xFFFFFFFFFFFFFFFF
        # 8 bytes little-endian
        hex_str = ''.join(f'{(val >> (i * 8)) & 0xFF:02X}' for i in range(8))
        c = f'  # {code}' if code else ''
        return f'{hex_str}{c}'

    if kind == 'zero':
        _, n, comment = directive_data
        hex_str = '00' * n
        c = f'  # .zero {n}' if n else ''
        return f'{hex_str}{c}'

    if kind == 'align':
        _, alignment, padding, comment = directive_data
        if padding == 0:
            return f'# .align {alignment} (already aligned)'
        hex_str = '00' * padding
        return f'{hex_str}  # .align {alignment} ({padding} bytes padding)'

    raise ValueError(f"Unknown directive kind: {kind}")


def pass2(labels, parsed):
    """Second pass: emit hex2 output with resolved branch offsets."""
    output = []
    addr = 0

    for line_type, data, raw_line in parsed:
        if line_type == 'blank':
            output.append('')
            continue

        if line_type == 'comment':
            output.append(raw_line.rstrip())
            continue

        if line_type == 'label':
            output.append(f':{data}')
            continue

        if line_type == 'raw':
            output.append(raw_line.rstrip())
            nbytes = count_hex_bytes(raw_line.strip())
            addr += nbytes
            continue

        if line_type == 'directive':
            result = emit_directive(data)
            output.append(result)
            kind = data[0]
            if kind == 'word':
                addr += 4
            elif kind == 'dword':
                addr += 8
            elif kind == 'zero':
                addr += data[1]
            elif kind == 'align':
                addr += data[2]  # padding
            continue

        if line_type == 'insn':
            code, comment = data
            result = encode_instruction(code, comment, addr, labels)
            output.append(result)
            addr += 4
            continue

    return output


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def main():
    lines = sys.stdin.readlines()
    labels, parsed = pass1(lines)
    output = pass2(labels, parsed)
    for line in output:
        print(line)


if __name__ == '__main__':
    main()
