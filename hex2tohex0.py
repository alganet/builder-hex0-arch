#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: Apache-2.0
"""Convert RISC-V hex2 to commented hex0 using the linker binary for correct bytes.

The hex2 format for RISC-V uses OR'd fragments (.XXXXXXXX) and label references
($label, @label) that the hex2 linker resolves with architecture-specific instruction
encoding. This script reads the linker's binary output to get correct byte values,
and annotates them with comments from the hex2 source.

Usage: python3 hex2tohex0.py input.hex2 input.bin output.hex0
"""
import sys


def count_bytes(line):
    """Count bytes produced by a hex2 line for RISC-V 64-bit.

    In RISC-V hex2, all .XXXXXXXX fragments and label references on a single
    line are OR'd into a single 4-byte instruction word by the linker.
    Raw hex pairs (without . prefix) are counted individually.
    """
    code = line.split('#')[0].split(';')[0].strip()
    if not code or code.startswith(':'):
        return 0
    # Lines with . fragments or label references produce one 4-byte word
    if '.' in code or '$' in code or '@' in code:
        return 4
    # Raw hex pairs
    count = 0
    pos = 0
    while pos < len(code):
        if code[pos].isalnum():
            pos += 2
            count += 1
        else:
            pos += 1
    return count


def main():
    if len(sys.argv) != 4:
        prog = sys.argv[0] if sys.argv else "hex2tohex0.py"
        print(f"Usage: {prog} input.hex2 input.bin output.hex0", file=sys.stderr)
        sys.exit(1)
    hex2path = sys.argv[1]
    binpath = sys.argv[2]
    hex0path = sys.argv[3]

    with open(binpath, "rb") as f:
        binary = f.read()

    offset = 0
    with open(hex2path, "r") as h2f, open(hex0path, "w") as h0f:
        for line in h2f:
            stripped = line.rstrip('\n')
            nbytes = count_bytes(stripped)

            if nbytes == 0:
                # Comment, label definition, or empty line
                if stripped.startswith(':'):
                    h0f.write('#' + stripped + '\n')
                else:
                    h0f.write(stripped + '\n')
                continue

            # Extract comment from original line
            comment = ''
            for sep in ('#', ';'):
                idx = stripped.find(sep)
                if idx >= 0:
                    comment = stripped[idx:]
                    break

            # Get actual bytes from binary
            	
            if offset + nbytes > len(binary):
                remaining = len(binary) - offset
                print(
                    f"ERROR: hex2 requests {nbytes} bytes at offset {offset}, "
                    f"but binary has only {remaining} bytes remaining",
                    file=sys.stderr,
                )
                sys.exit(1)
            chunk = binary[offset:offset + nbytes]
            hex_bytes = ' '.join(f'{b:02x}' for b in chunk)

            if comment:
                h0f.write(f'{hex_bytes}  {comment}\n')
            else:
                h0f.write(f'{hex_bytes}\n')

            offset += nbytes

    if offset != len(binary):
        print(f"WARNING: hex2 accounted for {offset} bytes but binary is {len(binary)} bytes",
              file=sys.stderr)


if __name__ == '__main__':
    main()
