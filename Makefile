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
#   make                     # build all architectures
#   make riscv64              # build riscv64 only
#   make aarch64              # build aarch64 only
#   make test                 # test all architectures
#   make test-riscv64         # test riscv64 only
#   make test-aarch64         # test aarch64 only

PYTHON3 ?= python3
HEX2 = hex2/hex2

# ---- Top-level targets (build all) ----

all: riscv64 aarch64

riscv64:
	$(MAKE) ARCH=riscv64 build

aarch64:
	$(MAKE) ARCH=aarch64 build

test: test-riscv64 test-aarch64

test-riscv64:
	$(MAKE) ARCH=riscv64 run-tests

test-aarch64:
	$(MAKE) ARCH=aarch64 run-tests

clean:
	rm -f builder-hex0-riscv64-stage1-virt.hex2 builder-hex0-riscv64-stage1-virt.bin builder-hex0-riscv64-stage1-virt.hex0
	rm -f builder-hex0-riscv64-stage1-sifive_u.hex2 builder-hex0-riscv64-stage1-sifive_u.bin builder-hex0-riscv64-stage1-sifive_u.hex0
	rm -f builder-hex0-riscv64-stage2.hex2 builder-hex0-riscv64-stage2.bin builder-hex0-riscv64-stage2.hex0
	rm -f builder-hex0-aarch64-stage1-virt.hex2 builder-hex0-aarch64-stage1-virt.bin builder-hex0-aarch64-stage1-virt.hex0
	rm -f builder-hex0-aarch64-stage2.hex2 builder-hex0-aarch64-stage2.bin builder-hex0-aarch64-stage2.hex0
	rm -f test-virt.img test-sifive_u.img
	$(MAKE) -C hex2 clean

.PHONY: all riscv64 aarch64 test test-riscv64 test-aarch64 clean
.PHONY: build run-tests

# ---- Architecture-specific settings (set via recursive ARCH=) ----

ifeq ($(ARCH),riscv64)
  ASM2HEX2 = rv64-asm2hex2.py
  ASM_LIB = asm.py
  QEMU ?= qemu-system-riscv64
  STAGE1_BASE = 0x80200000
  STAGE2_BASE = 0x80210000
  HEX2_ARCH = riscv64
  STAGE1_VIRT = builder-hex0-riscv64-stage1-virt
  STAGE1_SIFIVE_U = builder-hex0-riscv64-stage1-sifive_u
  STAGE2 = builder-hex0-riscv64-stage2
  BUILD_TARGETS = $(STAGE1_VIRT).hex0 $(STAGE1_VIRT).bin \
                  $(STAGE1_SIFIVE_U).hex0 $(STAGE1_SIFIVE_U).bin \
                  $(STAGE2).hex0
  TEST_TARGETS = test-stage1-virt test-boot-virt test-boot-sifive_u
else ifeq ($(ARCH),aarch64)
  ASM2HEX2 = a64-asm2hex2.py
  ASM_LIB = a64_asm.py
  QEMU ?= qemu-system-aarch64
  STAGE1_BASE = 0x40080000
  STAGE2_BASE = 0x40210000
  HEX2_ARCH = aarch64
  STAGE1_VIRT = builder-hex0-aarch64-stage1-virt
  STAGE2 = builder-hex0-aarch64-stage2
  BUILD_TARGETS = $(STAGE1_VIRT).hex0 $(STAGE1_VIRT).bin $(STAGE2).hex0
  TEST_TARGETS = test-boot-virt
endif

# ---- Internal build/test targets (require ARCH=) ----

build: $(BUILD_TARGETS)

run-tests: $(TEST_TARGETS)

$(HEX2):
	$(MAKE) -C hex2

# --- Stage 1 virt ---

$(STAGE1_VIRT).hex2: $(STAGE1_VIRT).S $(ASM2HEX2) $(ASM_LIB)
	$(PYTHON3) $(ASM2HEX2) < $(STAGE1_VIRT).S > $(STAGE1_VIRT).hex2

$(STAGE1_VIRT).bin: $(STAGE1_VIRT).hex2 $(HEX2)
	$(HEX2) -f $(STAGE1_VIRT).hex2 --architecture $(HEX2_ARCH) \
		--base-address $(STAGE1_BASE) --little-endian -o $(STAGE1_VIRT).bin

