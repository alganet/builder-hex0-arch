# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
#
# SPDX-License-Identifier: Apache-2.0

# Makefile for builder-hex0-riscv64
#
# Two-stage build:
#   builder-hex0-riscv64-stage1.S -> .hex2 -> .bin  (minimal hex0 bootloader, <=512 bytes)
#   builder-hex0-riscv64-stage2.S -> .hex2 -> .bin -> .hex0  (full kernel as hex0 source)

PYTHON3 ?= python3
HEX2 = hex2/hex2

QEMU ?= qemu-system-riscv64

STAGE1 = builder-hex0-riscv64-stage1
STAGE2 = builder-hex0-riscv64-stage2

all: $(STAGE1).hex0 $(STAGE1).bin $(STAGE2).hex0

$(HEX2):
	$(MAKE) -C hex2

# --- Stage 1: minimal hex0 bootloader ---

$(STAGE1).hex2: $(STAGE1).S rv64-asm2hex2.py asm.py
	$(PYTHON3) rv64-asm2hex2.py < $(STAGE1).S > $(STAGE1).hex2

$(STAGE1).bin: $(STAGE1).hex2 $(HEX2)
	$(HEX2) -f $(STAGE1).hex2 --architecture riscv64 \
		--base-address 0x80200000 --little-endian -o $(STAGE1).bin

$(STAGE1).hex0: $(STAGE1).hex2 $(STAGE1).bin hex2tohex0.py
	$(PYTHON3) hex2tohex0.py $(STAGE1).hex2 $(STAGE1).bin $(STAGE1).hex0

# --- Stage 2: full kernel compiled to hex0 ---

$(STAGE2).hex2: $(STAGE2).S rv64-asm2hex2.py asm.py
	$(PYTHON3) rv64-asm2hex2.py < $(STAGE2).S > $(STAGE2).hex2

$(STAGE2).bin: $(STAGE2).hex2 $(HEX2)
	$(HEX2) -f $(STAGE2).hex2 --architecture riscv64 \
		--base-address 0x80210000 --little-endian -o $(STAGE2).bin

$(STAGE2).hex0: $(STAGE2).hex2 $(STAGE2).bin hex2tohex0.py
	$(PYTHON3) hex2tohex0.py $(STAGE2).hex2 $(STAGE2).bin $(STAGE2).hex0

# --- Tests ---

test: test-stage1 test-boot

# Stage 1: verify bootloader fits in 512 bytes
test-stage1: $(STAGE1).bin
	@size=$$(wc -c < $(STAGE1).bin); \
	if [ $$size -le 512 ]; then echo "PASS: stage1 $$size bytes (<= 512)"; \
	else echo "FAIL: stage1 $$size bytes (> 512)"; exit 1; fi

# Two-stage boot: stage1 compiles stage2.hex0 from disk, kernel runs and shuts down
test-boot: $(STAGE1).bin $(STAGE2).hex0
	dd if=$(STAGE2).hex0 of=test.img bs=512 conv=sync 2>/dev/null
	dd if=/dev/zero bs=512 count=4 >> test.img 2>/dev/null
	$(QEMU) -machine virt -m 2G -nographic \
		-kernel $(STAGE1).bin \
		-drive file=test.img,format=raw,if=none,id=hd0 \
		-device virtio-blk-device,drive=hd0 \
		--no-reboot

clean:
	rm -f $(STAGE1).hex2 $(STAGE1).bin $(STAGE1).hex0
	rm -f $(STAGE2).hex2 $(STAGE2).bin $(STAGE2).hex0
	rm -f test.img
	$(MAKE) -C hex2 clean

.PHONY: all test test-stage1 test-boot clean
