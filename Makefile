# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
#
# SPDX-License-Identifier: Apache-2.0

# Makefile for builder-hex0-more
#
# Multi-architecture, multi-board two-stage build:
#   Stage 1 (board-specific): .S -> .hex2 -> .bin
#   Stage 2 (portable):       .S -> .hex2 -> .bin -> .hex0
#
# Usage:
#   make                          # build all
#   make riscv64                  # build riscv64 (all boards)
#   make aarch64                  # build aarch64 (all boards)
#   make test                     # test all
#   make test-riscv64-virt        # test one board
#   make test-aarch64-raspi3b     # test one board

PYTHON3 ?= python3
HEX2 = hex2/hex2
QEMU_RISCV64 ?= qemu-system-riscv64
QEMU_AARCH64 ?= qemu-system-aarch64

# ---- Top-level targets ----

all: riscv64 aarch64

riscv64: riscv64-stage1-virt riscv64-stage1-sifive_u riscv64-stage2
aarch64: aarch64-stage1-virt aarch64-stage1-raspi3b aarch64-stage2

test: test-riscv64 test-aarch64
test-riscv64: test-riscv64-virt test-riscv64-sifive_u
test-aarch64: test-aarch64-virt test-aarch64-raspi3b

clean:
	rm -f builder-hex0-*.hex2 builder-hex0-*.bin builder-hex0-*.hex0 test-*.img
	$(MAKE) -C hex2 clean

.PHONY: all riscv64 aarch64 test test-riscv64 test-aarch64 clean
.PHONY: riscv64-stage1-virt riscv64-stage1-sifive_u riscv64-stage2
.PHONY: aarch64-stage1-virt aarch64-stage1-raspi3b aarch64-stage2
.PHONY: test-riscv64-virt test-riscv64-sifive_u
.PHONY: test-aarch64-virt test-aarch64-raspi3b

# ---- hex2 linker ----

$(HEX2):
	$(MAKE) -C hex2

# ===========================================================================
# RISC-V 64-bit
# ===========================================================================

# --- Stage 1 virt (512 bytes) ---

riscv64-stage1-virt: builder-hex0-riscv64-stage1-virt.bin builder-hex0-riscv64-stage1-virt.hex0

builder-hex0-riscv64-stage1-virt.hex2: builder-hex0-riscv64-stage1-virt.S rv64-asm2hex2.py asm.py
	$(PYTHON3) rv64-asm2hex2.py < $< > $@

builder-hex0-riscv64-stage1-virt.bin: builder-hex0-riscv64-stage1-virt.hex2 $(HEX2)
	$(HEX2) -f $< --architecture riscv64 --base-address 0x80200000 --little-endian -o $@

builder-hex0-riscv64-stage1-virt.hex0: builder-hex0-riscv64-stage1-virt.hex2 builder-hex0-riscv64-stage1-virt.bin hex2tohex0.py
	$(PYTHON3) hex2tohex0.py $< builder-hex0-riscv64-stage1-virt.bin $@

# --- Stage 1 sifive_u (756 bytes) ---

riscv64-stage1-sifive_u: builder-hex0-riscv64-stage1-sifive_u.bin builder-hex0-riscv64-stage1-sifive_u.hex0

builder-hex0-riscv64-stage1-sifive_u.hex2: builder-hex0-riscv64-stage1-sifive_u.S rv64-asm2hex2.py asm.py
	$(PYTHON3) rv64-asm2hex2.py < $< > $@

builder-hex0-riscv64-stage1-sifive_u.bin: builder-hex0-riscv64-stage1-sifive_u.hex2 $(HEX2)
	$(HEX2) -f $< --architecture riscv64 --base-address 0x80200000 --little-endian -o $@

builder-hex0-riscv64-stage1-sifive_u.hex0: builder-hex0-riscv64-stage1-sifive_u.hex2 builder-hex0-riscv64-stage1-sifive_u.bin hex2tohex0.py
	$(PYTHON3) hex2tohex0.py $< builder-hex0-riscv64-stage1-sifive_u.bin $@

# --- Stage 2 (~9KB) ---

riscv64-stage2: builder-hex0-riscv64-stage2.hex0

builder-hex0-riscv64-stage2.hex2: builder-hex0-riscv64-stage2.S rv64-asm2hex2.py asm.py
	$(PYTHON3) rv64-asm2hex2.py < $< > $@

builder-hex0-riscv64-stage2.bin: builder-hex0-riscv64-stage2.hex2 $(HEX2)
	$(HEX2) -f $< --architecture riscv64 --base-address 0x80210000 --little-endian -o $@

builder-hex0-riscv64-stage2.hex0: builder-hex0-riscv64-stage2.hex2 builder-hex0-riscv64-stage2.bin hex2tohex0.py
	$(PYTHON3) hex2tohex0.py $< builder-hex0-riscv64-stage2.bin $@

# ===========================================================================
# AArch64
# ===========================================================================

# --- Stage 1 virt (500 bytes) ---

aarch64-stage1-virt: builder-hex0-aarch64-stage1-virt.bin builder-hex0-aarch64-stage1-virt.hex0

builder-hex0-aarch64-stage1-virt.hex2: builder-hex0-aarch64-stage1-virt.S a64-asm2hex2.py a64_asm.py
	$(PYTHON3) a64-asm2hex2.py < $< > $@

