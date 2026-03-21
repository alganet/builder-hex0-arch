<!--
SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>

SPDX-License-Identifier: Apache-2.0
-->

# Development Notes

## Build Chain

### x86 (vendored)

No build step — hex0 source files are included directly:
* `builder-hex0-x86-stage1-bios.hex0` — stage 1 (MBR boot + hex0 compiler)
* `builder-hex0-x86-stage2.hex0` — stage 2 (full builder with shell)
* `builder-hex0-x86-mini.hex0` — minimal hex0-only compiler (512 bytes)

### RISC-V 64-bit

```
builder-hex0-riscv64-stage1-{board}.S  --(rv64-asm2hex2.py)-->  .hex2  --(hex2)-->  .bin
builder-hex0-riscv64-stage2.S          --(rv64-asm2hex2.py)-->  .hex2  --(hex2)-->  .bin  --(hex2tohex0.py)-->  .hex0
```

### AArch64

```
builder-hex0-aarch64-stage1-{board}.S  --(a64-asm2hex2.py)-->  .hex2  --(hex2)-->  .bin
builder-hex0-aarch64-stage2.S          --(a64-asm2hex2.py)-->  .hex2  --(hex2)-->  .bin  --(hex2tohex0.py)-->  .hex0
```

The AArch64 converter resolves branch targets in a two-pass approach (the hex2
linker's `@`/`$` label reference types have RISC-V-specific encoding in
hex2_word.c, so AArch64 pre-resolves all offsets in Python).


## Source Files

| File                                   | Purpose                                         |
|----------------------------------------|-------------------------------------------------|
| builder-hex0-x86-stage1-bios.hex0      | x86 BIOS stage 1 (vendored, Rick Masters)       |
| builder-hex0-x86-stage2.hex0           | x86 full builder (vendored, Rick Masters)       |
| builder-hex0-x86-mini.hex0             | x86 mini hex0 compiler (vendored, Rick Masters) |
| builder-hex0-riscv64-stage1-virt.S     | RISC-V QEMU virt stage 1 (VirtIO)               |
| builder-hex0-riscv64-stage1-sifive_u.S | RISC-V SiFive sifive_u stage 1 (SPI+SD)         |
| builder-hex0-riscv64-stage2.S          | RISC-V portable stage 2 kernel                  |
| rv64-asm2hex2.py                       | RISC-V assembly-to-hex2 converter               |
| asm.py                                 | RISC-V instruction encoder library              |
| builder-hex0-aarch64-stage1-virt.S     | AArch64 QEMU virt stage 1 (VirtIO)              |
| builder-hex0-aarch64-stage1-raspi3b.S  | AArch64 RPi 3B stage 1 (SDHCI, core parking)    |
| builder-hex0-aarch64-stage2.S          | AArch64 portable stage 2 kernel                 |
| a64-asm2hex2.py                        | AArch64 assembly-to-hex2 converter (two-pass)   |
| a64_asm.py                             | AArch64 instruction encoder library             |
| hex2tohex0.py                          | hex2-to-hex0 converter with comments (shared)   |
| hex0-to-src.sh                         | Generate shell script for hex0 self-compilation |
| build-self.sh                          | Boot kernel and hex0-compile a source file      |
| hex2/                                  | Vendored hex2 linker (C source, shared)         |
| Makefile                               | Multi-architecture build with per-board targets |


## Two-Stage Boot

### Stage 1: Board-Specific

Each board has its own stage 1. Stage 1 is architecture- and board-specific.

|                 | RISC-V                    | AArch64 (virt)         | AArch64 (raspi3b)                            |
|-----------------|---------------------------|------------------------|----------------------------------------------|
| Load address    | `0x80200000` (by OpenSBI) | `0x40080000` (by QEMU) | `0x00080000` (by QEMU)                       |
| Entry state     | `a0`=hartid, `a1`=dtb     | `x0`=dtb               | EL2, all 4 cores                             |
| Stage 2 address | `0x80210000`              | `0x40210000`           | `0x00210000`                                 |
| Exit convention | `a0`=sector, `a1`=DTB     | `x0`=sector, `x1`=DTB  | `x0`=sector, `x1`=0, `x2`=SDHCI base, `x3`=3 |

Responsibilities:
1. Find and initialize the storage device (board-specific)
2. Read hex0 source from disk sector 0 onward
3. Compile hex0 to binary at the stage 2 address
4. Jump there with filesystem start sector and DTB pointer