$(STAGE1_VIRT).hex0: $(STAGE1_VIRT).hex2 $(STAGE1_VIRT).bin hex2tohex0.py
	$(PYTHON3) hex2tohex0.py $(STAGE1_VIRT).hex2 $(STAGE1_VIRT).bin $(STAGE1_VIRT).hex0

# --- Stage 1 sifive_u (riscv64 only) ---

ifeq ($(ARCH),riscv64)
$(STAGE1_SIFIVE_U).hex2: $(STAGE1_SIFIVE_U).S $(ASM2HEX2) $(ASM_LIB)
	$(PYTHON3) $(ASM2HEX2) < $(STAGE1_SIFIVE_U).S > $(STAGE1_SIFIVE_U).hex2

$(STAGE1_SIFIVE_U).bin: $(STAGE1_SIFIVE_U).hex2 $(HEX2)
	$(HEX2) -f $(STAGE1_SIFIVE_U).hex2 --architecture $(HEX2_ARCH) \
		--base-address $(STAGE1_BASE) --little-endian -o $(STAGE1_SIFIVE_U).bin

$(STAGE1_SIFIVE_U).hex0: $(STAGE1_SIFIVE_U).hex2 $(STAGE1_SIFIVE_U).bin hex2tohex0.py
	$(PYTHON3) hex2tohex0.py $(STAGE1_SIFIVE_U).hex2 $(STAGE1_SIFIVE_U).bin $(STAGE1_SIFIVE_U).hex0
endif

# --- Stage 2 ---

$(STAGE2).hex2: $(STAGE2).S $(ASM2HEX2) $(ASM_LIB)
	$(PYTHON3) $(ASM2HEX2) < $(STAGE2).S > $(STAGE2).hex2

$(STAGE2).bin: $(STAGE2).hex2 $(HEX2)
	$(HEX2) -f $(STAGE2).hex2 --architecture $(HEX2_ARCH) \
		--base-address $(STAGE2_BASE) --little-endian -o $(STAGE2).bin

$(STAGE2).hex0: $(STAGE2).hex2 $(STAGE2).bin hex2tohex0.py
	$(PYTHON3) hex2tohex0.py $(STAGE2).hex2 $(STAGE2).bin $(STAGE2).hex0

# --- Tests ---

test-stage1-virt: $(STAGE1_VIRT).bin
ifeq ($(ARCH),riscv64)
	@size=$$(wc -c < $(STAGE1_VIRT).bin); \
	if [ $$size -le 512 ]; then echo "PASS: stage1-virt $$size bytes (<= 512)"; \
	else echo "FAIL: stage1-virt $$size bytes (> 512)"; exit 1; fi
endif

test-boot-virt: $(STAGE1_VIRT).bin $(STAGE2).hex0
	dd if=$(STAGE2).hex0 of=test-virt.img bs=512 conv=sync 2>/dev/null
	dd if=/dev/zero bs=512 count=4 >> test-virt.img 2>/dev/null
ifeq ($(ARCH),riscv64)
	$(QEMU) -machine virt -m 2G -nographic \
		-kernel $(STAGE1_VIRT).bin \
		-drive file=test-virt.img,format=raw,if=none,id=hd0 \
		-device virtio-blk-device,drive=hd0 \
		--no-reboot
else ifeq ($(ARCH),aarch64)
	$(QEMU) -machine virt -cpu cortex-a53 -m 2G -nographic \
		-kernel $(STAGE1_VIRT).bin \
		-drive file=test-virt.img,format=raw,if=none,id=hd0 \
		-device virtio-blk-device,drive=hd0 \
		--no-reboot
endif

ifeq ($(ARCH),riscv64)
test-boot-sifive_u: $(STAGE1_SIFIVE_U).bin $(STAGE2).hex0
	dd if=/dev/zero of=test-sifive_u.img bs=1024 count=1024 2>/dev/null
	dd if=$(STAGE2).hex0 of=test-sifive_u.img bs=512 conv=notrunc 2>/dev/null
	$(QEMU) -machine sifive_u -m 2G -nographic \
		-kernel $(STAGE1_SIFIVE_U).bin \
		-drive file=test-sifive_u.img,format=raw,if=sd \
		--no-reboot
endif
