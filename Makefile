# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
#
# SPDX-License-Identifier: Apache-2.0

# Makefile for builder-hex0-arch
#
# Multi-architecture, multi-board two-stage build:
#   Stage 1 (board-specific): .S -> .hex2 -> .bin
#   Stage 2 (portable):       .S -> .hex2 -> .bin -> .hex0
#
# Usage:
#   make                          # build all
#   make x86                      # x86 is vendored (no build step)
#   make riscv64                  # build riscv64 (all boards)
#   make aarch64                  # build aarch64 (all boards)
#   make test                     # test all
#   make test-x86-bios            # test one board
#   make test-riscv64-virt        # test one board
#   make test-aarch64-raspi3b     # test one board

PYTHON3 ?= python3
HEX2 = hex2/hex2
QEMU_X86 ?= qemu-system-x86_64
QEMU_RISCV64 ?= qemu-system-riscv64
QEMU_AARCH64 ?= qemu-system-aarch64

# ---- Top-level targets ----

all: x86 riscv64 aarch64

x86:
	@echo "x86: vendored hex0 (no build step)"

riscv64: riscv64-stage1-virt riscv64-stage1-sifive_u riscv64-stage2
aarch64: aarch64-stage1-virt aarch64-stage1-raspi3b aarch64-stage2

test: test-x86 test-riscv64 test-aarch64
test-x86: test-x86-bios
test-riscv64: test-riscv64-virt test-riscv64-sifive_u
test-aarch64: test-aarch64-virt test-aarch64-raspi3b

self-test: self-test-x86 self-test-riscv64 self-test-aarch64
self-test-x86: self-test-x86-bios
self-test-riscv64: self-test-riscv64-virt self-test-riscv64-sifive_u
self-test-aarch64: self-test-aarch64-virt self-test-aarch64-raspi3b

clean:
	rm -f builder-hex0-riscv64-*.hex2 builder-hex0-riscv64-*.bin builder-hex0-riscv64-*.hex0
	rm -f builder-hex0-aarch64-*.hex2 builder-hex0-aarch64-*.bin builder-hex0-aarch64-*.hex0
	rm -f test-*.img test-self-*.bin BUILD -rf
	$(MAKE) -C hex2 clean

.PHONY: all x86 riscv64 aarch64 test test-x86 test-riscv64 test-aarch64 clean
.PHONY: self-test self-test-x86 self-test-riscv64 self-test-aarch64
.PHONY: riscv64-stage1-virt riscv64-stage1-sifive_u riscv64-stage2
.PHONY: aarch64-stage1-virt aarch64-stage1-raspi3b aarch64-stage2
.PHONY: test-x86-bios test-riscv64-virt test-riscv64-sifive_u
.PHONY: test-aarch64-virt test-aarch64-raspi3b
.PHONY: self-test-x86-bios self-test-riscv64-virt self-test-riscv64-sifive_u
.PHONY: self-test-aarch64-virt self-test-aarch64-raspi3b

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
# x86 (vendored hex0, no build step)
# ===========================================================================

# --- x86 bios ---

test-x86-bios: builder-hex0-x86-stage1-bios.hex0 builder-hex0-x86-stage2.hex0 builder-hex0-x86-mini.hex0
	@echo "=== x86 bios: mini compiles stage1, seed-verify ==="
	# Compile mini hex0 to binary using host xxd (seed)
	cut builder-hex0-x86-mini.hex0 -f1 -d'#' | cut -f1 -d';' | xxd -r -p > test-x86-mini-seed.bin
	# Mini seed compiles stage1 hex0
	dd if=/dev/zero of=test-bios.img bs=512 count=257 2>/dev/null
	dd if=test-x86-mini-seed.bin of=test-bios.img bs=512 conv=notrunc 2>/dev/null
	dd if=builder-hex0-x86-stage1-bios.hex0 of=test-bios.img bs=512 seek=1 conv=notrunc 2>/dev/null
	$(QEMU_X86) -m 256M -nographic -drive file=test-bios.img,format=raw --no-reboot
	# Verify: host-compiled stage1 matches mini-compiled stage1
	cut builder-hex0-x86-stage1-bios.hex0 -f1 -d'#' | cut -f1 -d';' | xxd -r -p > test-x86-stage1-seed.bin
	dd if=test-bios.img of=test-x86-stage1-built.bin bs=1 count=$$(wc -c < test-x86-stage1-seed.bin | tr -d ' ') status=none
	diff test-x86-stage1-seed.bin test-x86-stage1-built.bin
	@echo "PASS: x86 stage1 built by mini matches host-compiled seed"
	rm -f test-x86-mini-seed.bin test-x86-stage1-seed.bin test-x86-stage1-built.bin

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

