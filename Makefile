# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
#
# SPDX-License-Identifier: Apache-2.0

# Makefile for builder-hex0-riscv64
#
# Build chain: kernel.S -> kernel.hex2 -> builder-hex0-riscv64.bin
#
# The assembly-to-hex2 conversion uses a Python tool (rv64-asm2hex2.py).
# The hex2-to-binary step uses a vendored C hex2 linker (hex2/).

PYTHON3 ?= python3
HEX2 = hex2/hex2
BASE_ADDRESS = 0x80200000
BIN = builder-hex0-riscv64.bin
HEX2_SRC = kernel.hex2
ASM_SRC = kernel.S

QEMU ?= qemu-system-riscv64

all: $(BIN)

$(HEX2):
	$(MAKE) -C hex2

$(HEX2_SRC): $(ASM_SRC) rv64-asm2hex2.py asm.py
	$(PYTHON3) rv64-asm2hex2.py < $(ASM_SRC) > $(HEX2_SRC)

$(BIN): $(HEX2_SRC) $(HEX2)
	$(HEX2) -f $(HEX2_SRC) --architecture riscv64 \
		--base-address $(BASE_ADDRESS) --little-endian -o $(BIN)

# Boot with an empty disk image to verify the kernel starts and shuts down.
test: $(BIN)
	dd if=/dev/zero of=/tmp/bh0-rv64-test.img bs=512 count=2 2>/dev/null
	timeout 10 $(QEMU) -machine virt -m 2G -nographic \
		-kernel $(BIN) \
		-drive file=/tmp/bh0-rv64-test.img,format=raw,if=none,id=hd0 \
		-device virtio-blk-device,drive=hd0 \
		--no-reboot; \
	rc=$$?; rm -f /tmp/bh0-rv64-test.img; \
	if [ $$rc -eq 0 ]; then echo "PASS: kernel booted and shut down cleanly"; \
	else echo "FAIL: exit code $$rc"; exit 1; fi

clean:
	rm -f $(BIN) $(HEX2_SRC)
	$(MAKE) -C hex2 clean

.PHONY: all test clean
