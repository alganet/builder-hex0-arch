# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
#
# SPDX-License-Identifier: Apache-2.0

# Makefile for builder-hex0-riscv64
#
# Multi-board two-stage build:
#   Stage 1 (board-specific): .S -> .hex2 -> .bin
#   Stage 2 (portable):       .S -> .hex2 -> .bin -> .hex0

PYTHON3 ?= python3
HEX2 = hex2/hex2

QEMU ?= qemu-system-riscv64

STAGE1_VIRT = builder-hex0-riscv64-stage1-virt
STAGE1_SIFIVE_U = builder-hex0-riscv64-stage1-sifive_u
STAGE2 = builder-hex0-riscv64-stage2

all: $(STAGE1_VIRT).hex0 $(STAGE1_VIRT).bin $(STAGE1_SIFIVE_U).hex0 $(STAGE1_SIFIVE_U).bin $(STAGE2).hex0

$(HEX2):
	$(MAKE) -C hex2

# --- Stage 1 virt: QEMU virt board (VirtIO) ---

$(STAGE1_VIRT).hex2: $(STAGE1_VIRT).S rv64-asm2hex2.py asm.py
	$(PYTHON3) rv64-asm2hex2.py < $(STAGE1_VIRT).S > $(STAGE1_VIRT).hex2

$(STAGE1_VIRT).bin: $(STAGE1_VIRT).hex2 $(HEX2)
	$(HEX2) -f $(STAGE1_VIRT).hex2 --architecture riscv64 \
		--base-address 0x80200000 --little-endian -o $(STAGE1_VIRT).bin

$(STAGE1_VIRT).hex0: $(STAGE1_VIRT).hex2 $(STAGE1_VIRT).bin hex2tohex0.py
	$(PYTHON3) hex2tohex0.py $(STAGE1_VIRT).hex2 $(STAGE1_VIRT).bin $(STAGE1_VIRT).hex0

# --- Stage 1 sifive_u: SiFive HiFive Unleashed (SPI+SD) ---

$(STAGE1_SIFIVE_U).hex2: $(STAGE1_SIFIVE_U).S rv64-asm2hex2.py asm.py
	$(PYTHON3) rv64-asm2hex2.py < $(STAGE1_SIFIVE_U).S > $(STAGE1_SIFIVE_U).hex2

$(STAGE1_SIFIVE_U).bin: $(STAGE1_SIFIVE_U).hex2 $(HEX2)
	$(HEX2) -f $(STAGE1_SIFIVE_U).hex2 --architecture riscv64 \
		--base-address 0x80200000 --little-endian -o $(STAGE1_SIFIVE_U).bin

$(STAGE1_SIFIVE_U).hex0: $(STAGE1_SIFIVE_U).hex2 $(STAGE1_SIFIVE_U).bin hex2tohex0.py
	$(PYTHON3) hex2tohex0.py $(STAGE1_SIFIVE_U).hex2 $(STAGE1_SIFIVE_U).bin $(STAGE1_SIFIVE_U).hex0

# --- Stage 2: portable kernel compiled to hex0 ---

$(STAGE2).hex2: $(STAGE2).S rv64-asm2hex2.py asm.py
	$(PYTHON3) rv64-asm2hex2.py < $(STAGE2).S > $(STAGE2).hex2

$(STAGE2).bin: $(STAGE2).hex2 $(HEX2)
	$(HEX2) -f $(STAGE2).hex2 --architecture riscv64 \
		--base-address 0x80210000 --little-endian -o $(STAGE2).bin

$(STAGE2).hex0: $(STAGE2).hex2 $(STAGE2).bin hex2tohex0.py
	$(PYTHON3) hex2tohex0.py $(STAGE2).hex2 $(STAGE2).bin $(STAGE2).hex0

# --- Tests ---

test: test-stage1-virt test-boot-virt test-boot-sifive_u

# Stage 1 virt: verify bootloader fits in 512 bytes
test-stage1-virt: $(STAGE1_VIRT).bin
	@size=$$(wc -c < $(STAGE1_VIRT).bin); \
	if [ $$size -le 512 ]; then echo "PASS: stage1-virt $$size bytes (<= 512)"; \
	else echo "FAIL: stage1-virt $$size bytes (> 512)"; exit 1; fi

# Boot test virt: stage1 compiles stage2.hex0, kernel runs and reboots
test-boot-virt: $(STAGE1_VIRT).bin $(STAGE2).hex0
	dd if=$(STAGE2).hex0 of=test-virt.img bs=512 conv=sync 2>/dev/null
	dd if=/dev/zero bs=512 count=4 >> test-virt.img 2>/dev/null
	$(QEMU) -machine virt -m 2G -nographic \
		-kernel $(STAGE1_VIRT).bin \
		-drive file=test-virt.img,format=raw,if=none,id=hd0 \
		-device virtio-blk-device,drive=hd0 \
		--no-reboot

# Boot test sifive_u: stage1 reads SD via SPI, kernel runs and reboots
# SD card image must be power-of-2 sized; pad to 1MB
test-boot-sifive_u: $(STAGE1_SIFIVE_U).bin $(STAGE2).hex0
	dd if=/dev/zero of=test-sifive_u.img bs=1024 count=1024 2>/dev/null
	dd if=$(STAGE2).hex0 of=test-sifive_u.img bs=512 conv=notrunc 2>/dev/null
	$(QEMU) -machine sifive_u -m 2G -nographic \
		-kernel $(STAGE1_SIFIVE_U).bin \
		-drive file=test-sifive_u.img,format=raw,if=sd \
		--no-reboot

clean:
	rm -f $(STAGE1_VIRT).hex2 $(STAGE1_VIRT).bin $(STAGE1_VIRT).hex0
	rm -f $(STAGE1_SIFIVE_U).hex2 $(STAGE1_SIFIVE_U).bin $(STAGE1_SIFIVE_U).hex0
	rm -f $(STAGE2).hex2 $(STAGE2).bin $(STAGE2).hex0
	rm -f test-virt.img test-sifive_u.img
	$(MAKE) -C hex2 clean

.PHONY: all test test-stage1-virt test-boot-virt test-boot-sifive_u clean