# ===========================================================================
# Self-build reproducibility tests
# ===========================================================================
#
# Each test boots the kernel, hex0-compiles a source file via the internal
# shell, flushes to disk, extracts the result, and diffs against the
# host-compiled binary. A passing diff proves reproducibility.

# --- x86 bios (mini builds mini, then mini builds full) ---

self-test-x86-bios: builder-hex0-x86-stage1-bios.hex0 builder-hex0-x86-stage2.hex0 builder-hex0-x86-mini.hex0
	@echo "=== x86 bios: mini seed -> mini self-build ==="
	mkdir -p BUILD
	cut builder-hex0-x86-mini.hex0 -f1 -d'#' | cut -f1 -d';' | xxd -r -p > BUILD/x86-mini-seed.bin
	./hex0-to-src.sh builder-hex0-x86-mini.hex0 > BUILD/x86-mini.src
	./build-self.sh x86 bios BUILD/x86-mini-seed.bin builder-hex0-x86-mini.hex0 BUILD/x86-mini.src 512 BUILD/x86-mini-self.bin
	diff BUILD/x86-mini-seed.bin BUILD/x86-mini-self.bin
	@echo "PASS: x86 mini self-build reproduces"

# --- riscv64 virt ---

self-test-riscv64-virt: builder-hex0-riscv64-stage1-virt.bin builder-hex0-riscv64-stage2.hex0 builder-hex0-riscv64-stage1-virt.hex0
	@echo "=== riscv64 virt: stage2 self-build ==="
	./hex0-to-src.sh builder-hex0-riscv64-stage2.hex0 > test-self-riscv64-virt.src
	./build-self.sh riscv64 virt builder-hex0-riscv64-stage1-virt.bin \
		builder-hex0-riscv64-stage2.hex0 test-self-riscv64-virt.src \
		$$(wc -c < builder-hex0-riscv64-stage2.bin | tr -d ' ') test-self-riscv64-virt-stage2.bin
	diff builder-hex0-riscv64-stage2.bin test-self-riscv64-virt-stage2.bin
	@echo "PASS: riscv64 virt stage2 self-build reproduces"
	@echo "=== riscv64 virt: stage1 self-build ==="
	./hex0-to-src.sh builder-hex0-riscv64-stage1-virt.hex0 > test-self-riscv64-virt-s1.src
	./build-self.sh riscv64 virt builder-hex0-riscv64-stage1-virt.bin \
		builder-hex0-riscv64-stage2.hex0 test-self-riscv64-virt-s1.src \
		$$(wc -c < builder-hex0-riscv64-stage1-virt.bin | tr -d ' ') test-self-riscv64-virt-stage1.bin
	diff builder-hex0-riscv64-stage1-virt.bin test-self-riscv64-virt-stage1.bin
	@echo "PASS: riscv64 virt stage1 self-build reproduces"

# --- riscv64 sifive_u ---

self-test-riscv64-sifive_u: builder-hex0-riscv64-stage1-sifive_u.bin builder-hex0-riscv64-stage2.hex0 builder-hex0-riscv64-stage1-sifive_u.hex0
	@echo "=== riscv64 sifive_u: stage2 self-build ==="
	./hex0-to-src.sh builder-hex0-riscv64-stage2.hex0 > test-self-riscv64-sifive_u.src
	./build-self.sh riscv64 sifive_u builder-hex0-riscv64-stage1-sifive_u.bin \
		builder-hex0-riscv64-stage2.hex0 test-self-riscv64-sifive_u.src \
		$$(wc -c < builder-hex0-riscv64-stage2.bin | tr -d ' ') test-self-riscv64-sifive_u-stage2.bin
	diff builder-hex0-riscv64-stage2.bin test-self-riscv64-sifive_u-stage2.bin
	@echo "PASS: riscv64 sifive_u stage2 self-build reproduces"
	@echo "=== riscv64 sifive_u: stage1 self-build ==="
	./hex0-to-src.sh builder-hex0-riscv64-stage1-sifive_u.hex0 > test-self-riscv64-sifive_u-s1.src
	./build-self.sh riscv64 sifive_u builder-hex0-riscv64-stage1-sifive_u.bin \
		builder-hex0-riscv64-stage2.hex0 test-self-riscv64-sifive_u-s1.src \
		$$(wc -c < builder-hex0-riscv64-stage1-sifive_u.bin | tr -d ' ') test-self-riscv64-sifive_u-stage1.bin
	diff builder-hex0-riscv64-stage1-sifive_u.bin test-self-riscv64-sifive_u-stage1.bin
	@echo "PASS: riscv64 sifive_u stage1 self-build reproduces"

