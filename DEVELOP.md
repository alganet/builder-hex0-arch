<!--
SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>

SPDX-License-Identifier: Apache-2.0
-->

# Development Notes

## Build Chain

```
builder-hex0-riscv64-stage1.S  --(rv64-asm2hex2.py)-->  .hex2  --(hex2)-->  .bin  (508 bytes)
builder-hex0-riscv64-stage2.S  --(rv64-asm2hex2.py)-->  .hex2  --(hex2)-->  .bin  +  .hex2  --(hex2tohex0.py)-->  .hex0
 ```

1. **builder-hex0-riscv64-stage1.S** - Minimal hex0 compiler bootloader (~130 lines)
2. **builder-hex0-riscv64-stage2.S** - Full kernel source in RISC-V assembly (~3500 lines)
3. **rv64-asm2hex2.py** - Converts assembly to hex2 format (labels, branches, jumps)
4. **hex2** - Vendored C linker from [stage0-posix](https://github.com/oriansj/stage0-posix). Resolves labels and produces flat binaries.
5.  5. **hex2tohex0.py** - Consumes the stage2 `.hex2` (plus the linked `.bin`) to produce commented hex0 source (replaces the older `xxd` + `sed` pipeline, imported from x86 builder-hex0 for review/audit).
6. **hex2tohex0.py** - Converts hex2 to commented hex0 (imported from x86 builder-hex0, for review/audit)

The hex2 linker is built from source in the `hex2/` directory. Run `make -C hex2` to build it, or `make` in the project root which builds everything.


## Source Files

| File | Purpose |
|------|---------|
| builder-hex0-riscv64-stage1.S | Stage 1 hex0 bootloader (508 bytes binary) |
| builder-hex0-riscv64-stage2.S | Stage 2 kernel source in RISC-V assembly |
| rv64-asm2hex2.py | Assembly-to-hex2 converter (main build tool) |
| asm.py | RISC-V instruction encoder library (used by rv64-asm2hex2.py and standalone) |
| hex2tohex0.py | hex2-to-hex0 converter with comments (from x86 builder-hex0) |
| hex2/ | Vendored hex2 linker (C source, builds to hex2/hex2) |
| Makefile | Build automation |


## Two-Stage Boot

### Stage 1 (builder-hex0-riscv64-stage1.S → .bin, 508 bytes)

Loaded at `0x80200000` by OpenSBI via QEMU `-kernel`. Responsibilities:

1. Initialize VirtIO block device (legacy v1, scan MMIO for device ID 2)
2. Read hex0 source from disk sector 0 onward
3. Compile hex0 to binary at `0x80210000`
4. Jump to `0x80210000` with `a0` = next disk sector (filesystem start)

Register allocation:
- `s0` = hex state (0=first nibble, 1=have first)
- `s1` = current disk sector
- `s2` = offset in sector buffer (0-511, init 512 to force first read)
- `s3` = VirtIO MMIO base
- `s4` = VirtIO struct base (`0x80500000`)
- `s5` = output write pointer
- `s6` = high nibble accumulator
- `s7` = sector buffer (`s4+0x3000`)
- `s9` = saved `ra` in `next_byte`

Terminates on null byte (0x00) in the raw disk data.

### Stage 2 (builder-hex0-riscv64-stage2.S → .hex0, ~25KB hex0)

Full kernel stored on disk as hex0 source. Compiled by stage 1 at boot to
`0x80210000`. Receives filesystem start sector in `a0`.


## Python Tools

### rv64-asm2hex2.py

Converts RISC-V assembly to hex2 format. Reads from stdin, writes to stdout.

```
python3 rv64-asm2hex2.py < builder-hex0-riscv64-stage2.S > builder-hex0-riscv64-stage2.hex2
```

Features:
- Translates all RV64IM instructions + standard pseudo-instructions
- Converts label definitions (`label_name:`) to hex2 labels (`:label_name`)
- Converts branch targets to hex2 relative references (`@label`)
- Converts jump/call targets to hex2 absolute references (`$label`)
- Passes through raw hex2 lines unchanged (for inline data)
- Preserves comments

### hex2tohex0.py

Converts hex2 to commented hex0 by resolving all label references to concrete
addresses. Imported from the x86 builder-hex0 project.

```
python3 hex2tohex0.py builder-hex0-riscv64-stage1.hex2 builder-hex0-riscv64-stage1.bin builder-hex0-riscv64-stage1.hex0
python3 hex2tohex0.py builder-hex0-riscv64-stage2.hex2 builder-hex0-riscv64-stage2.bin builder-hex0-riscv64-stage2.hex0
```

Or via make:
```
make builder-hex0-riscv64-stage1.hex0
```

### asm.py

Low-level RISC-V instruction encoder. Can be used standalone for quick encoding checks:

```
# Encode a single instruction
python3 asm.py lui a0 0x80200

# Batch mode from stdin
echo "addi a0, a0, 1" | python3 asm.py

# Generate multi-instruction address loads
python3 asm.py load_addr t0 0x80300000
```

Also importable as a library (`from asm import emit, load_addr`).


## Memory Layout

See the header comment in builder-hex0-riscv64-stage2.S for the complete memory map. Key regions:

- `0x80200000` - Stage 1 code (loaded by OpenSBI)
- `0x80210000` - Stage 2 code (compiled by stage 1)
- `0x80300000` - Global variables
- `0x80400000` - Process descriptors (16 slots)
- `0x80500000` - VirtIO structures (shared between stages)
- `0x80600000` - User process memory (mapped at VA 0x00600000 via Sv39)
- `0xD4000000` - File data (bump allocator)


## Architecture

### Boot Sequence

1. OpenSBI loads stage 1 at `0x80200000` in S-mode
2. Stage 1 initializes VirtIO, reads hex0 from disk, compiles to `0x80210000`
3. Stage 1 jumps to stage 2 with `a0` = filesystem start sector
4. Stage 2 sets stack, trap vector (`stvec`), reinitializes VirtIO
5. Sv39 paging enabled (3 gigapage entries for identity + user mapping)
6. Internal shell reads commands from disk via VirtIO (starting at sector `a0`)
7. Programs run in U-mode, syscalls trap to S-mode via `ecall`

### VirtIO Block Device

The only QEMU-specific component (~300 lines in stage 2, ~40 lines in stage 1).
Scans MMIO region `0x10001000-0x10008000` for a block device (device ID 2).
Uses legacy VirtIO with a single virtqueue for synchronous read/write operations.

Stage 1 uses VirtIO v1 (legacy) only. Stage 2 supports both v1 and v2.

### Process Simulation

Same model as x86 builder-hex0:
- `clone` (fork): snapshots process memory and stack to a save area
- `execve`: loads ELF, overlays child in same address space
- `exit`: restores parent from save area
- `waitid`: returns immediately (child already finished)

### Trap Handling

The trap handler is at offset 4 from the stage 2 binary start (`0x80210004`).
On entry, it disables paging (`satp = 0`) and swaps `sp` with `sscratch`.
Syscall dispatch is via `scause == 8` (environment call from U-mode).
Non-ecall traps trigger shutdown.


## Build and Test Checklist

```
# After modifying stage1 or stage2:

# 1. Rebuild
make clean && make

# 2. Two-stage boot test (stage2.hex0 on disk, verify clean shutdown)
make test
```


## Debugging

Use QEMU's built-in GDB stub:

```
# Terminal 1: start QEMU paused
qemu-system-riscv64 -machine virt -m 2G -nographic \
    -kernel builder-hex0-riscv64-stage1.bin \
    -drive file=disk.img,format=raw,if=none,id=hd0 \
    -device virtio-blk-device,drive=hd0 \
    -s -S --no-reboot

# Terminal 2: attach GDB
gdb-multiarch -ex "target remote :1234" -ex "set arch riscv:rv64"
```

For instruction tracing: `qemu-system-riscv64 -d in_asm,cpu ...`
