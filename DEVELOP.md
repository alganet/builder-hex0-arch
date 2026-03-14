<!--
SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>

SPDX-License-Identifier: Apache-2.0
-->

# Development Notes

## Build Chain

```
builder-hex0-riscv64-stage1-{board}.S  --(rv64-asm2hex2.py)-->  .hex2  --(hex2)-->  .bin
builder-hex0-riscv64-stage2.S          --(rv64-asm2hex2.py)-->  .hex2  --(hex2)-->  .bin  --(hex2tohex0.py)-->  .hex0
```

1. **builder-hex0-riscv64-stage1-virt.S** - QEMU virt stage 1 (512 bytes, VirtIO)
2. **builder-hex0-riscv64-stage1-sifive_u.S** - SiFive HiFive Unleashed stage 1 (756 bytes, SPI+SD)
3. **builder-hex0-riscv64-stage2.S** - Portable kernel (~4000 lines)
4. **rv64-asm2hex2.py** - Converts assembly to hex2 format (labels, branches, jumps)
5. **hex2** - Vendored C linker from [stage0-posix](https://github.com/oriansj/stage0-posix)
6. **hex2tohex0.py** - Converts hex2 to commented hex0 (for review/audit)

The hex2 linker is built from source in the `hex2/` directory.


## Source Files

| File | Purpose |
|------|---------|
| builder-hex0-riscv64-stage1-virt.S | QEMU virt stage 1 (VirtIO block) |
| builder-hex0-riscv64-stage1-sifive_u.S | SiFive sifive_u stage 1 (SPI+SD) |
| builder-hex0-riscv64-stage2.S | Portable stage 2 kernel |
| rv64-asm2hex2.py | Assembly-to-hex2 converter |
| asm.py | RISC-V instruction encoder library |
| hex2tohex0.py | hex2-to-hex0 converter with comments |
| hex2/ | Vendored hex2 linker (C source) |
| Makefile | Multi-board build automation |


## Two-Stage Boot

### Stage 1: Board-Specific

Each board has its own stage 1. Loaded at `0x80200000` by OpenSBI
(receives `a0=hartid`, `a1=dtb_ptr`).

Responsibilities:
1. Find and initialize the storage device (board-specific)
2. Read hex0 source from disk sector 0 onward
3. Compile hex0 to binary at `0x80210000`
4. Jump to `0x80210000` with `a0` = next disk sector, `a1` = DTB pointer

**virt** stage 1: scans VirtIO MMIO range `0x10001000-0x10008000` for block
device. Legacy VirtIO v1 only. 512 bytes.

**sifive_u** stage 1: initializes SiFive SPI controller at `0x10050000`,
performs SD card init (CMD0, CMD8, ACMD41, CMD9), reads via CMD17. Parks
non-boot harts (sifive_u boot hart = 1). 756 bytes.

### Stage 2: Portable

Portable kernel stored on disk as hex0 source. Compiled by stage 1 at boot.
Receives `a0` = filesystem start sector, `a1` = DTB pointer.

Discovers storage via FDT parsing — no hardcoded MMIO addresses. All disk I/O
goes through function pointers (`disk_read_fn` / `disk_write_fn`), set by
whichever storage driver the DTB selects.


## Architecture

### Boot Sequence

1. OpenSBI loads stage 1 at `0x80200000` in S-mode
2. Stage 1 initializes storage, reads hex0 from disk, compiles to `0x80210000`
3. Stage 1 jumps to stage 2 with `a0` = filesystem sector, `a1` = DTB pointer
4. Stage 2 parses FDT to discover storage type (VirtIO or SPI+SD)
5. Stage 2 initializes the appropriate driver, sets disk I/O function pointers
6. Sv39 paging enabled (3 gigapage entries)
7. Internal shell reads commands from disk (starting at sector `a0`)
8. Programs run in U-mode, syscalls trap to S-mode via `ecall`

### FDT Storage Discovery

`fdt_find_storage(a0=dtb_ptr)` returns `a0` = MMIO base, `a1` = type:
- Type 1 (VirtIO): node name starts with `"virt"`, probed for magic + block ID
- Type 2 (SPI+SD): node name `"spi@..."` with `"mmc@..."` child

### Disk I/O Abstraction

`disk_read_sector` / `disk_write_sector` load function pointers from globals
and tail-call the implementation. Drivers set these during init:
- VirtIO: `virtio_read_sector` / `virtio_write_sector`
- SPI+SD: `spi_sd_read_sector` / `spi_sd_write_sector`

### SPI+SD Driver

The SPI+SD driver communicates with SD cards through the SiFive SPI controller:
- `spi_transfer(a0=byte)` — exchange one byte (loads SPI base from globals)
- `spi_sd_cmd(a0=cmd, a1=arg, a2=crc)` — send SD command, poll for R1
- `spi_sd_read_sector` / `spi_sd_write_sector` — sector I/O via CMD17/CMD24

SD card init sequence (in stage 1): CMD0 → CMD8 → ACMD41 (with voltage bits
`0x40FF8000`) → CMD9 (transitions to transfer state). Each command is followed
by a flush byte to consume the ssi-sd bridge's RESPONSE→CMD state transition.
Uses byte addressing (`sector * 512`) for standard-capacity cards.

### Reboot (not Shutdown)

Uses SBI SRST with `type=COLD_REBOOT` (not SHUTDOWN). Reboot is more portable
(all boards have a reboot device) and matches the bootstrap lifecycle: boot →
build → rewrite disk → reboot into next stage. Tests use `--no-reboot` so
QEMU exits cleanly.


## Porting to a New Board

1. Create `builder-hex0-riscv64-stage1-{board}.S` with storage init + hex0 compiler
2. Add build targets to `Makefile`
3. If using a new storage type, add a driver to stage 2 implementing
   `xx_read_sector(a0=sector, a1=buffer)` and `xx_write_sector`
4. Add detection logic in `fdt_find_storage` for the new DTB node pattern
5. Add a test target (`test-boot-{board}`)

The sifive_u implementation serves as the reference for non-VirtIO boards.


## Build and Test Checklist

```
make clean && make
make test                    # runs all board tests
```

The sifive_u test requires QEMU >= 10.1.


## Debugging

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

For instruction tracing: `qemu-system-riscv64 -d in_asm,cpu ...`

For SD card debugging: `-trace "sdcard_*" -d guest_errors`
