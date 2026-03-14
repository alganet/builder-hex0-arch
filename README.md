<!--
SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>

SPDX-License-Identifier: Apache-2.0
-->

# Builder-hex0 RISC-V 64-bit

A minimal bootable kernel for bootstrapping compilers from source on RISC-V 64-bit.
Inspired by [builder-hex0](https://github.com/ironmeld/builder-hex0) by Rick Masters.

Builder-hex0 is a bootable disk image containing a kernel, shell, and hex0 compiler.
The x86 original fits in under 4KB of binary. This RISC-V port is ~8KB and runs
in QEMU's `virt` machine with OpenSBI providing firmware services.


## Features

* ~8KB flat binary kernel, written in RISC-V assembly (kernel.S)
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

This runs the build chain: `kernel.S` -> `kernel.hex2` -> `builder-hex0-riscv64.bin`


## Testing

Boot with an empty disk image to verify the kernel starts and shuts down:

```
make test
```


## Booting

```
qemu-system-riscv64 -machine virt -m 2G -nographic \
    -kernel builder-hex0-riscv64.bin \
    -drive file=disk.img,format=raw,if=none,id=hd0 \
    -device virtio-blk-device,drive=hd0 \
    --no-reboot
```

OpenSBI is loaded automatically by QEMU and provides firmware services.
The kernel is loaded at `0x80200000` in S-mode.


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
by reading the disk image starting after any binary header.

Built-in commands:
* `src N filename` - read N bytes from stdin into a file
* `hex0 input output` - compile hex0 source to binary
* `f` - flush `/dev/hda` to disk before the next command


## Differences from x86 builder-hex0

| Aspect | x86 | RISC-V |
|--------|-----|--------|
| Boot | MBR/BIOS (stage1+stage2) | QEMU `-kernel` with OpenSBI |
| Privilege | 32-bit protected mode | S-mode with Sv39 paging |
| Console | BIOS int 10h | SBI putchar |
| Disk | BIOS int 13h (LBA) | VirtIO-MMIO block device |
| Shutdown | Triple fault | SBI SRST |
| Binary size | ~4KB | ~8KB |
| ELF format | 32-bit | 64-bit |
| Syscall ABI | int 0x80, x86 numbers | ecall, RISC-V Linux numbers |


## Limitations

* VirtIO disk driver is QEMU-specific (replaceable for real hardware)
* Only 8192 files can be created
* File names limited to 1024 bytes
* One child process at a time (fork simulation)
* Unimplemented syscalls return 0 (success)
