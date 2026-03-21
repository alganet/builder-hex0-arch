#!/bin/sh
# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: Apache-2.0
#
# Boot a builder-hex0 kernel and run a hex0-to-src script.
# The kernel compiles hex0 source to /dev/hda, which is flushed to disk.
# After QEMU exits, extract the artifact from the disk image.
#
# Usage: build-self.sh <arch> <board> <stage1.bin> <stage2.hex0> <src-script> <artifact-size> <artifact.bin>

set -eu

ARCH="$1"
BOARD="$2"
STAGE1="$3"
STAGE2_HEX0="$4"
SRC="$5"
ARTIFACT_SIZE="$6"
ARTIFACT="$7"

QEMU_X86="${QEMU_X86:-qemu-system-x86_64}"
QEMU_RISCV64="${QEMU_RISCV64:-qemu-system-riscv64}"
QEMU_AARCH64="${QEMU_AARCH64:-qemu-system-aarch64}"

IMG="test-self-${ARCH}-${BOARD}.img"

# Create disk image: stage2.hex0 (null-terminated) + src script
dd if=/dev/zero of="$IMG" bs=1024 count=1024 2>/dev/null
dd if="$STAGE2_HEX0" of="$IMG" bs=512 conv=notrunc 2>/dev/null
# Calculate sector after stage2 hex0
STAGE2_LEN=$(wc -c < "$STAGE2_HEX0" | tr -d ' ')
if [ $((STAGE2_LEN % 512)) -eq 0 ]; then
    SRC_SECTOR=$((STAGE2_LEN / 512))
else
    SRC_SECTOR=$((STAGE2_LEN / 512 + 1))
fi
dd if="$SRC" of="$IMG" seek="$SRC_SECTOR" bs=512 conv=notrunc 2>/dev/null

case "${ARCH}-${BOARD}" in
    x86-bios)
        # x86: stage1 is MBR, stage2 hex0 starts at sector 1
        dd if=/dev/zero of="$IMG" bs=512 count=2064384 2>/dev/null
        cat "$STAGE1" "$STAGE2_HEX0" > "${IMG}.input"
        dd if="${IMG}.input" of="$IMG" conv=notrunc 2>/dev/null
        # Append src after stage1+stage2
        INPUT_LEN=$(wc -c < "${IMG}.input" | tr -d ' ')
        if [ $((INPUT_LEN % 512)) -eq 0 ]; then
            SRC_SECTOR=$((INPUT_LEN / 512))
        else
            SRC_SECTOR=$((INPUT_LEN / 512 + 1))
        fi
        dd if="$SRC" of="$IMG" seek="$SRC_SECTOR" bs=512 conv=notrunc 2>/dev/null
        rm -f "${IMG}.input"
        $QEMU_X86 -m 256M -nographic -drive file="$IMG",format=raw --no-reboot
        ;;
    riscv64-virt)
        $QEMU_RISCV64 -machine virt -m 2G -nographic \
            -kernel "$STAGE1" \
            -drive file="$IMG",format=raw,if=none,id=hd0 \
            -device virtio-blk-device,drive=hd0 \
            --no-reboot
        ;;
    riscv64-sifive_u)
        $QEMU_RISCV64 -machine sifive_u -m 2G -nographic \
            -kernel "$STAGE1" \
            -drive file="$IMG",format=raw,if=sd \
            --no-reboot
        ;;
    aarch64-virt)
        $QEMU_AARCH64 -machine virt -cpu cortex-a53 -m 2G -nographic \
            -kernel "$STAGE1" \
            -drive file="$IMG",format=raw,if=none,id=hd0 \
            -device virtio-blk-device,drive=hd0 \
            --no-reboot
        ;;
    aarch64-raspi3b)
        $QEMU_AARCH64 -machine raspi3b -serial mon:stdio -nographic \
            -kernel "$STAGE1" \
            -drive file="$IMG",if=sd,format=raw \
            --no-reboot
        ;;
    *)
        echo "error: unsupported arch-board: ${ARCH}-${BOARD}" >&2
        exit 1
        ;;
esac

# Extract artifact from beginning of disk image
dd if="$IMG" of="$ARTIFACT" bs=1 count="$ARTIFACT_SIZE" status=none
rm -f "$IMG"
