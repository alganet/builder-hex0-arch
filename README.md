<!--
SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>

SPDX-License-Identifier: Apache-2.0
-->

# Builder-hex0-more

Minimal bootable kernels for bootstrapping compilers from source on RISC-V 64-bit
and AArch64. Inspired by [builder-hex0](https://github.com/ironmeld/builder-hex0)
by Rick Masters.

Builder-hex0 is a bootable disk image containing a kernel, shell, and hex0 compiler.
The x86 original fits in under 4KB of binary. These ports use a two-stage design
with board-specific stage 1 bootloaders and portable stage 2 kernels.


## Two-Stage Architecture

Each architecture uses a **board-specific stage 1** and a **portable stage 2**:

* **Stage 1** (board-specific): Hex0 compiler bootloader. Finds the disk on the
  target platform, reads hex0 source, compiles it to binary, and jumps there
  with the filesystem start sector and storage info (DTB pointer or MMIO base).

* **Stage 2** (per-architecture, ~9-15KB): Portable kernel that works on any
  supported board for a given architecture. Discovers storage devices via DTB
  or stage 1 handoff. Provides paging, syscalls, process simulation,
  filesystem, and internal shell.

The **same stage 2 hex0 source works on every board** within an architecture —
only stage 1 changes per platform.


## Supported Architectures and Boards

### RISC-V 64-bit

| Board | Stage 1 | Storage | QEMU machine |
|-------|---------|---------|--------------|
| QEMU virt | `stage1-virt.S` (512 bytes) | VirtIO block | `-machine virt` |
| SiFive HiFive Unleashed | `stage1-sifive_u.S` (756 bytes) | SD card over SPI | `-machine sifive_u` |

### AArch64

| Board | Stage 1 | Storage | QEMU machine |
|-------|---------|---------|--------------|
| QEMU virt | `stage1-virt.S` (500 bytes) | VirtIO block | `-machine virt -cpu cortex-a53` |
| Raspberry Pi 3B | `stage1-raspi3b.S` (1916 bytes) | SDHCI (ARASAN) | `-machine raspi3b` |


## Features

Common to both architectures:

* Two-stage boot: board-specific binary seed + shared hex0 source
* Storage discovery via DTB (VirtIO, SPI+SD) or stage 1 handoff (SDHCI)
* Disk I/O abstraction via function pointers
* Virtual memory with gigapage/block mappings
* 14 Linux-compatible system calls (shared numbering)
* In-memory filesystem, process simulation (fork/exec/exit/waitid)
* Internal shell with `src`, `hex0`, and `f` commands
* Executes 64-bit ELF programs

| | RISC-V 64-bit | AArch64 |
|---|---|---|
| Stage 2 size | ~9KB (4058 lines) | ~15KB (4232 lines) |
| Privilege mode | S-mode under OpenSBI | EL1 (direct) |
| Paging | Sv39 gigapages | L1 block descriptors (virt), L1+L2 (raspi3b) |
| Console | SBI putchar | PL011 UART |
| Reboot | SBI SRST cold reboot | PSCI HVC (virt) / BCM2835 PM watchdog (raspi3b) |
| Syscall ABI | ecall, a7 | SVC #0, x8 |
| RAM base | 0x80000000 | 0x40000000 (virt) / 0x00000000 (raspi3b, 1GB) |


## Building

Requires Python 3 and a C compiler (for the hex2 linker):

```
make                     # build all architectures
make riscv64             # build riscv64 only
make aarch64             # build aarch64 only
```

### RISC-V outputs

* `builder-hex0-riscv64-stage1-virt.bin` — virt stage 1
* `builder-hex0-riscv64-stage1-sifive_u.bin` — sifive_u stage 1
* `builder-hex0-riscv64-stage2.hex0` — portable stage 2

### AArch64 outputs

* `builder-hex0-aarch64-stage1-virt.bin` — virt stage 1
* `builder-hex0-aarch64-stage1-raspi3b.bin` — Raspberry Pi 3B stage 1
* `builder-hex0-aarch64-stage2.hex0` — portable stage 2


## Testing

```
make test                    # test all architectures
make test-riscv64            # test riscv64 only
make test-aarch64            # test aarch64 only
```

The RISC-V sifive_u test requires QEMU >= 10.1 (SPI-mode SD card fixes).


## Booting

### RISC-V — QEMU virt (VirtIO)

```
qemu-system-riscv64 -machine virt -m 2G -nographic \
    -kernel builder-hex0-riscv64-stage1-virt.bin \
    -drive file=disk.img,format=raw,if=none,id=hd0 \
    -device virtio-blk-device,drive=hd0 --no-reboot
```

### RISC-V — SiFive HiFive Unleashed (SD card)

```
qemu-system-riscv64 -machine sifive_u -m 2G -nographic \
    -kernel builder-hex0-riscv64-stage1-sifive_u.bin \
    -drive file=disk.img,format=raw,if=sd --no-reboot
```

### AArch64 — QEMU virt (VirtIO)

```
qemu-system-aarch64 -machine virt -cpu cortex-a53 -m 2G -nographic \
    -kernel builder-hex0-aarch64-stage1-virt.bin \
    -drive file=disk.img,format=raw,if=none,id=hd0 \
    -device virtio-blk-device,drive=hd0 --no-reboot
```

### AArch64 — Raspberry Pi 3B (SDHCI)

```
qemu-system-aarch64 -machine raspi3b -serial mon:stdio -nographic \
    -kernel builder-hex0-aarch64-stage1-raspi3b.bin \
    -drive file=disk.img,if=sd,format=raw --no-reboot
```

### Disk Layout

```
Sector 0..N:   stage 2 kernel hex0 source (null-terminated)
Sector N+1..:  filesystem data (src/putdir/putfile entries)
```


## System Calls

Both architectures implement the same Linux generic syscall numbers:

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
by stage 1).

Built-in commands:
* `src N filename` - read N bytes from stdin into a file
* `hex0 input output` - compile hex0 source to binary
* `f` - flush `/dev/hda` to disk before the next command


## Differences from x86 builder-hex0

| Aspect | x86 | RISC-V | AArch64 |
|--------|-----|--------|---------|
| Boot | MBR/BIOS | QEMU `-kernel` + hex0 on disk | QEMU `-kernel` + hex0 on disk |
| Binary seed | 192 bytes | 512-756 bytes | 500-1916 bytes |
| Privilege | 32-bit protected mode | S-mode (Sv39) | EL1 (AArch64 paging) |
| Console | BIOS int 10h | SBI putchar | PL011 UART |
| Disk | BIOS int 13h | VirtIO or SPI+SD (DTB) | VirtIO or SDHCI |
| Reboot | Triple fault | SBI SRST | PSCI HVC / BCM2835 PM |
| Stage 2 size | ~4KB | ~9KB | ~15KB |
| Syscall ABI | int 0x80 | ecall (a7) | SVC #0 (x8) |


## Limitations

* Stage 1 is board-specific (RISC-V: virt + sifive_u; AArch64: virt + raspi3b)
* RISC-V sifive_u test requires QEMU >= 10.1
* Only 16384 files can be created
* File names limited to 1024 bytes
* One child process at a time (fork simulation)
* Unimplemented syscalls return 0 (success)
