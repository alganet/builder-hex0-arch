<!--
SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>

SPDX-License-Identifier: Apache-2.0
-->

# Builder-hex0 RISC-V 64-bit

A minimal bootable kernel for bootstrapping compilers from source on RISC-V 64-bit.
Inspired by [builder-hex0](https://github.com/ironmeld/builder-hex0) by Rick Masters.

Builder-hex0 is a bootable disk image containing a kernel, shell, and hex0 compiler.
The x86 original fits in under 4KB of binary. This RISC-V port uses a two-stage
design with board-specific stage 1 bootloaders and a portable stage 2 kernel.


## Two-Stage Architecture

The kernel uses a **board-specific stage 1** and a **portable stage 2**:

* **Stage 1** (board-specific, 512-756 bytes): Hex0 compiler bootloader. Finds
  the disk on the target platform, reads hex0 source, compiles it at
  `0x80210000`, and jumps there with `a0 = next disk sector`, `a1 = DTB pointer`.

* **Stage 2** (`builder-hex0-riscv64-stage2.S`, ~9KB): Portable kernel that
  works on any supported board. Parses the Flattened Device Tree (FDT) to
  discover storage devices at runtime. Supports VirtIO block and SPI+SD storage.
  Provides Sv39 paging, syscalls, process simulation, filesystem, and internal
  shell. Uses SBI for console and reboot.

The **same stage 2 hex0 source works on every board** — only stage 1 changes
per platform. Checksums remain stable across boards.


## Supported Boards

| Board | Stage 1 | Storage | QEMU machine |
|-------|---------|---------|--------------|
| QEMU virt | `stage1-virt.S` (512 bytes) | VirtIO block | `-machine virt` |
| SiFive HiFive Unleashed | `stage1-sifive_u.S` (756 bytes) | SD card over SPI | `-machine sifive_u` |


## Features

* Two-stage boot: board-specific binary seed + ~25KB shared hex0 source
* ~9KB portable stage 2 kernel, written in RISC-V assembly
* Runs in S-mode under OpenSBI
* DTB-driven storage discovery (VirtIO block or SPI+SD)
* Disk I/O abstraction via function pointers (`disk_read_fn` / `disk_write_fn`)
* Sv39 virtual memory with gigapage mappings
* 15 Linux-compatible system calls (RISC-V ABI)
* In-memory filesystem, process simulation (fork/exec/exit/waitid)
* Internal shell with `src`, `hex0`, and `f` commands
* Can execute 64-bit RISC-V ELF programs
* Builds the complete [stage0-posix](https://github.com/oriansj/stage0-posix) RISC-V toolchain


## Building

Requires Python 3 and a C compiler (for the hex2 linker):

```
make
```

This produces binaries for all supported boards:
* `builder-hex0-riscv64-stage1-virt.bin` — virt stage 1
* `builder-hex0-riscv64-stage1-sifive_u.bin` — sifive_u stage 1
* `builder-hex0-riscv64-stage2.hex0` — portable stage 2 (shared)


## Testing

```
make test
```

Runs boot tests for all supported boards. The sifive_u test requires
QEMU >= 10.1 (SPI-mode SD card fixes).


## Booting

### QEMU virt (VirtIO)

```
qemu-system-riscv64 -machine virt -m 2G -nographic \
    -kernel builder-hex0-riscv64-stage1-virt.bin \
    -drive file=disk.img,format=raw,if=none,id=hd0 \
    -device virtio-blk-device,drive=hd0 \
    --no-reboot
```

### SiFive HiFive Unleashed (SD card)

```
qemu-system-riscv64 -machine sifive_u -m 2G -nographic \
    -kernel builder-hex0-riscv64-stage1-sifive_u.bin \
    -drive file=disk.img,format=raw,if=sd \
    --no-reboot
```

OpenSBI is loaded automatically by QEMU and provides firmware services.
Stage 1 is loaded at `0x80200000` in S-mode. It compiles stage 2 from
hex0 source on disk to `0x80210000` and jumps there.

### Disk Layout

```
Sector 0..N:   stage 2 kernel hex0 source (null-terminated)
Sector N+1..:  filesystem data (src/putdir/putfile entries)
```


## Hardware Abstraction

Stage 2 is portable across RISC-V boards. It relies on:

* **SBI** for console (legacy putchar, ext 0x01) and reboot (SRST, ext
  0x53525354 with type=COLD_REBOOT). SBI is the standard RISC-V hardware
  abstraction layer — any board with OpenSBI or equivalent firmware provides it.
  Reboot (not shutdown) is used because all boards have a reboot device and it
  matches the bootstrap lifecycle (boot → build → rewrite disk → reboot).
* **FDT (Flattened Device Tree)** for storage device discovery. Stage 2 parses
  the DTB passed in `a1` to find either VirtIO MMIO block devices or SiFive SPI
  controllers with SD card slots.
* **Disk I/O function pointers** (`disk_read_fn` / `disk_write_fn`) in global
  data. The active storage driver sets these during init. Both VirtIO and SPI+SD
  drivers implement the same `(a0=sector, a1=buffer)` interface.
* **RAM at `0x80000000`** — the near-universal RISC-V convention.

To port to a new board, create a stage 1 that finds the disk, loads and
compiles stage 2, then jumps to it with `a0 = filesystem start sector` and
`a1 = DTB pointer`. If the board uses a new storage type, add a driver to
stage 2 with the `(a0=sector, a1=buffer)` interface.


## Machine Requirements

* RISC-V 64-bit processor (RV64IM)
* 2GB of memory
* SBI firmware (OpenSBI or equivalent)
* FDT/DTB describing the hardware
* VirtIO-MMIO block device or SD card over SPI (discovered via DTB)


## System Calls

Implements the RISC-V Linux syscall ABI (`ecall` with syscall number in `a7`):

| Syscall   | Number | Notes                          |
|-----------|--------|--------------------------------|
| getcwd    | 17     |                                |
| mkdirat   | 34     | dirfd ignored                  |
| faccessat | 48     | dirfd ignored, always succeeds |
| chdir     | 49     |                                |
| openat    | 56     | dirfd ignored                  |
| close     | 57     |                                |
| lseek     | 62     |                                |
| read      | 63     |                                |
| write     | 64     |                                |
| exit      | 93     |                                |
| waitid    | 95     |                                |
| brk       | 214    |                                |
| clone     | 220    | simulated fork                 |
| execve    | 221    | loads 64-bit ELF               |


## The Builder Shell

The internal shell reads commands from standard input, which the kernel provides
by reading the disk image starting after the hex0 source (at the sector passed
by stage 1 in `a0`).

Built-in commands:
* `src N filename` - read N bytes from stdin into a file
* `hex0 input output` - compile hex0 source to binary
* `f` - flush `/dev/hda` to disk before the next command


## Differences from x86 builder-hex0

| Aspect | x86 | RISC-V |
|--------|-----|--------|
| Boot | MBR/BIOS (stage1+stage2) | QEMU `-kernel` stage1 + hex0 stage2 on disk |
| Binary seed | 192 bytes | 512-756 bytes (board-dependent) |
| Privilege | 32-bit protected mode | S-mode with Sv39 paging |
| Console | BIOS int 10h | SBI putchar |
| Disk | BIOS int 13h (LBA) | VirtIO or SPI+SD (DTB-discovered) |
| Reboot | Triple fault | SBI SRST cold reboot |
| Stage 2 size | ~4KB | ~9KB |
| ELF format | 32-bit | 64-bit |
| Syscall ABI | int 0x80, x86 numbers | ecall, RISC-V Linux numbers |


## Limitations

* Stage 1 is board-specific (currently QEMU virt and sifive_u)
* Stage 2 supports VirtIO block and SPI+SD storage (DTB-discovered)
* sifive_u test requires QEMU >= 10.1 (SPI-mode SD card fixes)
* Only 8192 files can be created
* File names limited to 1024 bytes
* One child process at a time (fork simulation)
* Unimplemented syscalls return 0 (success)