builder-hex0-aarch64-stage1-virt.bin: builder-hex0-aarch64-stage1-virt.hex2 $(HEX2)
	$(HEX2) -f $< --architecture aarch64 --base-address 0x40080000 --little-endian -o $@

builder-hex0-aarch64-stage1-virt.hex0: builder-hex0-aarch64-stage1-virt.hex2 builder-hex0-aarch64-stage1-virt.bin hex2tohex0.py
	$(PYTHON3) hex2tohex0.py $< builder-hex0-aarch64-stage1-virt.bin $@

# --- Stage 1 raspi3b (1916 bytes) ---

aarch64-stage1-raspi3b: builder-hex0-aarch64-stage1-raspi3b.bin builder-hex0-aarch64-stage1-raspi3b.hex0

builder-hex0-aarch64-stage1-raspi3b.hex2: builder-hex0-aarch64-stage1-raspi3b.S a64-asm2hex2.py a64_asm.py
	$(PYTHON3) a64-asm2hex2.py < $< > $@

builder-hex0-aarch64-stage1-raspi3b.bin: builder-hex0-aarch64-stage1-raspi3b.hex2 $(HEX2)
	$(HEX2) -f $< --architecture aarch64 --base-address 0x00080000 --little-endian -o $@

builder-hex0-aarch64-stage1-raspi3b.hex0: builder-hex0-aarch64-stage1-raspi3b.hex2 builder-hex0-aarch64-stage1-raspi3b.bin hex2tohex0.py
	$(PYTHON3) hex2tohex0.py $< builder-hex0-aarch64-stage1-raspi3b.bin $@

# --- Stage 2 (~15KB) ---

aarch64-stage2: builder-hex0-aarch64-stage2.hex0

builder-hex0-aarch64-stage2.hex2: builder-hex0-aarch64-stage2.S a64-asm2hex2.py a64_asm.py
	$(PYTHON3) a64-asm2hex2.py < $< > $@

builder-hex0-aarch64-stage2.bin: builder-hex0-aarch64-stage2.hex2 $(HEX2)
	$(HEX2) -f $< --architecture aarch64 --base-address 0x40210000 --little-endian -o $@

builder-hex0-aarch64-stage2.hex0: builder-hex0-aarch64-stage2.hex2 builder-hex0-aarch64-stage2.bin hex2tohex0.py
	$(PYTHON3) hex2tohex0.py $< builder-hex0-aarch64-stage2.bin $@

# ===========================================================================
# Tests
# ===========================================================================

# --- RISC-V virt ---

test-riscv64-virt: builder-hex0-riscv64-stage1-virt.bin builder-hex0-riscv64-stage2.hex0
	@size=$$(wc -c < builder-hex0-riscv64-stage1-virt.bin); \
	if [ $$size -le 512 ]; then echo "PASS: stage1-virt $$size bytes (<= 512)"; \
	else echo "FAIL: stage1-virt $$size bytes (> 512)"; exit 1; fi
	dd if=builder-hex0-riscv64-stage2.hex0 of=test-virt.img bs=512 conv=sync 2>/dev/null
	dd if=/dev/zero bs=512 count=4 >> test-virt.img 2>/dev/null
	$(QEMU_RISCV64) -machine virt -m 2G -nographic \
		-kernel builder-hex0-riscv64-stage1-virt.bin \
		-drive file=test-virt.img,format=raw,if=none,id=hd0 \
		-device virtio-blk-device,drive=hd0 \
		--no-reboot

# --- RISC-V sifive_u (requires QEMU >= 10.1) ---

test-riscv64-sifive_u: builder-hex0-riscv64-stage1-sifive_u.bin builder-hex0-riscv64-stage2.hex0
	dd if=/dev/zero of=test-sifive_u.img bs=1024 count=1024 2>/dev/null
	dd if=builder-hex0-riscv64-stage2.hex0 of=test-sifive_u.img bs=512 conv=notrunc 2>/dev/null
	$(QEMU_RISCV64) -machine sifive_u -m 2G -nographic \
		-kernel builder-hex0-riscv64-stage1-sifive_u.bin \
		-drive file=test-sifive_u.img,format=raw,if=sd \
		--no-reboot

# --- AArch64 virt ---

test-aarch64-virt: builder-hex0-aarch64-stage1-virt.bin builder-hex0-aarch64-stage2.hex0
	dd if=builder-hex0-aarch64-stage2.hex0 of=test-virt.img bs=512 conv=sync 2>/dev/null
	dd if=/dev/zero bs=512 count=4 >> test-virt.img 2>/dev/null
	$(QEMU_AARCH64) -machine virt -cpu cortex-a53 -m 2G -nographic \
		-kernel builder-hex0-aarch64-stage1-virt.bin \
		-drive file=test-virt.img,format=raw,if=none,id=hd0 \
		-device virtio-blk-device,drive=hd0 \
		--no-reboot

# --- AArch64 raspi3b ---

test-aarch64-raspi3b: builder-hex0-aarch64-stage1-raspi3b.bin builder-hex0-aarch64-stage2.hex0
	dd if=/dev/zero of=test-raspi3b.img bs=1024 count=1024 2>/dev/null
	dd if=builder-hex0-aarch64-stage2.hex0 of=test-raspi3b.img bs=512 conv=notrunc 2>/dev/null
	$(QEMU_AARCH64) -machine raspi3b -serial mon:stdio -nographic \
		-kernel builder-hex0-aarch64-stage1-raspi3b.bin \
		-drive file=test-raspi3b.img,if=sd,format=raw \
		--no-reboot