# --- AArch64 virt ---

self-test-aarch64-virt: builder-hex0-aarch64-stage1-virt.bin builder-hex0-aarch64-stage2.hex0 builder-hex0-aarch64-stage1-virt.hex0
	@echo "=== aarch64 virt: stage2 self-build ==="
	./hex0-to-src.sh builder-hex0-aarch64-stage2.hex0 > test-self-aarch64-virt.src
	./build-self.sh aarch64 virt builder-hex0-aarch64-stage1-virt.bin \
		builder-hex0-aarch64-stage2.hex0 test-self-aarch64-virt.src \
		$$(wc -c < builder-hex0-aarch64-stage2.bin | tr -d ' ') test-self-aarch64-virt-stage2.bin
	diff builder-hex0-aarch64-stage2.bin test-self-aarch64-virt-stage2.bin
	@echo "PASS: aarch64 virt stage2 self-build reproduces"
	@echo "=== aarch64 virt: stage1 self-build ==="
	./hex0-to-src.sh builder-hex0-aarch64-stage1-virt.hex0 > test-self-aarch64-virt-s1.src
	./build-self.sh aarch64 virt builder-hex0-aarch64-stage1-virt.bin \
		builder-hex0-aarch64-stage2.hex0 test-self-aarch64-virt-s1.src \
		$$(wc -c < builder-hex0-aarch64-stage1-virt.bin | tr -d ' ') test-self-aarch64-virt-stage1.bin
	diff builder-hex0-aarch64-stage1-virt.bin test-self-aarch64-virt-stage1.bin
	@echo "PASS: aarch64 virt stage1 self-build reproduces"

# --- AArch64 raspi3b ---

self-test-aarch64-raspi3b: builder-hex0-aarch64-stage1-raspi3b.bin builder-hex0-aarch64-stage2.hex0 builder-hex0-aarch64-stage1-raspi3b.hex0
	@echo "=== aarch64 raspi3b: stage2 self-build ==="
	./hex0-to-src.sh builder-hex0-aarch64-stage2.hex0 > test-self-aarch64-raspi3b.src
	./build-self.sh aarch64 raspi3b builder-hex0-aarch64-stage1-raspi3b.bin \
		builder-hex0-aarch64-stage2.hex0 test-self-aarch64-raspi3b.src \
		$$(wc -c < builder-hex0-aarch64-stage2.bin | tr -d ' ') test-self-aarch64-raspi3b-stage2.bin
	diff builder-hex0-aarch64-stage2.bin test-self-aarch64-raspi3b-stage2.bin
	@echo "PASS: aarch64 raspi3b stage2 self-build reproduces"
	@echo "=== aarch64 raspi3b: stage1 self-build ==="
	./hex0-to-src.sh builder-hex0-aarch64-stage1-raspi3b.hex0 > test-self-aarch64-raspi3b-s1.src
	./build-self.sh aarch64 raspi3b builder-hex0-aarch64-stage1-raspi3b.bin \
		builder-hex0-aarch64-stage2.hex0 test-self-aarch64-raspi3b-s1.src \
		$$(wc -c < builder-hex0-aarch64-stage1-raspi3b.bin | tr -d ' ') test-self-aarch64-raspi3b-stage1.bin
	diff builder-hex0-aarch64-stage1-raspi3b.bin test-self-aarch64-raspi3b-stage1.bin
	@echo "PASS: aarch64 raspi3b stage1 self-build reproduces"