**RISC-V virt** stage 1: scans VirtIO MMIO range `0x10001000-0x10008000`
for block device. Legacy VirtIO v1. 512 bytes.

**RISC-V sifive_u** stage 1: initializes SiFive SPI controller at
`0x10050000`, performs SD card init, reads via CMD17. Parks non-boot harts.
756 bytes.

**AArch64 virt** stage 1: scans VirtIO MMIO range `0x0A000000-0x0A004000`
(32 slots, step 0x200) for block device. Legacy VirtIO v1. 500 bytes.

**AArch64 raspi3b** stage 1: parks non-boot cores (MPIDR check + WFE),
drops from EL2 to EL1, initializes ARASAN SDHCI at `0x3F300000`
(CMD0/CMD8/ACMD41/CMD2/CMD3/CMD7/CMD16), reads hex0 source via CMD17
PIO (128 unrolled word reads per sector to work around QEMU TCG caching),
compiles to binary, re-inits SDHCI before jumping to stage 2. 1916 bytes.

### Stage 2: Portable (per-architecture)

Portable kernel stored on disk as hex0 source. Compiled by stage 1 at boot.

Discovers storage via FDT parsing — no hardcoded MMIO addresses. All disk I/O
goes through function pointers (`disk_read_fn` / `disk_write_fn`), set by
whichever storage driver the DTB selects.


## Architecture Details

### RISC-V

* Runs in S-mode under OpenSBI
* Sv39 paging with 3 gigapage entries
* Console via SBI putchar, reboot via SBI SRST
* Syscalls via `ecall` with number in `a7`
* RAM at `0x80000000`

### AArch64

* Runs at EL1 (no firmware layer)
* Syscalls via `SVC #0` with number in `x8`
* MMU stays on during kernel execution
* Exception vector table at VBAR_EL1 (2KB-aligned, 16 entries × 128 bytes)
* Console via PL011 UART (board-specific VA)

**Virt:**
* L1 1GB block descriptors (4 entries: user, kernel, upper, MMIO)
* PL011 UART at VA `0xC9000000` (PA `0x09000000`, MMIO entry)
* VirtIO storage discovered via DTB
* RAM at `0x40000000` (2GB)
* Reboot via PSCI `SYSTEM_RESET` (`HVC #0`, x0=`0x84000009`)

**Raspi3b:**
* Board detection via trampoline: `adr` address < `0x40000000` = raspi3b
* L1 + L2 page tables: Entry 0/1 use L2 (504 normal + 8 device entries),
  Entry 2 is a 1GB block (file data region)
* PL011 UART at VA `0x7F201000` (PA `0x3F201000`, Entry 1 device region)
* SDHCI ARASAN at VA `0x7F300000` (PA `0x3F300000`)
* 1GB RAM (PA `0x00-0x3F`), all L1 entries alias to same physical memory
* CMD18 preload: 16128 sectors (8MB) read into VA `0x42000000` (PA `0x02000000`)
  at boot for fast stdin access; falls back to per-sector CMD17 when exhausted
* Multi-core: stage 1 parks cores 1-3 via MPIDR check + WFE
* Reboot via BCM2835 PM watchdog (PM_RSTS + PM_WDOG + PM_RSTC at PA `0x3F100000`)


### FDT Storage Discovery

`fdt_find_storage(dtb_ptr)` returns MMIO base and type:
- Type 1 (VirtIO): node name starts with `"virt"`, probed for magic + block ID
- Type 2 (SPI+SD): node name `"spi@..."` with `"mmc@..."` child (RISC-V only)
- Type 3 (SDHCI): stage 1 passes SDHCI base directly via `x2`, no DTB discovery
  (AArch64 raspi3b — the ARASAN SDHCI is not in the DTB)


### Reboot (not Shutdown)

Both architectures use reboot (not shutdown). Reboot is more portable and
matches the bootstrap lifecycle: boot → build → rewrite disk → reboot into
next stage. Tests use `--no-reboot` so QEMU exits cleanly.

The reboot method is board-conditional: RISC-V uses SBI SRST, AArch64 virt
uses PSCI HVC, AArch64 raspi3b uses the BCM2835 power management watchdog
(writing PM_RSTS, PM_WDOG, PM_RSTC with the PM password `0x5A`).


## Self-Build Reproducibility

Each architecture can prove its hex0 compiler produces identical output to the
host toolchain. The `make self-test` targets automate this.

### x86

The x86 chain follows the original builder-hex0 pattern:

1. Host compiles `builder-hex0-x86-mini.hex0` to binary using `xxd` (seed)
2. Mini seed boots in QEMU, compiles `stage1-bios.hex0` → writes to disk
3. Host also compiles `stage1-bios.hex0` using `xxd`
4. Diff the two binaries — proves mini's hex0 compiler matches host

The x86 also has a "full builds full" chain (the full builder can compile its
own hex0 source via the `hex0` shell command), matching the original
builder-hex0 Makefile.

### RISC-V and AArch64

These architectures don't have a "mini" variant. Stage 1 IS the hex0 compiler,
but it can't self-build in isolation because:
- It needs QEMU `-kernel` to load (not MBR boot)
- The compiled output goes to a fixed RAM address, not back to disk
- Stage 1 has no "write to disk" capability

Instead, self-builds go through the full stage 2 kernel:

1. Host compiles stage 1 and stage 2 from hex0 source (seed binaries)
2. Stage 1 seed boots → compiles stage 2 hex0 → stage 2 kernel runs
3. Internal shell loads a hex0 file via `src`, compiles it via `hex0`, flushes
   to disk via `f`
4. Extract the result from the disk image and diff against the seed binary

This is one extra layer compared to x86 mini, but achieves the same proof:
the hex0 compiler (embedded in the kernel) reproduces the binary from source.

Both stage 1 and stage 2 are tested:
- `make self-test-{arch}-{board}` runs both stage1 and stage2 self-builds


## Porting

### New board (same architecture)

1. Create `builder-hex0-{arch}-stage1-{board}.S` with storage init + hex0 compiler
2. Add build targets to `Makefile`
3. If using a new storage type, add a driver to stage 2 implementing
   `xx_read_sector(a0=sector, a1=buffer)` and `xx_write_sector`
4. Add detection logic in `fdt_find_storage` for the new DTB node pattern
5. Add a test target (`test-{arch}-{board}`) and self-test target (`self-test-{arch}-{board}`)

### New architecture

1. Create `{arch}_asm.py` instruction encoder
2. Create `{arch}-asm2hex2.py` assembly-to-hex2 converter
3. Create stage 1 and stage 2 assembly sources
4. Add architecture block to `Makefile`
5. Update `run.sh`, `scripts/k0.kaem`, `scripts/env.{arch}.kaem` in parent abuild


## Build and Test

```
make clean && make                     # all architectures
make x86                              # x86 (vendored, no build step)
make riscv64                           # riscv64 only
make aarch64                           # aarch64 only

make test                              # boot tests, all arch+board combos
make test-x86-bios                     # one board
make test-aarch64-raspi3b              # one board

make self-test                         # self-build reproducibility, all
make self-test-aarch64-virt            # one board
```

The RISC-V sifive_u test requires QEMU >= 10.1.


## Debugging

### RISC-V

```
# Terminal 1: start QEMU paused
qemu-system-riscv64 -machine virt -m 2G -nographic \
    -kernel builder-hex0-riscv64-stage1-virt.bin \
    -drive file=disk.img,format=raw,if=none,id=hd0 \
    -device virtio-blk-device,drive=hd0 \
    -s -S --no-reboot

# Terminal 2: attach GDB
gdb-multiarch -ex "target remote :1234" -ex "set arch riscv:rv64"
```

### AArch64

```
# Terminal 1: start QEMU paused
qemu-system-aarch64 -machine virt -cpu cortex-a53 -m 2G -nographic \
    -kernel builder-hex0-aarch64-stage1-virt.bin \
    -drive file=disk.img,format=raw,if=none,id=hd0 \
    -device virtio-blk-device,drive=hd0 \
    -s -S --no-reboot

# Terminal 2: attach GDB
gdb-multiarch -ex "target remote :1234" -ex "set arch aarch64"
```

### AArch64 — Raspberry Pi 3B

```
# Terminal 1: start QEMU paused
qemu-system-aarch64 -machine raspi3b -serial mon:stdio -nographic \
    -kernel builder-hex0-aarch64-stage1-raspi3b.bin \
    -drive file=disk.img,if=sd,format=raw \
    -s -S --no-reboot

# Terminal 2: attach GDB
gdb-multiarch -ex "target remote :1234" -ex "set arch aarch64"
```

### General

For instruction tracing: `qemu-system-{arch} -d in_asm,cpu ...`

For VirtIO debugging: `-trace "virtio_blk*" -trace "virtio_mmio*"`

For SD card debugging (RISC-V): `-trace "sdcard_*" -d guest_errors`

For SDHCI debugging (AArch64 raspi3b): `-trace "sdhci_*" -d guest_errors`
