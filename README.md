<!--
SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>

SPDX-License-Identifier: Apache-2.0
-->

# Builder-hex0 RISC-V 64-bit

A minimal bootable kernel for bootstrapping compilers from source on RISC-V 64-bit.
Inspired by [builder-hex0](https://github.com/ironmeld/builder-hex0) by Rick Masters.

Builder-hex0 is a bootable disk image containing a kernel, shell, and hex0 compiler.
The x86 original fits in under 4KB of binary. This RISC-V port uses a two-stage
design and runs in QEMU's `virt` machine with OpenSBI providing firmware services.


## Two-Stage Architecture

Like the x86 original, the kernel boots in two stages:

* **Stage 1** (`builder-hex0-riscv64-stage1.S`, 508 bytes): Minimal hex0 compiler
  bootloader loaded at `0x80200000` by OpenSBI. Reads hex0 source from disk,
  compiles it to binary at `0x80210000`, and jumps there. Passes the next disk
  sector number to stage 2 via register `a0`.

* **Stage 2** (`builder-hex0-riscv64-stage2.S`, ~8KB): Full kernel with VirtIO
  driver, Sv39 paging, syscalls, process simulation, filesystem, and internal
  shell. Stored on disk as human-readable hex0 source, compiled at boot time
  by stage 1.

This design minimizes the binary seed to 508 bytes. The rest of the kernel is
readable hex0 source on disk, maximizing bootstrappability.


## Features

* Two-stage boot: 508-byte binary seed + ~25KB hex0 source
* ~8KB stage 2 kernel, written in RISC-V assembly
* Runs in S-mode under OpenSBI (analogous to x86 builder-hex0 running under BIOS)
* VirtIO-MMIO block device driver for disk I/O
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

This produces:
* `builder-hex0-riscv64-stage1.bin` — stage 1 bootloader (loaded by QEMU via `-kernel`)
* `builder-hex0-riscv64-stage2.hex0` — stage 2 kernel as hex0 source (placed on disk)

To produce commented hex0 from hex2 (for review/audit):
```
make builder-hex0-riscv64-stage1.hex0
```


## Testing

Boot with stage2.hex0 on disk to verify two-stage boot works:

```
make test
```


## Booting

```
qemu-system-riscv64 -machine virt -m 2G -nographic \
    -kernel builder-hex0-riscv64-stage1.bin \
    -drive file=disk.img,format=raw,if=none,id=hd0 \
    -device virtio-blk-device,drive=hd0 \
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


## Machine Requirements

* RISC-V 64-bit processor (RV64IM)
* 2GB of memory
* QEMU `virt` machine with OpenSBI
  * SBI legacy `putchar` (extension 0x01) for console output
  * SBI SRST (extension 0x53525354) for shutdown
  * VirtIO-MMIO block device for disk I/O


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
| Binary seed | 192 bytes | 508 bytes |
| Privilege | 32-bit protected mode | S-mode with Sv39 paging |
| Console | BIOS int 10h | SBI putchar |
| Disk | BIOS int 13h (LBA) | VirtIO-MMIO block device |
| Shutdown | Triple fault | SBI SRST |
| Stage 2 size | ~4KB | ~8KB |
| ELF format | 32-bit | 64-bit |
| Syscall ABI | int 0x80, x86 numbers | ecall, RISC-V Linux numbers |


## Limitations

* VirtIO disk driver is QEMU-specific (replaceable for real hardware)
* Only 8192 files can be created
* File names limited to 1024 bytes
* One child process at a time (fork simulation)
* Unimplemented syscalls return 0 (success)
