<!--
SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>

SPDX-License-Identifier: Apache-2.0
-->

# Development Notes

## Build Chain

```
kernel.S  --(rv64-asm2hex2.py)-->  kernel.hex2  --(hex2)-->  builder-hex0-riscv64.bin
```

1. **kernel.S** - RISC-V assembly source (~3500 lines)
2. **rv64-asm2hex2.py** - Converts assembly to hex2 format (labels, branches, jumps)
3. **hex2** - Vendored C linker from [stage0-posix](https://github.com/oriansj/stage0-posix). Resolves labels and produces a flat binary.

The hex2 linker is built from source in the `hex2/` directory. Run `make -C hex2` to build it, or `make` in the project root which builds everything.


## Source Files

| File | Purpose |
|------|---------|
| kernel.S | Kernel source in RISC-V assembly |
| rv64-asm2hex2.py | Assembly-to-hex2 converter (main build tool) |
| asm.py | RISC-V instruction encoder library (used by rv64-asm2hex2.py and standalone) |
| hex2/ | Vendored hex2 linker (C source, builds to hex2/hex2) |
| Makefile | Build automation |


## Python Tools

### rv64-asm2hex2.py

Converts RISC-V assembly to hex2 format. Reads from stdin, writes to stdout.

```
python3 rv64-asm2hex2.py < kernel.S > kernel.hex2
```

Features:
- Translates all RV64IM instructions + standard pseudo-instructions
- Converts label definitions (`label_name:`) to hex2 labels (`:label_name`)
- Converts branch targets to hex2 relative references (`@label`)
- Converts jump/call targets to hex2 absolute references (`$label`)
- Passes through raw hex2 lines unchanged (for inline data)
- Preserves comments

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

See the header comment in kernel.S for the complete memory map. Key regions:

- `0x80200000` - Kernel code (flat binary entry point)
- `0x80300000` - Global variables
- `0x80400000` - Process descriptors (16 slots)
- `0x80500000` - VirtIO structures
- `0x80600000` - User process memory (mapped at VA 0x00600000 via Sv39)
- `0xD4000000` - File data (bump allocator)


## Architecture

### Boot Sequence

1. OpenSBI loads kernel at `0x80200000` in S-mode
2. Kernel sets stack, trap vector (`stvec`), and initializes VirtIO
3. Sv39 paging enabled (3 gigapage entries for identity + user mapping)
4. Internal shell reads commands from disk via VirtIO
5. Programs run in U-mode, syscalls trap to S-mode via `ecall`

### VirtIO Block Device

The only QEMU-specific component (~300 lines). Scans MMIO region `0x10001000-0x10008000`
for a block device (device ID 2). Uses legacy VirtIO with a single virtqueue for
synchronous read/write operations.

### Process Simulation

Same model as x86 builder-hex0:
- `clone` (fork): snapshots process memory and stack to a save area
- `execve`: loads ELF, overlays child in same address space
- `exit`: restores parent from save area
- `waitid`: returns immediately (child already finished)

### Trap Handling

The trap handler is at offset 4 from the binary start (`0x80200004`).
On entry, it disables paging (`satp = 0`) and swaps `sp` with `sscratch`.
Syscall dispatch is via `scause == 8` (environment call from U-mode).
Non-ecall traps trigger shutdown.


## Build and Test Checklist

```
# After modifying kernel.S:

# 1. Rebuild
make clean && make

# 2. Quick boot test (empty disk, verify clean shutdown)
make test
```


## Debugging

Use QEMU's built-in GDB stub:

```
# Terminal 1: start QEMU paused
qemu-system-riscv64 -machine virt -m 2G -nographic \
    -kernel builder-hex0-riscv64.bin \
    -drive file=disk.img,format=raw,if=none,id=hd0 \
    -device virtio-blk-device,drive=hd0 \
    -s -S --no-reboot

# Terminal 2: attach GDB
gdb-multiarch -ex "target remote :1234" -ex "set arch riscv:rv64"
```

For instruction tracing: `qemu-system-riscv64 -d in_asm,cpu ...`
