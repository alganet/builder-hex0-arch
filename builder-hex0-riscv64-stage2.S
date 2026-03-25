# SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
# SPDX-License-Identifier: Apache-2.0
#
# Builder-hex0 RISC-V 64-bit Stage 2
#
# A minimal kernel for bootstrapping compilers from source on RISC-V.
# Inspired by builder-hex0 (https://github.com/ironmeld/builder-hex0).
#
# Boot (virt):     qemu-system-riscv64 -machine virt -m 2G -nographic \
#                  -kernel builder-hex0-riscv64-stage1-virt.bin \
#                  -drive file=disk.img,format=raw,if=none,id=hd0 \
#                  -device virtio-blk-device,drive=hd0 --no-reboot
# Boot (sifive_u): qemu-system-riscv64 -machine sifive_u -m 2G -nographic \
#                  -kernel builder-hex0-riscv64-stage1-sifive_u.bin \
#                  -drive file=disk.img,format=raw,if=sd --no-reboot
#
# Compiled by stage 1 from hex0 source on disk to 0x80210000.
# On entry: a0 = next disk sector (filesystem start), a1 = DTB pointer
#
# Memory layout (physical addresses):
#   0x80100000  Sv39 root page table (4KB)
#   0x80210000  Kernel code (base, s2 points here)
#   0x80300000  Kernel global data (variables)
#   0x80400000  Process descriptors (16 x 4096)
#   0x80500000  VirtIO structures (desc/avail/used/buffers)
#   0x80600000  User process area (VA 0x00600000 via Sv39 gigapage)
#   0x90000000  User stack top (VA 0x10000000, grows down)
#   0xA0000000  Scratch buffer (64KB)
#   0xA0010000  stdin device buffer (64KB)
#   0xA0020000  File names (8MB, 8192 entries x 1024 bytes)
#   0xA0820000  File descriptors (512KB, 32768 x 16 bytes)
#   0xA8000000  Kernel stack top (grows down) / sscratch
#   0xB0000000  Saved process memory (bump allocator)
#   0xD4000000  File data (bump allocator, next_file_address)
#
# Sv39 paging (gigapages, root table only):
#   Entry 0: VA 0x00000000-0x3FFFFFFF -> PA 0x80000000 (U|R|W|X|V)
#   Entry 2: VA 0x80000000-0xBFFFFFFF -> PA 0x80000000 (R|W|X|V)
#   Entry 3: VA 0xC0000000-0xFFFFFFFF -> PA 0xC0000000 (R|W|X|V)
#   Kernel disables paging (satp=0) on trap entry, enables before sret
#
# Global data at 0x80300000:
#   +0x000: storage_mmio_base (8 bytes) [VirtIO MMIO or SPI controller base]
#   +0x008: virtio_struct_base (8 bytes) [VirtIO only]
#   +0x010: next_filenum (8 bytes)
#   +0x018: next_file_address (8 bytes)
#   +0x020: next_process_num (8 bytes)
#   +0x028: next_save_process_address (8 bytes)
#   +0x030: stdin_sector (8 bytes)
#   +0x038: stdin_offset (8 bytes)
#   +0x040: current_brk (8 bytes)  [PA, per-process simplified]
#   +0x048: enable_flush (8 bytes)
#   +0x050: have_userspace (8 bytes)
#   +0x058: cmd_args (3x8: argv[0], argv[1], NULL)
#   +0x070: cmd_env (1x8: NULL)
#   +0x078: satp_value (8 bytes)
#   +0x080: dtb_pointer (8 bytes)
#   +0x088: disk_read_fn (8 bytes)   [function pointer, set by storage driver]
#   +0x090: disk_write_fn (8 bytes)  [function pointer, set by storage driver]
#   +0x098: spi_base (8 bytes)       [SPI+SD only, used by spi_transfer]
#
# Process descriptor (4096 bytes each, at 0x80400000):
#   +0x000: process_address (8)
#   +0x008: brk (8)
#   +0x010: saved_stack_pointer (8) [return-to-shell]
#   +0x018: saved_stack_pointer_fork (8)
#   +0x020: forked (8)
#   +0x028: saved_brk (8)
#   +0x030: child_exit_code (8)
#   +0x038: saved_process_mem_addr (8)
#   +0x040: saved_process_mem_len (8)
#   +0x048: saved_stack_addr (8)
#   +0x050: saved_stack_len (8)
#   +0x100: current_dir (256 bytes, null-terminated, trailing /)
#   +0x200: open_files (448 entries x 8 bytes)
#            each: global_file_index(4), current_offset(4)
#
# Global file descriptor table (16 bytes each, at 0x81000000):
#   +0x00: file_address (8)
#   +0x08: file_length (8)
#
# File names table (1024 bytes each, at 0x80800000):
#   Null-terminated absolute paths
#
# VirtIO structures at 0x80500000:
#   +0x0000: Descriptor table (8 entries x 16 bytes = 128)
#   +0x0080: Available ring (flags + idx + 8 entries = 22 bytes)
#   +0x1000: Used ring (flags + idx + 8 entries = 68 bytes)
#   +0x2000: Request header (16 bytes)
#   +0x2010: Status byte
#   +0x3000: Sector buffer (512 bytes)
#
# Register conventions:
#   s2 = RAM base (0x80210000), set during boot
#   s3 = VirtIO MMIO base, available during boot
#   s4 = VirtIO struct base (0x80500000), available during boot
#   s5 = global data base (0x80300000), available during boot
#   sp = kernel stack pointer (in sscratch during U-mode)
#
# Trap handler at offset 4 from binary start

_start:
    jal zero, main

#============================================================
# Trap handler (at offset 4 = address 0x80210004)
# Entered on ecall from U-mode (scause = 8)
#============================================================
trap_handler:
    # Swap sp and sscratch: sp = kernel sp, sscratch = user sp
    csrrw sp, sscratch, sp
    # Disable paging (kernel operates on physical addresses)
    csrrw zero, satp, zero
    sfence.vma
    # Quick sanity: if sp < 0x80000000, sscratch was wrong
    lui t0, 0x40000
    slli t0, t0, 1           # 0x80000000
    bgeu sp, t0, trap_sp_ok
    # Bad sp! sp = old sscratch (bad kernel sp?), sscratch = old user sp
    # Save bad sp value before overwriting
    mv t1, sp                # t1 = bad sscratch value (sp after swap)
    # Set sp to a safe kernel stack area: 0xA7F00000
    lui t0, 0x53F80
    slli sp, t0, 1           # sp = 0xA7F00000
    addi sp, sp, -64
    sd ra, 0(sp)
    sd s0, 8(sp)
    sd s1, 16(sp)
    mv s0, t1                # s0 = bad sscratch value
    csrrs s1, sscratch, zero # s1 = old user sp
    j reboot
trap_sp_ok:
    # Allocate trap frame (256 bytes = 32 slots of 8 bytes)
    addi sp, sp, -256
    # Save t0 first (we use it as scratch for CSR reads)
    sd t0, 32(sp)
    # Save user sp (from sscratch) into frame
    csrrs t0, sscratch, zero
    sd t0, 8(sp)
    # Save sepc into frame
    csrrs t0, sepc, zero
    sd t0, 248(sp)
    # Save remaining registers
    sd ra, 0(sp)
    sd gp, 16(sp)
    sd tp, 24(sp)
    # t0 already saved at 32
    sd t1, 40(sp)
    sd t2, 48(sp)
    sd s0, 56(sp)
    sd s1, 64(sp)
    sd a0, 72(sp)
    sd a1, 80(sp)
    sd a2, 88(sp)
    sd a3, 96(sp)
    sd a4, 104(sp)
    sd a5, 112(sp)
    sd a6, 120(sp)
    sd a7, 128(sp)
    sd s2, 136(sp)
    sd s3, 144(sp)
    sd s4, 152(sp)
    sd s5, 160(sp)
    sd s6, 168(sp)
    sd s7, 176(sp)
    sd s8, 184(sp)
    sd s9, 192(sp)
    sd s10, 200(sp)
    sd s11, 208(sp)
    sd t3, 216(sp)
    sd t4, 224(sp)
    sd t5, 232(sp)
    sd t6, 240(sp)

    # Check scause == 8 (ecall from U-mode)
    csrrs t0, scause, zero
    li t1, 8
    beq t0, t1, dispatch

    # Not ecall from U-mode: terminate process with exit code 139
    li t0, 139
    sd t0, 72(sp)
    j syscall_exit

# Dispatch syscall based on a7
dispatch:
    ld a7, 128(sp)

    # All dispatch uses trampolines (J-type, ±1MB range)
    li t1, 64
    beq a7, t1, tramp_write
    li t1, 93
    beq a7, t1, tramp_exit
    li t1, 214
    beq a7, t1, tramp_brk
    li t1, 63
    beq a7, t1, tramp_read
    li t1, 56
    beq a7, t1, tramp_openat
    li t1, 57
    beq a7, t1, tramp_close
    li t1, 62
    beq a7, t1, tramp_lseek
    li t1, 49
    beq a7, t1, tramp_chdir
    li t1, 17
    beq a7, t1, tramp_getcwd
    li t1, 48
    beq a7, t1, tramp_faccessat
    li t1, 34
    beq a7, t1, tramp_mkdirat
    li t1, 220
    beq a7, t1, tramp_clone
    li t1, 221
    beq a7, t1, tramp_execve
    li t1, 95
    beq a7, t1, tramp_waitid
    li t1, 260
    beq a7, t1, tramp_wait4
    li t1, 96
    beq a7, t1, tramp_stub
    li t1, 29
    beq a7, t1, tramp_stub
    li t1, 53
    beq a7, t1, tramp_stub

    # Unknown syscall
    li t0, -1
    sd t0, 72(sp)
    j trap_exit

# Trampolines (J-type, ±1MB range)
tramp_write:
    j syscall_write
tramp_exit:
    j syscall_exit
tramp_brk:
    j syscall_brk
tramp_read:
    j syscall_read
tramp_openat:
    j syscall_openat
tramp_close:
    j syscall_close
tramp_lseek:
    j syscall_lseek
tramp_chdir:
    j syscall_chdir
tramp_getcwd:
    j syscall_getcwd
tramp_faccessat:
    j syscall_faccessat
tramp_mkdirat:
    j syscall_mkdirat
tramp_clone:
    j syscall_clone
tramp_execve:
    j syscall_execve
tramp_waitid:
    j syscall_waitid
tramp_wait4:
    j syscall_wait4
tramp_stub:
    j syscall_stub_zero

#============================================================
# trap_exit: Restore all registers and sret
#============================================================
trap_exit:
    # Restore sepc (incremented by 4 to skip ecall)
    ld t0, 248(sp)
    addi t0, t0, 4
    csrrw zero, sepc, t0
    # Restore user sp to sscratch
    ld t0, 8(sp)
    csrrw zero, sscratch, t0
    # Enable paging before returning to user mode
    # (kernel code+stack are identity-mapped via gigapage 2, so this is safe)
    lui t0, 0x40180
    slli t0, t0, 1            # 0x80300000 globals
    ld t0, 0x78(t0)           # satp_value
    csrrw zero, satp, t0
    sfence.vma
    # Restore all registers
    ld ra, 0(sp)
    ld gp, 16(sp)
    ld tp, 24(sp)
    ld t0, 32(sp)
    ld t1, 40(sp)
    ld t2, 48(sp)
    ld s0, 56(sp)
    ld s1, 64(sp)
    ld a0, 72(sp)
    ld a1, 80(sp)
    ld a2, 88(sp)
    ld a3, 96(sp)
    ld a4, 104(sp)
    ld a5, 112(sp)
    ld a6, 120(sp)
    ld a7, 128(sp)
    ld s2, 136(sp)
    ld s3, 144(sp)
    ld s4, 152(sp)
    ld s5, 160(sp)
    ld s6, 168(sp)
    ld s7, 176(sp)
    ld s8, 184(sp)
    ld s9, 192(sp)
    ld s10, 200(sp)
    ld s11, 208(sp)
    ld t3, 216(sp)
    ld t4, 224(sp)
    ld t5, 232(sp)
    ld t6, 240(sp)
    # Deallocate frame
    addi sp, sp, 256
    # Swap back: sp = user sp, sscratch = kernel sp
    csrrw sp, sscratch, sp
    # Return to user mode
    sret

#============================================================
# syscall_write: write(fd, buf, count) -> count
# a0(72)=fd, a1(80)=buf, a2(88)=count
#============================================================
syscall_write:
    # Load args from trap frame
    ld s3, 72(sp)           # fd
    ld s4, 80(sp)           # buf (VA)
    ld s5, 88(sp)           # count
    mv s6, s5               # save original count

    # Translate buf VA -> PA
    lui t0, 0x40000
    slli t0, t0, 1          # 0x80000000
    add s4, s4, t0

    # If fd <= 2, write to console
    li t0, 3
    blt s3, t0, write_console
    j write_file

write_console:
write_loop:
    beqz s5, write_done
    lbu a0, 0(s4)
    call sbi_putchar
    addi s4, s4, 1
    addi s5, s5, -1
    j write_loop

write_done:
    sd s6, 72(sp)
    j trap_exit

write_file:
    # s3=fd, s4=buf, s5=count, s6=original count
    # Get file info from process fd table
    mv a0, s3
    call fd_to_file_index
    mv s7, a0                # s7 = global file index

    # Get file_address and file_length from global descriptor
    lui t0, 0x50410
    slli t0, t0, 1           # 0x81000000
    slli t1, s7, 4           # index * 16
    add s8, t0, t1           # s8 = &global_fd[file_index]
    ld s9, 0(s8)             # file_address
    ld s10, 8(s8)            # file_length

    # Get current_offset from process fd
    call get_process_base
    addi a0, a0, 0x200
    slli t0, s3, 3
    add s11, a0, t0          # s11 = &open_files[fd]
    lwu s3, 4(s11)           # current_offset (reuse s3, fd no longer needed)

write_file_loop:
    beqz s5, write_file_done

    # Copy byte from user buf to file
    lbu t0, 0(s4)
    add t1, s9, s3           # dest = file_address + offset
    sb t0, 0(t1)


    addi s4, s4, 1
    addi s3, s3, 1           # offset++
    addi s5, s5, -1

    # If offset > file_length, extend file
    bge s10, s3, write_file_loop

    # Extend: file_length = offset
    mv s10, s3
    sd s10, 8(s8)            # update file_length

    # Also advance next_file_address
    lui t0, 0x40180
    slli t0, t0, 1
    ld t1, 0x18(t0)
    addi t1, t1, 1
    sd t1, 0x18(t0)          # next_file_address++

    j write_file_loop

write_file_done:
    # Update current_offset in process fd
    sw s3, 4(s11)
    # Return original count
    sd s6, 72(sp)
    j trap_exit

#============================================================
# syscall_brk: brk(addr) -> addr
# a0(72)=addr. If addr==0, return current brk.
# brk stored in global data at offset 0x40
#============================================================
syscall_brk:
    ld t0, 72(sp)           # requested addr (VA, or 0)

    # Global data at 0x80300000
    lui t1, 0x40180
    slli t1, t1, 1           # t1 = 0x80300000
    ld t2, 0x40(t1)          # current brk (PA)

    beqz t0, brk_return_current

    # Convert VA to PA: PA = VA + 0x80000000
    lui t3, 0x40000
    slli t3, t3, 1
    add t0, t0, t3           # PA = new brk

    # Zero memory from old brk to new brk if extending
    bge t2, t0, brk_store    # skip if shrinking or same
    mv t4, t2                # t4 = cursor = old brk (PA)
brk_zero_loop:
    bge t4, t0, brk_store
    sb zero, 0(t4)
    addi t4, t4, 1
    j brk_zero_loop

brk_store:
    sd t0, 0x40(t1)          # store new brk (PA)
    # Return VA to user
    sub t0, t0, t3
    sd t0, 72(sp)
    j trap_exit

brk_return_current:
    # Return current brk as VA = PA - 0x80000000
    lui t3, 0x40000
    slli t3, t3, 1
    sub t2, t2, t3
    sd t2, 72(sp)
    j trap_exit

#============================================================
# syscall_read: read(fd, buf, count) -> bytes_read
# a0(72)=fd, a1(80)=buf, a2(88)=count
# fd 0 = stdin (from disk via VirtIO)
#============================================================
syscall_read:
    ld s3, 72(sp)           # fd
    ld s4, 80(sp)           # buf (VA)
    ld s5, 88(sp)           # count
    mv s6, s5               # save original count

    # Translate buf VA -> PA
    lui t0, 0x40000
    slli t0, t0, 1
    add s4, s4, t0

    bnez s3, read_file       # if fd != 0, read from file

    # Read from stdin (disk)
read_stdin_loop:
    beqz s5, read_stdin_done

    # Load global data base
    lui t0, 0x40180
    slli t0, t0, 1           # t0 = 0x80300000
    ld t1, 0x30(t0)          # stdin_sector
    ld t2, 0x38(t0)          # stdin_offset

    # Check if we need to read a new sector
    # stdin buffer at 0x80700000
    lui a0, 0x50008
    slli a0, a0, 1           # a0 = 0xA0010000

    # If offset >= 512, read next sector
    li t3, 512
    blt t2, t3, read_stdin_have_data

    # Read next sector
    mv a0, t1                # sector number
    lui a1, 0x50008
    slli a1, a1, 1           # buffer = 0xA0010000
    call disk_read_sector
    # Advance sector, reset offset
    lui t0, 0x40180
    slli t0, t0, 1
    ld t1, 0x30(t0)
    addi t1, t1, 1
    sd t1, 0x30(t0)          # stdin_sector++
    sd zero, 0x38(t0)        # stdin_offset = 0
    li t2, 0                 # t2 = offset = 0

read_stdin_have_data:
    # Read one byte from stdin buffer
    lui a0, 0x50008
    slli a0, a0, 1           # a0 = 0xA0010000
    add a0, a0, t2           # a0 = buffer + offset
    lbu t3, 0(a0)            # byte

    # Store to user buffer
    sb t3, 0(s4)
    addi s4, s4, 1
    addi s5, s5, -1

    # Update stdin_offset
    lui t0, 0x40180
    slli t0, t0, 1
    ld t2, 0x38(t0)
    addi t2, t2, 1
    sd t2, 0x38(t0)

    j read_stdin_loop

read_stdin_done:
    sd s6, 72(sp)            # return original count
    j trap_exit

read_file:
    # s3=fd, s4=buf, s5=count
    # Get file info from process fd table
    mv a0, s3
    call fd_to_file_index
    mv s7, a0                # s7 = global file index

    # Get file_address and file_length from global descriptor
    lui t0, 0x50410
    slli t0, t0, 1           # 0x81000000
    slli t1, s7, 4
    add t0, t0, t1
    ld s8, 0(t0)             # file_address
    ld s9, 8(t0)             # file_length

    # Get current_offset from process fd
    call get_process_base
    addi a0, a0, 0x200
    slli t0, s3, 3
    add s10, a0, t0          # s10 = &open_files[fd]
    lwu s11, 4(s10)          # current_offset

    # Read loop
    li s6, 0                 # bytes read


read_file_loop:
    beqz s5, read_file_done
    # Check if offset >= length (EOF)
    bge s11, s9, read_file_done

    # Copy one byte
    add t0, s8, s11          # src = file_address + offset
    lbu t1, 0(t0)
    sb t1, 0(s4)
    addi s4, s4, 1
    addi s11, s11, 1
    addi s5, s5, -1
    addi s6, s6, 1
    j read_file_loop

read_file_done:
    # Update current_offset
    sw s11, 4(s10)


    # Return bytes read
    sd s6, 72(sp)
    j trap_exit

#============================================================
# syscall_openat: openat(dirfd, pathname, flags, mode)
# a0(72)=dirfd(ignored), a1(80)=pathname, a2(88)=flags
# Returns: fd number or -1
#============================================================
syscall_openat:
    ld s3, 80(sp)            # pathname (a1, VA)
    ld s4, 88(sp)            # flags (a2)

    # Translate pathname VA -> PA
    lui t0, 0x40000
    slli t0, t0, 1
    add s3, s3, t0

    # Resolve to absolute path
    mv a0, s3
    call absolute_path
    mv s3, a0                # s3 = absolute path in scratch buffer

    # Check O_CREAT (bit 6 = 0x40)
    andi t0, s4, 0x40
    bnez t0, openat_create

    # Open existing file
    mv a0, s3
    call find_file
    bltz a0, openat_fail
    mv s5, a0                # s5 = file index

    j openat_alloc_fd

openat_create:
    # Check parent directory exists
    # Find last '/' in path
    mv t0, s3
    mv t1, s3                # t1 = last slash position (default: start)
openat_find_slash:
    lbu t2, 0(t0)
    beqz t2, openat_check_parent
    li t3, 0x2F
    bne t2, t3, openat_next_char
    mv t1, t0
openat_next_char:
    addi t0, t0, 1
    j openat_find_slash

openat_check_parent:
    # If slash is first char, parent is root (always exists)
    beq t1, s3, openat_do_create

    # Temporarily null-terminate at last slash
    mv s7, t1                # save slash position (t1 is caller-saved)
    lbu s6, 0(s7)
    sb zero, 0(s7)
    mv a0, s3
    call find_file
    sb s6, 0(s7)             # restore slash (s7 survives call)
    bltz a0, openat_fail

openat_do_create:
    # Allocate new file entry
    lui t0, 0x40180
    slli t0, t0, 1           # globals base
    ld s5, 0x10(t0)          # s5 = next_filenum (our new file index)

    # Copy filename to file names table
    # dest = 0x80800000 + s5 * 1024
    lui t1, 0x50010
    slli t1, t1, 1           # 0x80800000
    slli t2, s5, 10
    add t1, t1, t2           # destination
    mv t2, s3                # source
openat_copy_name:
    lbu t3, 0(t2)
    sb t3, 0(t1)
    beqz t3, openat_name_done
    addi t1, t1, 1
    addi t2, t2, 1
    j openat_copy_name
openat_name_done:

    # Set up global file descriptor
    # fd_entry = 0x81000000 + s5 * 16
    lui t0, 0x50410
    slli t0, t0, 1           # 0x81000000
    slli t1, s5, 4
    add t0, t0, t1

    # file_address = next_file_address
    lui t1, 0x40180
    slli t1, t1, 1
    ld t2, 0x18(t1)          # next_file_address
    sd t2, 0(t0)             # store file_address
    sd zero, 8(t0)           # file_length = 0

    # Increment next_filenum
    ld t2, 0x10(t1)
    addi t2, t2, 1
    sd t2, 0x10(t1)

openat_alloc_fd:
    # Allocate a process fd slot (start from fd 4)
    call get_process_base
    addi a0, a0, 0x200       # open_files array
    li t0, 4                 # start fd
    li t1, 448               # max entries
openat_find_fd:
    bge t0, t1, openat_fail
    slli t2, t0, 3           # fd * 8
    add t2, a0, t2
    lw t3, 0(t2)             # global_file_index
    beqz t3, openat_got_fd
    addi t0, t0, 1
    j openat_find_fd

openat_got_fd:
    # Store file index and reset offset
    sw s5, 0(t2)             # global_file_index
    sw zero, 4(t2)           # current_offset = 0
    # Return fd
    sd t0, 72(sp)
    j trap_exit

openat_fail:
    li t0, -1
    sd t0, 72(sp)
    j trap_exit

#============================================================
# syscall_close: close(fd) -> 0
# a0(72)=fd
#============================================================
syscall_close:
    ld s3, 72(sp)

    call get_process_base
    addi a0, a0, 0x200       # open_files
    slli t0, s3, 3
    add a0, a0, t0
    sw zero, 0(a0)           # clear slot (mark free)

    sd zero, 72(sp)          # return 0
    j trap_exit

#============================================================
# syscall_lseek: lseek(fd, offset, whence) -> new_offset
# a0(72)=fd, a1(80)=offset, a2(88)=whence
# whence: 0=SEEK_SET, 1=SEEK_CUR, 2=SEEK_END
#============================================================
syscall_lseek:
    ld s3, 72(sp)            # fd
    ld s4, 80(sp)            # offset
    ld s5, 88(sp)            # whence

    call get_process_base
    addi a0, a0, 0x200
    slli t0, s3, 3
    add s6, a0, t0           # s6 = &open_files[fd]

    # SEEK_SET (whence == 0)
    bnez s5, lseek_not_set
    sw s4, 4(s6)
    sd s4, 72(sp)
    j trap_exit

lseek_not_set:
    li t0, 1
    bne s5, t0, lseek_end

    # SEEK_CUR (whence == 1)
    lwu t0, 4(s6)
    add t0, t0, s4
    sw t0, 4(s6)
    sd t0, 72(sp)
    j trap_exit

lseek_end:
    # SEEK_END (whence == 2)
    lw t0, 0(s6)             # global file index
    lui t1, 0x50410
    slli t1, t1, 1           # 0x81000000
    slli t2, t0, 4
    add t1, t1, t2
    ld t0, 8(t1)             # file_length
    add t0, t0, s4           # length + offset
    sw t0, 4(s6)
    sd t0, 72(sp)
    j trap_exit

#============================================================
# syscall_chdir: chdir(path) -> 0 or -1
# a0(72)=path
#============================================================
syscall_chdir:
    ld s3, 72(sp)            # path (VA)

    # Translate VA -> PA
    lui t0, 0x40000
    slli t0, t0, 1
    add s3, s3, t0

    # Resolve to absolute path
    mv a0, s3
    call absolute_path
    mv s3, a0

    # Find the file
    mv a0, s3
    call find_file
    bltz a0, chdir_fail

    # Check it's a directory (file_length == 0)
    lui t0, 0x50410
    slli t0, t0, 1
    slli t1, a0, 4
    add t0, t0, t1
    ld t1, 8(t0)             # file_length
    bnez t1, chdir_fail      # not a directory

    # Copy path to process current_dir
    call get_process_base
    addi s4, a0, 0x100       # dest = proc->current_dir

    mv t0, s3                # source
    mv t1, s4                # dest
    li t3, 0                 # track last char
chdir_copy:
    lbu t2, 0(t0)
    sb t2, 0(t1)
    beqz t2, chdir_check_slash
    mv t3, t2
    addi t0, t0, 1
    addi t1, t1, 1
    j chdir_copy

chdir_check_slash:
    # Append trailing '/' if not present
    li t2, 0x2F
    beq t3, t2, chdir_ok
    sb t2, 0(t1)
    addi t1, t1, 1
    sb zero, 0(t1)
chdir_ok:
    sd zero, 72(sp)          # return 0
    j trap_exit

chdir_fail:
    li t0, -1
    sd t0, 72(sp)
    j trap_exit

#============================================================
# syscall_getcwd: getcwd(buf, size) -> buf or -1
# a0(72)=buf, a1(80)=size
#============================================================
syscall_getcwd:
    ld s3, 72(sp)            # buf (VA)
    ld s4, 80(sp)            # size

    # Translate buf VA -> PA
    lui t0, 0x40000
    slli t0, t0, 1
    add s3, s3, t0

    call get_process_base
    addi a0, a0, 0x100       # current_dir
    mv t0, a0                # src
    mv t1, s3                # dest

    # Check for root "/"
    lbu t2, 0(t0)
    li t3, 0x2F
    bne t2, t3, getcwd_copy
    lbu t2, 1(t0)
    bnez t2, getcwd_copy
    # Root: copy "/" + null
    sb t3, 0(t1)
    sb zero, 1(t1)
    j getcwd_return

getcwd_copy:
    lbu t2, 0(t0)
    beqz t2, getcwd_strip
    sb t2, 0(t1)
    addi t0, t0, 1
    addi t1, t1, 1
    j getcwd_copy

getcwd_strip:
    # Strip trailing '/'
    addi t1, t1, -1
    lbu t2, 0(t1)
    li t3, 0x2F
    bne t2, t3, getcwd_no_strip
    sb zero, 0(t1)
    j getcwd_return
getcwd_no_strip:
    addi t1, t1, 1
    sb zero, 0(t1)

getcwd_return:
    # Return original VA (s3 is PA, convert back to VA)
    lui t0, 0x40000
    slli t0, t0, 1
    sub t0, s3, t0           # VA = PA - 0x80000000
    sd t0, 72(sp)            # return buf (VA)
    j trap_exit

#============================================================
# syscall_faccessat: faccessat(dirfd, pathname, mode, flags)
# a0(72)=dirfd(ignored), a1(80)=pathname
# Returns: 0 if file exists, -1 if not
#============================================================
syscall_faccessat:
    ld s3, 80(sp)            # pathname (a1, VA)

    # Translate VA -> PA
    lui t0, 0x40000
    slli t0, t0, 1
    add s3, s3, t0

    mv a0, s3
    call absolute_path
    call find_file

    bltz a0, faccessat_fail
    sd zero, 72(sp)          # return 0
    j trap_exit
faccessat_fail:
    li t0, -1
    sd t0, 72(sp)
    j trap_exit

#============================================================
# syscall_mkdirat: mkdirat(dirfd, pathname, mode)
# a0(72)=dirfd(ignored), a1(80)=pathname
# Creates a zero-length file entry (= directory)
# Returns: 0 on success, -1 on failure
#============================================================
syscall_mkdirat:
    ld s3, 80(sp)            # pathname (a1, VA)

    # Translate VA -> PA
    lui t0, 0x40000
    slli t0, t0, 1
    add s3, s3, t0

    # Resolve to absolute path
    mv a0, s3
    call absolute_path
    mv s3, a0

    # Check parent directory exists (find last '/')
    mv t0, s3
    mv t1, s3                # default last slash = start
mkdirat_find_slash:
    lbu t2, 0(t0)
    beqz t2, mkdirat_check_parent
    li t3, 0x2F
    bne t2, t3, mkdirat_next_char
    mv t1, t0
mkdirat_next_char:
    addi t0, t0, 1
    j mkdirat_find_slash

mkdirat_check_parent:
    beq t1, s3, mkdirat_do_create   # root parent always exists

    mv s7, t1                # save slash position (t1 is caller-saved)
    lbu s6, 0(s7)
    sb zero, 0(s7)
    mv a0, s3
    call find_file
    sb s6, 0(s7)             # restore slash (s7 survives call)
    bltz a0, mkdirat_fail

mkdirat_do_create:
    # Allocate new file entry
    lui t0, 0x40180
    slli t0, t0, 1
    ld s5, 0x10(t0)          # next_filenum

    # Copy name to file names table
    lui t1, 0x50010
    slli t1, t1, 1           # 0x80800000
    slli t2, s5, 10
    add t1, t1, t2
    mv t2, s3
mkdirat_copy_name:
    lbu t3, 0(t2)
    sb t3, 0(t1)
    beqz t3, mkdirat_name_done
    addi t1, t1, 1
    addi t2, t2, 1
    j mkdirat_copy_name
mkdirat_name_done:

    # Set up global file descriptor (length = 0 = directory)
    lui t0, 0x50410
    slli t0, t0, 1
    slli t1, s5, 4
    add t0, t0, t1
    lui t1, 0x40180
    slli t1, t1, 1
    ld t2, 0x18(t1)          # next_file_address
    sd t2, 0(t0)             # file_address
    sd zero, 8(t0)           # file_length = 0

    # Increment next_filenum
    ld t2, 0x10(t1)
    addi t2, t2, 1
    sd t2, 0x10(t1)

    sd zero, 72(sp)          # return 0
    j trap_exit

mkdirat_fail:
    li t0, -1
    sd t0, 72(sp)
    j trap_exit

#============================================================
# syscall_stub_zero: Return 0 for unimplemented stubs
#============================================================
syscall_stub_zero:
    sd zero, 72(sp)
    j trap_exit

#============================================================
# syscall_clone: clone/fork simulation
# Saves parent state, returns 0 (as child). Parent resumes
# when child calls exit, returning 1.
#============================================================
syscall_clone:
    # Get current process descriptor
    call get_process_base
    mv s3, a0                # s3 = proc base

    # Save brk to saved_brk (+0x28)
    lui t0, 0x40180
    slli t0, t0, 1
    ld t1, 0x40(t0)          # current brk (PA)
    sd t1, 0x28(s3)          # saved_brk

    # Save kernel sp to saved_stack_pointer_fork (+0x18)
    # (sp is the kernel stack after trap frame allocation)
    sd sp, 0x18(s3)

    # Set forked flag (+0x20)
    ld t0, 0x20(s3)
    addi t0, t0, 1
    sd t0, 0x20(s3)

    # Save stack: copy from sp to kernel_stack_top (0xA8000000)
    lui t0, 0x54000
    slli t0, t0, 1           # t0 = 0xA8000000 (stack top)
    sub t1, t0, sp           # t1 = stack length

    # Get save address from next_save_process_address
    lui t0, 0x40180
    slli t0, t0, 1
    ld s4, 0x28(t0)          # next_save_process_address
    sd s4, 0x48(s3)          # save stack save address

    lui t0, 0x54000
    slli t0, t0, 1
    sub t1, t0, sp           # stack length
    sd t1, 0x50(s3)          # save stack length

    # Copy stack to save area
    mv a0, s4                # dest = save area
    mv a1, sp                # src = current sp
    mv a2, t1                # len
    call memcpy

    # Advance next_save_process_address
    lui t0, 0x40180
    slli t0, t0, 1
    ld t1, 0x28(t0)
    ld t2, 0x50(s3)          # stack length
    add t1, t1, t2
    sd t1, 0x28(t0)

    # Save process memory: from process_address to brk
    ld s5, 0(s3)             # process_address (PA)
    ld s6, 0x40(s3)          # brk (PA) - wait, brk is in globals
    lui t0, 0x40180
    slli t0, t0, 1
    ld s6, 0x40(t0)          # brk (PA)
    sub t1, s6, s5           # process memory length
    sd t1, 0x40(s3)          # save process mem length (reuse +0x40? No...)
    # Actually use dedicated fields: +0x38 = saved_process_mem_addr, +0x40 = saved_process_mem_len
    # But +0x40 is brk in the plan... Let me re-check the layout.
    # Plan says: +0x038: saved_process_mem_addr, +0x040: saved_process_mem_len
    # But brk is in globals at 0x80300040, not in process descriptor.
    # So +0x040 in proc descriptor is saved_process_mem_len. OK.

    # Get save address
    lui t0, 0x40180
    slli t0, t0, 1
    ld s7, 0x28(t0)          # next save addr
    sd s7, 0x38(s3)          # saved_process_mem_addr

    sub a2, s6, s5           # length
    sd a2, 0x40(s3)          # saved_process_mem_len

    # Copy process memory
    mv a0, s7                # dest
    mv a1, s5                # src = process_address (PA)
    call memcpy

    # Advance next_save_process_address
    lui t0, 0x40180
    slli t0, t0, 1
    ld t1, 0x28(t0)
    ld t2, 0x40(s3)          # process mem length
    add t1, t1, t2
    sd t1, 0x28(t0)

    # Save user stack: from user sp (PA) to 0x90000000
    # User sp is in the trap frame at offset 8
    ld s5, 8(sp)             # user sp (VA)
    lui t0, 0x40000
    slli t0, t0, 1
    add s5, s5, t0           # user sp (PA) = VA + 0x80000000

    lui t0, 0x48000
    slli t0, t0, 1           # t0 = 0x90000000 (user stack top PA)
    sub s6, t0, s5           # user stack length

    # Get save address
    lui t0, 0x40180
    slli t0, t0, 1
    ld s7, 0x28(t0)          # next save addr
    sd s7, 0x58(s3)          # saved_user_stack_addr
    sd s6, 0x60(s3)          # saved_user_stack_len

    # Copy user stack to save area
    mv a0, s7                # dest
    mv a1, s5                # src = user sp (PA)
    mv a2, s6                # len
    call memcpy

    # Advance next_save_process_address
    lui t0, 0x40180
    slli t0, t0, 1
    ld t1, 0x28(t0)
    add t1, t1, s6
    sd t1, 0x28(t0)

    # Return 0 (child return from fork)
    sd zero, 72(sp)
    j trap_exit

#============================================================
# syscall_execve: execve(pathname, argv, envp)
# a0(72)=pathname, a1(80)=argv, a2(88)=envp
# Loads 64-bit ELF, sets up process, jumps to entry
#============================================================
syscall_execve:
    ld s3, 72(sp)            # pathname (VA)
    ld s4, 80(sp)            # argv (VA)
    ld s5, 88(sp)            # envp (VA)

    # Translate all pointers VA -> PA
    lui t0, 0x40000
    slli t0, t0, 1
    add s3, s3, t0
    add s4, s4, t0
    add s5, s5, t0

    # Check if current process forked (check BEFORE first-process check)
    call get_process_base
    mv s6, a0                # current proc
    ld t0, 0x20(s6)          # forked flag
    bnez t0, execve_forked

    # Not forked: check if first process (direct exec from shell)
    lui t0, 0x40180
    slli t0, t0, 1
    ld t1, 0x20(t0)          # next_process_num
    li t2, 1
    bne t1, t2, execve_overlay

    # First process: save original sp at proc[1]+0x10
    lui t0, 0x40200
    slli t0, t0, 1           # 0x80400000
    lui t1, 1                # 0x1000
    add t0, t0, t1           # proc[1] = 0x80401000
    sd sp, 0x10(t0)          # save kernel sp for return-to-shell
    j execve_prepare_stack

execve_forked:
    # Forked: create new process after fork
    # Decrement forked flag
    addi t0, t0, -1
    sd t0, 0x20(s6)
    j execve_prepare_stack

execve_overlay:
    # Not forked, not first: overlay current process (same slot)
    j execve_prepare_stack

execve_prepare_stack:
    # Set up user stack at PA 0x90000000 (VA 0x10000000)
    # Push envp strings, then argv strings, then pointers, then argc

    # First, count argc
    mv t0, s4                # argv
    li s7, 0                 # argc
    # VA range limit: 0x40000000 (1GB, matches page table entry 0)
    lui t2, 0x40000          # t2 = 0x40000000
execve_count_args:
    ld t1, 0(t0)
    beqz t1, execve_counted
    bgeu t1, t2, execve_counted  # pointer out of valid VA range -> stop
    addi s7, s7, 1
    addi t0, t0, 8
    j execve_count_args
execve_counted:

    # String storage on user stack, growing DOWN from PA 0x90000000.
    # This ensures argv/envp strings are within [user_sp, 0x90000000)
    # and thus saved/restored by clone, preventing corruption when
    # child processes overwrite argv strings during their own execve.
    lui t0, 0x48000
    slli s9, t0, 1           # s9 = 0x90000000 (string storage PA, grows down)

    # ---- Phase 1: Copy argv strings ----
    # Temp argv VA array at PA 0xA0001000
    lui t0, 0x50000
    slli t0, t0, 1
    lui t1, 1
    add s10, t0, t1          # s10 = 0xA0001000 (temp VA array)

    mv s11, s4               # s11 = argv array iterator (PA)
    mv s6, s7                # s6 = argc (from count loop)
    li s7, 0                 # copy counter
execve_copy_argv:
    bge s7, s6, execve_argv_done
    ld t1, 0(s11)            # argv[i] pointer (VA)
    beqz t1, execve_argv_done

    # Translate argv[i] VA -> PA
    lui t2, 0x40000
    slli t2, t2, 1
    add a1, t1, t2           # src (PA)

    # Allocate string slot on user stack (grow down)
    addi s9, s9, -256
    # Copy string from a1 to s9 (256 bytes max)
    mv a0, s9                # dest (PA)
    li a2, 256
    call memcpy

    # Calculate VA for this string: VA = PA - 0x80000000
    lui t1, 0x40000
    slli t1, t1, 1
    sub t1, s9, t1           # VA

    # Store VA in temp array
    slli t2, s7, 3
    add t2, s10, t2
    sd t1, 0(t2)

    addi s7, s7, 1
    addi s11, s11, 8
    j execve_copy_argv

execve_argv_done:
    mv s6, s7                # s6 = argc (final)

    # ---- Phase 2: Copy envp strings ----
    # Temp envp VA array at PA 0xA0002000
    lui t0, 0x50000
    slli t0, t0, 1
    lui t1, 2
    add s10, t0, t1          # s10 = 0xA0002000

    mv s11, s5               # s11 = envp array iterator (PA)
    li s7, 0                 # envc counter
execve_copy_envp:
    ld t1, 0(s11)            # envp[i] pointer (VA)
    beqz t1, execve_envp_done
    lui t2, 0x40000
    bgeu t1, t2, execve_envp_done  # out of valid VA range

    # Translate VA -> PA
    lui t2, 0x40000
    slli t2, t2, 1
    add a1, t1, t2           # src (PA)

    # Allocate string slot on user stack (grow down)
    addi s9, s9, -256
    mv a0, s9                # dest (PA)
    li a2, 256
    call memcpy

    lui t1, 0x40000
    slli t1, t1, 1
    sub t1, s9, t1           # VA

    slli t2, s7, 3
    add t2, s10, t2
    sd t1, 0(t2)

    addi s7, s7, 1
    addi s11, s11, 8
    j execve_copy_envp

execve_envp_done:
    # s6 = argc, s7 = envc
    # Save envc to stack for later
    addi sp, sp, -8
    sd s7, 0(sp)             # save envc

    # ---- Phase 3: Build stack ----
    # s9 is now below all strings on the user stack.
    # Set s8 = s9 so the pointer/argc area grows below the strings.
    mv s8, s9

    # Stack layout (low addr to high addr, sp points to lowest):
    #   argc, argv[0]..argv[argc-1], NULL, envp[0]..envp[envc-1], NULL, strings...

    # Push NULL (envp terminator)
    addi s8, s8, -8
    sd zero, 0(s8)

    # Push envp pointers in reverse order
    ld t0, 0(sp)             # t0 = envc
    lui t3, 0x50000
    slli t3, t3, 1
    lui t4, 2
    add t3, t3, t4           # t3 = 0xA0002000 (envp VA array)
execve_push_envp:
    beqz t0, execve_push_envp_done
    addi t0, t0, -1
    slli t1, t0, 3
    add t1, t3, t1
    ld t1, 0(t1)             # VA
    addi s8, s8, -8
    sd t1, 0(s8)
    j execve_push_envp
execve_push_envp_done:
    addi sp, sp, 8           # pop saved envc

    # Push NULL (argv terminator)
    addi s8, s8, -8
    sd zero, 0(s8)

    # Push argv pointers in reverse order
    mv t0, s6                # t0 = argc
    lui t3, 0x50000
    slli t3, t3, 1
    lui t4, 1
    add t3, t3, t4           # t3 = 0xA0001000 (argv VA array)
execve_push_argv:
    beqz t0, execve_push_argc
    addi t0, t0, -1
    slli t1, t0, 3
    add t1, t3, t1
    ld t1, 0(t1)             # VA
    addi s8, s8, -8
    sd t1, 0(s8)
    j execve_push_argv

execve_push_argc:
    # Push argc
    addi s8, s8, -8
    sd s6, 0(s8)             # s6 = argc

    # Now s8 = user stack PA. Calculate VA = s8 - 0x80000000
    lui t0, 0x40000
    slli t0, t0, 1
    sub s8, s8, t0           # s8 = user stack VA

    # --- Load ELF ---
    # Resolve program name
    mv a0, s3                # pathname
    call absolute_path
    mv s3, a0
    mv a0, s3
    call find_file
    bltz a0, execve_fail
    mv s9, a0                # s9 = file index

    # Get file address and length
    lui t0, 0x50410
    slli t0, t0, 1           # 0xA0820000 (file descriptors)
    slli t1, s9, 4
    add t0, t0, t1
    ld s10, 0(t0)            # file_address (PA)
    ld s11, 8(t0)            # file_length

    # Increment next_process_num (for new process)
    lui t0, 0x40180
    slli t0, t0, 1
    ld t1, 0x20(t0)
    addi t1, t1, 1
    sd t1, 0x20(t0)

    # Get new process descriptor
    call get_process_base
    mv s6, a0                # s6 = new proc descriptor

    # Copy cwd from previous process
    # Previous process = s6 - 0x1000
    lui t0, 1
    sub t0, s6, t0           # prev proc
    addi t1, t0, 0x100       # prev cwd
    addi t2, s6, 0x100       # new cwd
    li t3, 256
execve_copy_cwd:
    beqz t3, execve_cwd_done
    lbu t4, 0(t1)
    sb t4, 0(t2)
    addi t1, t1, 1
    addi t2, t2, 1
    addi t3, t3, -1
    j execve_copy_cwd
execve_cwd_done:

    # Clear new process open file descriptors
    addi a0, s6, 0x200
    li a1, 0xE00             # 448 * 8 = 3584
    call memset_zero

    # Parse 64-bit ELF header
    # e_entry at offset 0x18 (8 bytes)
    ld s3, 0x18(s10)         # entry point (VA)

    # e_phoff at offset 0x20 (8 bytes)
    ld t0, 0x20(s10)         # program header table offset
    add s4, s10, t0          # s4 = phdr address (PA)

    # e_phnum at offset 0x38 (2 bytes)
    lhu s5, 0x38(s10)        # number of program headers


    # Zero user process area: 2MB starting at PA 0x80600000
    lui a0, 0x40300
    slli a0, a0, 1           # 0x80600000
    lui a1, 0x200             # 0x200000 = 2MB
    call memset_zero

    # Reset brk to process base (will be set properly by phdr loop)
    lui t0, 0x40300
    slli t0, t0, 1           # 0x80600000
    lui t1, 0x40180
    slli t1, t1, 1
    sd t0, 0x40(t1)          # brk = 0x80600000 (reset)

    # Load each program header (56 bytes each for ELF64)
    # p_type at +0x00 (4 bytes), skip if not PT_LOAD (1)
    # p_offset at +0x08 (8 bytes)
    # p_vaddr at +0x10 (8 bytes)
    # p_filesz at +0x20 (8 bytes)

execve_load_phdr:
    beqz s5, execve_load_done

    # Check p_type == PT_LOAD (1)
    lw t0, 0(s4)
    li t1, 1
    bne t0, t1, execve_next_phdr

    ld t0, 0x08(s4)          # p_offset
    add a1, s10, t0          # src = file_address + p_offset

    ld t0, 0x10(s4)          # p_vaddr (VA)
    # Convert VA to PA: PA = VA + 0x80000000
    lui t1, 0x40000
    slli t1, t1, 1
    add a0, t0, t1           # dest = PA

    ld a2, 0x20(s4)          # p_filesz
    call memcpy

    # Track end of loaded segments for brk
    ld t0, 0x10(s4)          # p_vaddr
    ld t1, 0x20(s4)          # p_filesz
    add t0, t0, t1           # end of segment (VA)
    lui t1, 0x40000
    slli t1, t1, 1
    add t0, t0, t1           # end (PA)
    lui t1, 2                # +0x2000 padding
    add t0, t0, t1

    # Set brk = max across segments (end_of_segment + padding)
    lui t1, 0x40180
    slli t1, t1, 1
    ld t2, 0x40(t1)
    bge t2, t0, execve_next_phdr
    sd t0, 0x40(t1)          # update brk

execve_next_phdr:
    addi s4, s4, 56          # next phdr (ELF64: 56 bytes each)
    addi s5, s5, -1
    j execve_load_phdr

execve_load_done:
    # Set process_address in descriptor
    lui t0, 0x40300
    slli t0, t0, 1           # PA 0x80600000
    sd t0, 0(s6)             # process_address = PA of user area

    # Clear forked flag
    sd zero, 0x20(s6)

    # Direct transition to U-mode (like handle_other_command)
    # Deallocate trap frame — we won't use trap_exit
    addi sp, sp, 256

    # Ensure new code is visible (I-cache coherence)
    fence
    fence.i

    # Clear SPP (bit 8), SPIE (bit 5), and SIE (bit 1) in sstatus
    # This prevents interrupts from firing after sret
    li t0, 0x122
    csrrc zero, sstatus, t0

    # Set sepc = entry point VA
    csrrw zero, sepc, s3

    # Set sscratch = sp (current kernel stack pointer)
    csrrw zero, sscratch, sp

    # Enable paging
    lui t0, 0x40180
    slli t0, t0, 1
    ld t0, 0x78(t0)          # satp_value
    csrrw zero, satp, t0
    sfence.vma

    # Set sp = user stack VA and sret
    mv sp, s8
    sret

execve_fail:
    li t0, -1
    sd t0, 72(sp)
    j trap_exit

#============================================================
# syscall_exit: exit(code)
# a0(72)=exit code
# Restores parent process or returns to shell
#============================================================
syscall_exit:
    ld s3, 72(sp)            # exit code

    # Decrement next_process_num
    lui t0, 0x40180
    slli t0, t0, 1
    ld t1, 0x20(t0)
    addi t1, t1, -1
    sd t1, 0x20(t0)          # next_process_num--

    # If returning to shell (next_process_num == 1): no parent clone to restore
    li t2, 1
    beq t1, t2, exit_to_shell

    # Returning to parent after fork
    # Parent saved state at proc[next_process_num - 1] (clone saves at get_process_base)
    addi t2, t1, -1          # parent index
    slli t2, t2, 12          # * 4096
    lui t3, 0x40200
    slli t3, t3, 1           # 0x80400000
    add s4, t3, t2           # s4 = parent proc descriptor

    # Save child exit code
    sd s3, 0x30(s4)          # child_exit_code

    # Restore parent process memory
    ld a0, 0(s4)             # dest = process_address (PA)
    ld a1, 0x38(s4)          # src = saved_process_mem_addr
    ld a2, 0x40(s4)          # len = saved_process_mem_len
    call memcpy

    # Deallocate save area: reset next_save_process_address
    lui t0, 0x40180
    slli t0, t0, 1
    ld t1, 0x48(s4)          # saved stack addr = start of save area
    sd t1, 0x28(t0)          # next_save_process_address = save area start

    # Restore parent brk
    ld t1, 0x28(s4)          # saved_brk
    sd t1, 0x40(t0)          # current_brk

    # Restore parent stack pointer
    ld sp, 0x18(s4)          # saved_stack_pointer_fork

    # Restore parent stack contents
    ld a1, 0x48(s4)          # src = saved stack addr
    mv a0, sp                # dest = sp
    ld a2, 0x50(s4)          # len = saved stack len
    call memcpy

    # Restore parent user stack
    ld a0, 8(sp)             # user sp (VA) from restored trap frame
    lui t0, 0x40000
    slli t0, t0, 1
    add a0, a0, t0           # dest = user sp (PA)
    ld a1, 0x58(s4)          # src = saved_user_stack_addr
    ld a2, 0x60(s4)          # len = saved_user_stack_len
    call memcpy

    # Flush I-cache after restoring parent code/data
    fence.i

    # Return 1 (parent return from fork)
    li t0, 1
    sd t0, 72(sp)            # a0 = 1 in trap frame
    j trap_exit

exit_to_shell:
    # Restore kernel sp from proc[1]+0x10 (fixed location)
    lui t0, 0x40200
    slli t0, t0, 1
    lui t1, 1
    add t0, t0, t1           # proc[1] = 0x80401000
    ld sp, 0x10(t0)

    # Jump to shell_return (disables paging, goes to shell_loop)
    j shell_return

#============================================================
# syscall_waitid: waitid(idtype, id, infop, options, ...)
# Returns child exit code in infop->si_status
# Simplified: just return 0, exit code already stored
#============================================================
syscall_waitid:
    # Get current process descriptor
    call get_process_base
    ld t0, 0x30(a0)          # child_exit_code

    # The infop struct: write status. For Linux compatibility,
    # write exit code to [infop+0x18] (si_status field)
    # But our programs (kaem) check [ecx] on x86, which maps to
    # a1 (infop pointer) on riscv64.
    ld t1, 80(sp)            # a1 = infop (in trap frame, at slot for a1... wait)
    # Actually RISC-V waitid: a0=idtype, a1=id, a2=infop, a3=options
    ld t1, 88(sp)            # a2 = infop (VA)
    beqz t1, waitid_no_write

    # Translate infop VA -> PA
    lui t2, 0x40000
    slli t2, t2, 1
    add t1, t1, t2

    # Write exit code shifted left by 8 (Linux convention)
    slli t0, t0, 8
    sw t0, 0(t1)             # store to infop

waitid_no_write:
    sd zero, 72(sp)          # return 0
    j trap_exit

#============================================================
# syscall_wait4: wait4(pid, wstatus, options, rusage)
# a0(72)=pid, a1(80)=wstatus_ptr, a2(88)=options, a3(96)=rusage
# In our simulation, child already exited. Just write wstatus.
#============================================================
syscall_wait4:
    # Get current process descriptor
    call get_process_base
    ld t0, 0x30(a0)          # child_exit_code

    # Get wstatus pointer (a1)
    ld t1, 80(sp)            # a1 = wstatus (VA)
    beqz t1, wait4_no_write

    # Translate VA -> PA
    lui t2, 0x40000
    slli t2, t2, 1
    add t1, t1, t2

    # Write wstatus = (exit_code << 8) (WIFEXITED=true, WEXITSTATUS=exit_code)
    slli t0, t0, 8
    sw t0, 0(t1)

wait4_no_write:
    # Return child pid (1 = any child)
    li t0, 1
    sd t0, 72(sp)
    j trap_exit

#============================================================
# sbi_putchar: Print character in a0 via SBI legacy ext 0x01
#============================================================
sbi_putchar:
    li a7, 1
    ecall
    ret

#============================================================
# print_hex_nibble: Print nibble (0-15) in a0
#============================================================
print_hex_nibble:
    li t0, 10
    bge a0, t0, print_hex_alpha
    addi a0, a0, 0x30
    j sbi_putchar
print_hex_alpha:
    addi a0, a0, 0x57
    j sbi_putchar

#============================================================
# print_hex_byte: Print byte in a0 as 2 hex digits
#============================================================
print_hex_byte:
    addi sp, sp, -16
    sd ra, 0(sp)
    sd s0, 8(sp)
    mv s0, a0
    srli a0, s0, 4
    andi a0, a0, 0xF
    call print_hex_nibble
    mv a0, s0
    andi a0, a0, 0xF
    call print_hex_nibble
    ld ra, 0(sp)
    ld s0, 8(sp)
    addi sp, sp, 16
    ret

#============================================================
# print_hex32: Print 32-bit value in a0 as 8 hex digits
#============================================================
print_hex32:
    addi sp, sp, -16
    sd ra, 0(sp)
    sd s0, 8(sp)
    mv s0, a0

    srli a0, s0, 28
    andi a0, a0, 0xF
    call print_hex_nibble
    srli a0, s0, 24
    andi a0, a0, 0xF
    call print_hex_nibble
    srli a0, s0, 20
    andi a0, a0, 0xF
    call print_hex_nibble
    srli a0, s0, 16
    andi a0, a0, 0xF
    call print_hex_nibble
    srli a0, s0, 12
    andi a0, a0, 0xF
    call print_hex_nibble
    srli a0, s0, 8
    andi a0, a0, 0xF
    call print_hex_nibble
    srli a0, s0, 4
    andi a0, a0, 0xF
    call print_hex_nibble
    mv a0, s0
    andi a0, a0, 0xF
    call print_hex_nibble

    ld ra, 0(sp)
    ld s0, 8(sp)
    addi sp, sp, 16
    ret

#============================================================
# print_string: Print null-terminated string at a0
#============================================================
print_string:
    addi sp, sp, -16
    sd ra, 0(sp)
    sd s0, 8(sp)
    mv s0, a0
print_string_loop:
    lbu a0, 0(s0)
    beqz a0, print_string_done
    call sbi_putchar
    addi s0, s0, 1
    j print_string_loop
print_string_done:
    ld ra, 0(sp)
    ld s0, 8(sp)
    addi sp, sp, 16
    ret

#============================================================
# load_ram_base: Load 0x80210000 into s2
#============================================================
load_ram_base:
    lui t0, 0x40108
    slli s2, t0, 1
    ret

#============================================================
# load_data_base: Load 0x80300000 into t0
# Returns: t0 = 0x80300000
#============================================================
load_data_base:
    lui t0, 0x40180
    slli t0, t0, 1
    ret

#============================================================
# reboot: SBI SRST cold reboot (via OpenSBI)
# Uses COLD_REBOOT (type 1) instead of SHUTDOWN (type 0) because:
# - All boards have a reboot device (not all have a shutdown device)
# - Reboot is the correct semantic for bootstrapping (boot -> build -> reboot)
# - Tests use --no-reboot so QEMU exits cleanly on reboot
#============================================================
reboot:
    lui a7, 0x53525
    addi a7, a7, 0x354       # a7 = 0x53525354 (SRST EID)
    li a6, 0                 # FID 0 = sbi_system_reset
    li a0, 1                 # type 1 = COLD_REBOOT
    li a1, 0                 # reason 0 = NONE
    ecall
reboot_hang:
    j reboot_hang

#============================================================
# memset_zero: Zero memory from a0 to a0+a1
# a0 = start address, a1 = byte count (must be multiple of 8)
#============================================================
memset_zero:
    beqz a1, memset_done
    sd zero, 0(a0)
    addi a0, a0, 8
    addi a1, a1, -8
    j memset_zero
memset_done:
    ret

#============================================================
# memcpy: Copy memory
# a0 = dest, a1 = src, a2 = byte count
# Returns: a0 = dest (preserved)
#============================================================
memcpy:
    mv t0, a0                # save dest for return
memcpy_loop:
    beqz a2, memcpy_done
    lbu t1, 0(a1)
    sb t1, 0(a0)
    addi a0, a0, 1
    addi a1, a1, 1
    addi a2, a2, -1
    j memcpy_loop
memcpy_done:
    mv a0, t0
    ret

#============================================================
# bswap32: Byte-swap a 32-bit value (big-endian <-> little-endian)
# a0 = input value (only low 32 bits used)
# Returns: a0 = byte-swapped value (zero-extended to 64 bits)
#============================================================
bswap32:
    # Extract bytes and reassemble in reversed order
    # Input:  a0 = [B3 B2 B1 B0] (low 32 bits)
    # Output: a0 = [B0 B1 B2 B3]
    andi t0, a0, 0xFF           # t0 = B0
    slli t0, t0, 24             # t0 = B0 << 24
    srli t1, a0, 8
    andi t1, t1, 0xFF           # t1 = B1
    slli t1, t1, 16             # t1 = B1 << 16
    or t0, t0, t1
    srli t1, a0, 16
    andi t1, t1, 0xFF           # t1 = B2
    slli t1, t1, 8              # t1 = B2 << 8
    or t0, t0, t1
    srli t1, a0, 24
    andi t1, t1, 0xFF           # t1 = B3
    or a0, t0, t1
    ret

#============================================================
# read_stdin_byte: Read one byte from stdin (disk via VirtIO)
# Uses globals: stdin_sector (+0x30), stdin_offset (+0x38)
# Returns: a0 = byte read
# Called from S-mode (internal shell), paging OFF
#============================================================
read_stdin_byte:
    addi sp, sp, -16
    sd ra, 0(sp)
    sd s0, 8(sp)

    # Load global data base
    lui t0, 0x40180
    slli t0, t0, 1           # t0 = 0x80300000
    ld t1, 0x38(t0)          # stdin_offset

    # If offset >= 512, read next sector
    li t2, 512
    blt t1, t2, rsb_have_data

    # Read next sector into stdin buffer at 0xA0010000
    ld a0, 0x30(t0)          # sector number
    lui a1, 0x50008
    slli a1, a1, 1           # buffer = 0xA0010000
    call disk_read_sector

    # Advance sector, reset offset
    lui t0, 0x40180
    slli t0, t0, 1
    ld t1, 0x30(t0)
    addi t1, t1, 1
    sd t1, 0x30(t0)          # stdin_sector++
    sd zero, 0x38(t0)        # stdin_offset = 0
    li t1, 0                 # t1 = offset = 0

rsb_have_data:
    # Read one byte from stdin buffer
    lui s0, 0x50008
    slli s0, s0, 1           # s0 = 0xA0010000
    add s0, s0, t1
    lbu a0, 0(s0)            # byte

    # Update stdin_offset
    lui t0, 0x40180
    slli t0, t0, 1
    ld t1, 0x38(t0)
    addi t1, t1, 1
    sd t1, 0x38(t0)

    ld ra, 0(sp)
    ld s0, 8(sp)
    addi sp, sp, 16
    ret

#============================================================
# setup_page_table: Create Sv39 root page table at PA 0x80100000
# Entry 0: VA 0x00000000-0x3FFFFFFF -> PA 0x80000000 (U|R|W|X|V)
# Entry 2: VA 0x80000000-0xBFFFFFFF -> PA 0x80000000 (R|W|X|V)
# Entry 3: VA 0xC0000000-0xFFFFFFFF -> PA 0xC0000000 (R|W|X|V)
# Also computes and stores satp_value in globals
#============================================================
setup_page_table:
    addi sp, sp, -8
    sd ra, 0(sp)

    # Zero page table (4KB at 0x80100000)
    lui t0, 0x40080
    slli a0, t0, 1              # a0 = 0x80100000
    lui a1, 1                # 4096
    call memset_zero

    # Page table entry format (Sv39 gigapage):
    # PPN[53:10] = PA >> 30 << 28 (for gigapages, PPN[1:0] must be 0)
    # Actually: PTE = (PA >> 12) << 10 | flags
    # For gigapage: PA must be 1GB aligned, PPN = PA >> 12
    # So PTE = (PA >> 2) | flags  ... wait let me think again
    #
    # Sv39 PTE format: [63:54]=reserved, [53:10]=PPN, [9:8]=RSW, [7:0]=DAGUXWRV
    # PPN = phys_addr >> 12  (page number)
    # PTE = PPN << 10 | flags
    # For PA=0x80000000: PPN = 0x80000000 >> 12 = 0x80000
    # PTE = 0x80000 << 10 | flags = 0x20000000 | flags
    #
    # Entry 0: PA=0x80000000, flags=U|X|W|R|V = 0b00011111 = 0x1F
    # PTE = 0x20000000 | 0x1F = 0x2000001F
    lui t1, 0x40080
    slli a0, t1, 1              # a0 = 0x80100000 page table base
    lui t0, 0x20000
    addi t0, t0, 0x1F        # PTE = 0x2000001F
    sd t0, 0(a0)             # entry 0

    # Entry 2: PA=0x80000000, flags=X|W|R|V = 0b00001111 = 0x0F (no U bit)
    # PTE = 0x20000000 | 0x0F = 0x2000000F
    lui t0, 0x20000
    addi t0, t0, 0x0F
    sd t0, 16(a0)            # entry 2 (offset = 2*8 = 16)

    # Entry 3: PA=0xC0000000, flags=X|W|R|V = 0x0F
    # PPN = 0xC0000000 >> 12 = 0xC0000
    # PTE = 0xC0000 << 10 | 0x0F = 0x30000000 | 0x0F = 0x3000000F
    lui t0, 0x30000
    addi t0, t0, 0x0F
    sd t0, 24(a0)            # entry 3 (offset = 3*8 = 24)

    # Compute satp value: mode=8 (Sv39) << 60 | PPN(page_table)
    # PPN = 0x80100000 >> 12 = 0x80100
    # satp = (8 << 60) | 0x80100
    li t0, 8
    slli t0, t0, 60          # mode field
    lui t1, 0x80
    addi t1, t1, 0x100       # PPN = 0x80100
    or t0, t0, t1            # satp = mode | PPN

    # Store in globals at +0x78
    lui t1, 0x40180
    slli t1, t1, 1           # 0x80300000
    sd t0, 0x78(t1)          # satp_value

    ld ra, 0(sp)
    addi sp, sp, 8
    ret

#============================================================
# strcmp: Compare two null-terminated strings
# a0 = str1, a1 = str2
# Returns: a0 = 0 if equal, nonzero if different
#============================================================
strcmp:
    lbu t0, 0(a0)
    lbu t1, 0(a1)
    bne t0, t1, strcmp_diff
    beqz t0, strcmp_equal
    addi a0, a0, 1
    addi a1, a1, 1
    j strcmp
strcmp_equal:
    li a0, 0
    ret
strcmp_diff:
    sub a0, t0, t1
    ret

#============================================================
# get_process_base: Get base of current process descriptor
# Returns: a0 = 0x80400000 + (next_process_num - 1) * 0x1000
#============================================================
get_process_base:
    lui t0, 0x40180
    slli t0, t0, 1           # t0 = 0x80300000
    ld t1, 0x20(t0)          # next_process_num
    addi t1, t1, -1          # current process num
    slli t1, t1, 12          # * 4096
    lui t0, 0x40200
    slli t0, t0, 1           # t0 = 0x80400000
    add a0, t0, t1
    ret

#============================================================
# absolute_path: Resolve path to absolute
# a0 = input path (null-terminated)
# Returns: a0 = pointer to resolved path in scratch buffer (0x80600000)
# Uses current process's current_dir if path is relative
#============================================================
absolute_path:
    addi sp, sp, -32
    sd ra, 0(sp)
    sd s0, 8(sp)
    sd s1, 16(sp)
    sd s2, 24(sp)

    mv s0, a0                # input path
    # Output buffer = scratch at 0x80600000
    lui t0, 0x50000
    slli s1, t0, 1           # s1 = output pointer (0xA0000000)
    mv s2, s1                # s2 = output start (for return)

    # Strip leading "./" if present
    lbu t0, 0(s0)
    li t1, 0x2E              # '.'
    bne t0, t1, abs_no_dot
    lbu t0, 1(s0)
    li t1, 0x2F              # '/'
    bne t0, t1, abs_no_dot
    addi s0, s0, 2           # skip "./"
abs_no_dot:

    # Check if absolute (starts with '/')
    lbu t0, 0(s0)
    li t1, 0x2F
    beq t0, t1, abs_copy_input

    # Relative: prepend cwd
    call get_process_base
    addi a0, a0, 0x100       # current_dir at +0x100
abs_copy_cwd:
    lbu t0, 0(a0)
    beqz t0, abs_copy_input
    sb t0, 0(s1)
    addi a0, a0, 1
    addi s1, s1, 1
    j abs_copy_cwd

abs_copy_input:
    lbu t0, 0(s0)
    sb t0, 0(s1)
    beqz t0, abs_done
    addi s0, s0, 1
    addi s1, s1, 1
    j abs_copy_input

abs_done:
    # Normalize: resolve /../ sequences in-place
    # Walk from start (s2), look for "/../"
    # When found, backtrack to remove preceding component
    mv s0, s2                # s0 = scan pointer
abs_norm_scan:
    lbu t0, 0(s0)
    beqz t0, abs_norm_done
    # Check for "/../" pattern: s0[0]='/' s0[1]='.' s0[2]='.' s0[3]='/' or s0[3]='\0'
    li t1, 0x2F              # '/'
    bne t0, t1, abs_norm_next
    lbu t0, 1(s0)
    li t1, 0x2E              # '.'
    bne t0, t1, abs_norm_next
    lbu t0, 2(s0)
    bne t0, t1, abs_norm_next
    lbu t0, 3(s0)
    li t1, 0x2F
    beq t0, t1, abs_norm_found
    beqz t0, abs_norm_found_end  # "/.." at end of string
    j abs_norm_next
abs_norm_found:
    # Found "/../" at s0. Remove preceding dir component.
    # Backtrack s0 to find the '/' before the dir name
    mv t2, s0                # t2 = start of "/../"
    beq s0, s2, abs_norm_skip  # at root, can't go back further
    addi s0, s0, -1          # back up one char before the '/'
abs_norm_back:
    beq s0, s2, abs_norm_do_remove  # reached start
    lbu t0, 0(s0)
    li t1, 0x2F
    beq t0, t1, abs_norm_do_remove
    addi s0, s0, -1
    j abs_norm_back
abs_norm_do_remove:
    # s0 = start of "/dir", t2 = start of "/../"
    # Copy from t2+3 (skip "/..") to s0
    addi t3, t2, 3           # t3 = source (after "/..")
abs_norm_copy:
    lbu t0, 0(t3)
    sb t0, 0(s0)
    beqz t0, abs_norm_restart
    addi t3, t3, 1
    addi s0, s0, 1
    j abs_norm_copy
abs_norm_restart:
    mv s0, s2                # restart scan from beginning
    j abs_norm_scan
abs_norm_skip:
    # At root with "/../", just skip the ".."
    addi t3, t2, 3           # source after "/.."
    mv s0, s2                # dest = start
abs_norm_skip_copy:
    lbu t0, 0(t3)
    sb t0, 0(s0)
    beqz t0, abs_norm_restart
    addi t3, t3, 1
    addi s0, s0, 1
    j abs_norm_skip_copy
abs_norm_found_end:
    # "/.." at end of string. Same as above but the string ends after ".."
    mv t2, s0
    beq s0, s2, abs_norm_trunc_root
    addi s0, s0, -1
abs_norm_back_end:
    beq s0, s2, abs_norm_trunc
    lbu t0, 0(s0)
    li t1, 0x2F
    beq t0, t1, abs_norm_trunc
    addi s0, s0, -1
    j abs_norm_back_end
abs_norm_trunc:
    # Null-terminate at s0 (removes /dir/..)
    sb zero, 0(s0)
    # If result is empty, make it "/"
    lbu t0, 0(s2)
    bnez t0, abs_norm_done
    li t0, 0x2F
    sb t0, 0(s2)
    sb zero, 1(s2)
    j abs_norm_done
abs_norm_trunc_root:
    # "/.." at root, result is "/"
    li t0, 0x2F
    sb t0, 0(s2)
    sb zero, 1(s2)
    j abs_norm_done
abs_norm_next:
    addi s0, s0, 1
    j abs_norm_scan
abs_norm_done:
    mv a0, s2                # return output buffer start

    ld ra, 0(sp)
    ld s0, 8(sp)
    ld s1, 16(sp)
    ld s2, 24(sp)
    addi sp, sp, 32
    ret

#============================================================
# find_file: Search for file by absolute path name
# a0 = path (absolute, null-terminated)
# Returns: a0 = file index (>= 3), or -1 if not found
# Searches backwards from newest file
#============================================================
find_file:
    addi sp, sp, -32
    sd ra, 0(sp)
    sd s0, 8(sp)
    sd s1, 16(sp)
    sd s2, 24(sp)

    mv s0, a0                # saved path

    # Load next_filenum
    lui t0, 0x40180
    slli t0, t0, 1
    ld s1, 0x10(t0)          # next_filenum
    addi s1, s1, -1          # start from last file

    # File names base = 0x80800000
    lui t0, 0x50010
    slli s2, t0, 1

find_file_loop:
    li t0, 3
    blt s1, t0, find_file_not_found

    # filename address = 0x80800000 + file_index * 1024
    slli t0, s1, 10
    add a0, s2, t0
    mv a1, s0
    call strcmp
    beqz a0, find_file_found

    addi s1, s1, -1
    j find_file_loop

find_file_not_found:
    li a0, -1
    j find_file_ret

find_file_found:
    mv a0, s1

find_file_ret:
    ld ra, 0(sp)
    ld s0, 8(sp)
    ld s1, 16(sp)
    ld s2, 24(sp)
    addi sp, sp, 32
    ret

#============================================================
# fd_to_file_index: Get global file index from process fd
# a0 = fd
# Returns: a0 = global file index
#============================================================
fd_to_file_index:
    addi sp, sp, -16
    sd ra, 0(sp)
    sd s0, 8(sp)
    mv s0, a0

    call get_process_base
    addi a0, a0, 0x200       # open_files at +0x200
    slli t0, s0, 3           # fd * 8 (each entry: 4-byte index + 4-byte offset)
    add a0, a0, t0
    lw a0, 0(a0)             # global file index

    ld ra, 0(sp)
    ld s0, 8(sp)
    addi sp, sp, 16
    ret

#============================================================
# fdt_find_storage: Parse FDT to find storage device
# a0 = DTB pointer (from OpenSBI via stage 1)
# Returns: a0 = MMIO base address (0 if not found)
#          a1 = storage type (0=none, 1=virtio, 2=spi_sd)
#
# Single-pass DTB walk. Detects:
# - VirtIO: node name starts with "virt", reg property gives MMIO base,
#   probed for VirtIO magic (0x74726976) and block device ID (2)
# - SPI+SD: node name starts with "spi@" (saves reg as SPI base),
#   child node name starts with "mmc@" (confirms SD card present)
#
# No fallback — returns what the DTB describes.
# FDT is big-endian; uses bswap32 for all multi-byte fields.
#============================================================
fdt_find_storage:
    addi sp, sp, -96
    sd ra, 0(sp)
    sd s0, 8(sp)
    sd s1, 16(sp)
    sd s3, 24(sp)
    sd s4, 32(sp)
    sd s5, 40(sp)
    sd s6, 48(sp)
    sd s8, 56(sp)
    sd s9, 64(sp)
    sd s10, 72(sp)
    sd s11, 80(sp)

    beqz a0, fdt_not_found      # null DTB pointer
    mv s0, a0                   # s0 = DTB base

    # Validate FDT magic: 0xd00dfeed big-endian = 0xedfe0dd0 as LE lw
    lw t0, 0(s0)
    lui t1, 0xedfe1
    addi t1, t1, -560           # t1 = 0xedfe0dd0
    bne t0, t1, fdt_not_found

    # Get structure block offset (big-endian u32 at dtb+8)
    lw a0, 8(s0)
    call bswap32
    add s1, s0, a0              # s1 = struct block pointer

    # Get strings block offset (big-endian u32 at dtb+0xC)
    lw a0, 0xC(s0)
    call bswap32
    add s3, s0, a0              # s3 = strings block base

    li s4, 0                    # s4 = node type (0=none, 1=virtio, 2=spi)
    li s5, 0                    # s5 = candidate MMIO address (current node)
    li s10, 0                   # s10 = SPI base (saved from parent spi@ node)
    li s11, 0                   # s11 = mmc_found flag

fdt_walk:
    lw a0, 0(s1)
    call bswap32
    mv s9, a0                   # s9 = token
    addi s1, s1, 4

    # FDT_END (9)
    li t0, 9
    beq s9, t0, fdt_walk_done

    # FDT_BEGIN_NODE (1)
    li t0, 1
    beq s9, t0, fdt_begin_node

    # FDT_END_NODE (2)
    li t0, 2
    beq s9, t0, fdt_end_node

    # FDT_PROP (3)
    li t0, 3
    beq s9, t0, fdt_prop

    # NOP (4) or unknown: skip
    j fdt_walk

fdt_begin_node:
    # Reset per-node state
    li s4, 0
    li s5, 0

    # Check node name prefix (first 4 bytes as LE lw)
    lw t0, 0(s1)

    # "virt" = 0x74726976
    lui t1, 0x74727
    addi t1, t1, -1674          # t1 = 0x74726976
    bne t0, t1, fdt_check_spi
    li s4, 1                    # mark as virtio node
    j fdt_skip_name

fdt_check_spi:
    # "spi@" = bytes 73 70 69 40 = LE 0x40697073
    lui t1, 0x40697
    addi t1, t1, 0x073          # t1 = 0x40697073
    bne t0, t1, fdt_check_mmc
    li s4, 2                    # mark as spi node
    j fdt_skip_name

fdt_check_mmc:
    # "mmc@" = bytes 6d 6d 63 40 = LE 0x40636d6d
    lui t1, 0x40637
    addi t1, t1, -659           # t1 = 0x40636d6d
    bne t0, t1, fdt_skip_name
    beqz s10, fdt_skip_name     # only if inside an spi@ node (s10 has base)
    li s11, 1                   # mmc child confirmed under spi@ parent

fdt_skip_name:
    # Skip null-terminated node name, then align to 4 bytes
    lbu t0, 0(s1)
    addi s1, s1, 1
    bnez t0, fdt_skip_name
    addi s1, s1, 3
    andi s1, s1, -4
    j fdt_walk

fdt_end_node:
    # Check if we found a VirtIO block device
    li t0, 1
    bne s4, t0, fdt_end_check_spi
    beqz s5, fdt_walk

    # Probe: check VirtIO magic at candidate address
    lw t0, 0(s5)
    lui t1, 0x74727
    addi t1, t1, -1674          # 0x74726976
    bne t0, t1, fdt_walk
    lw t0, 8(s5)
    li t1, 2
    bne t0, t1, fdt_walk

    # Found VirtIO block device
    mv a0, s5
    li a1, 1                    # type = STORAGE_VIRTIO
    j fdt_found

fdt_end_check_spi:
    # When an spi@ node ends, save its reg as candidate SPI base
    li t0, 2
    bne s4, t0, fdt_walk
    bnez s5, fdt_save_spi_base
    j fdt_walk
fdt_save_spi_base:
    mv s10, s5                  # save SPI base for later
    j fdt_walk

fdt_prop:
    # Read property length (big-endian u32)
    lw a0, 0(s1)
    call bswap32
    mv s6, a0                   # s6 = prop_len

    # Read property nameoff (big-endian u32)
    lw a0, 4(s1)
    call bswap32
    mv s8, a0                   # s8 = nameoff

    addi s1, s1, 8              # skip len + nameoff fields
    # s1 now points to property data

    # Only extract reg from virtio or spi nodes
    beqz s4, fdt_prop_skip

    # Check if property name is "reg\0" (LE lw = 0x00676572)
    add t0, s3, s8              # property name pointer
    lw t0, 0(t0)
    li t1, 0x00676572
    bne t0, t1, fdt_prop_skip

    # Extract MMIO base address from reg property
    # Assumes #address-cells=2: 8-byte address (2x big-endian u32)
    lw a0, 0(s1)
    call bswap32
    slli s5, a0, 32             # high 32 bits
    lw a0, 4(s1)
    call bswap32
    or s5, s5, a0               # s5 = full 64-bit MMIO address

    # If this is a spi@ node, save the base immediately (before child nodes reset s5)
    li t0, 2
    bne s4, t0, fdt_prop_skip
    mv s10, s5                  # save SPI base

fdt_prop_skip:
    # Advance past property data, aligned to 4 bytes
    add s1, s1, s6
    addi s1, s1, 3
    andi s1, s1, -4
    j fdt_walk

fdt_walk_done:
    # DTB walk complete. Check if we found SPI+SD (mmc under spi)
    beqz s11, fdt_not_found     # no mmc@ node seen
    beqz s10, fdt_not_found     # no spi@ base saved
    mv a0, s10
    li a1, 2                    # type = STORAGE_SPI_SD
    j fdt_found

fdt_not_found:
    li a0, 0
    li a1, 0                    # type = STORAGE_NONE

fdt_found:
    # a0 = MMIO base (or 0), a1 = storage type
    ld ra, 0(sp)
    ld s0, 8(sp)
    ld s1, 16(sp)
    ld s3, 24(sp)
    ld s4, 32(sp)
    ld s5, 40(sp)
    ld s6, 48(sp)
    ld s8, 56(sp)
    ld s9, 64(sp)
    ld s10, 72(sp)
    ld s11, 80(sp)
    addi sp, sp, 96
    ret

#============================================================
# virtio_init: Initialize VirtIO block device at given MMIO base
# a0 = MMIO base address (from fdt_find_storage)
# Halts if a0 == 0. Stores MMIO base, struct base, and disk
# function pointers in global data.
#============================================================
virtio_init:
    addi sp, sp, -48
    sd ra, 0(sp)
    sd s0, 8(sp)
    sd s3, 16(sp)
    sd s4, 24(sp)
    sd s5, 32(sp)

    # a0 = MMIO base from fdt_find_storage; halt if 0
    beqz a0, virtio_init_fail
    mv s3, a0                    # s3 = MMIO base

    # Load VirtIO structures base: s4 = 0x80500000
    lui t0, 0x40280
    slli s4, t0, 1

    # Load global data base: s5 = 0x80300000
    lui t0, 0x40180
    slli s5, t0, 1
    # Reset device
    sw zero, 0x70(s3)         # Status = 0

    # Set ACKNOWLEDGE
    li t0, 1
    sw t0, 0x70(s3)

    # Set DRIVER
    li t0, 3
    sw t0, 0x70(s3)

    # Check version
    lw t0, 4(s3)
    li t1, 2
    beq t0, t1, virtio_modern_setup

    #--- Version 1 (legacy) setup ---
virtio_legacy_setup:
    # Negotiate features: accept none
    sw zero, 0x20(s3)         # DriverFeatures = 0

    # Zero structures area (8KB)
    mv a0, s4
    lui a1, 2                 # a1 = 0x2000 = 8192
    call memset_zero

    # Set GuestPageSize = 4096 (V1 requirement, offset 0x28)
    lui t0, 1                 # 0x1000 = 4096
    sw t0, 0x28(s3)

    # Select queue 0
    sw zero, 0x30(s3)

    # Set queue size = 8
    li t0, 8
    sw t0, 0x38(s3)

    # Set QueueAlign = 4096
    lui t0, 1                 # 0x1000
    sw t0, 0x3C(s3)

    # Set QueuePFN = 0x80500000 / 4096 = 0x80500
    lui t0, 0x80
    addi t0, t0, 0x500
    sw t0, 0x40(s3)

    # Set DRIVER_OK
    li t0, 7
    sw t0, 0x70(s3)

    j virtio_init_done

    #--- Version 2 (modern) setup ---
virtio_modern_setup:
    # Accept no features
    sw zero, 0x24(s3)         # DriverFeaturesSel = 0
    sw zero, 0x20(s3)         # DriverFeatures = 0

    # Set FEATURES_OK: Status = 0xB
    li t0, 0xB
    sw t0, 0x70(s3)

    # Verify FEATURES_OK persisted
    lw t0, 0x70(s3)
    andi t0, t0, 8
    beqz t0, reboot

    # Zero structures area
    mv a0, s4
    lui a1, 2                 # 8KB
    call memset_zero

    # Select queue 0
    sw zero, 0x30(s3)

    # Set queue size = 8
    li t0, 8
    sw t0, 0x38(s3)

    # Descriptor table address = s4
    mv t0, s4
    sw t0, 0x80(s3)           # QueueDescLow
    srli t0, s4, 32
    sw t0, 0x84(s3)           # QueueDescHigh

    # Available ring address = s4 + 0x80
    addi t0, s4, 0x80
    sw t0, 0x90(s3)           # QueueDriverLow
    srli t1, s4, 32
    sw t1, 0x94(s3)           # QueueDriverHigh

    # Used ring address = s4 + 0x1000
    lui t0, 1
    add t0, s4, t0
    sw t0, 0xA0(s3)           # QueueDeviceLow
    srli t1, s4, 32
    sw t1, 0xA4(s3)           # QueueDeviceHigh

    # Enable queue
    li t0, 1
    sw t0, 0x44(s3)

    # Set DRIVER_OK (must include FEATURES_OK for V2)
    # ACK(1) | DRIVER(2) | FEATURES_OK(8) | DRIVER_OK(4) = 0xF
    li t0, 0xF
    sw t0, 0x70(s3)

    j virtio_init_done

virtio_init_fail:
    # Print '!' and halt — DTB did not provide a valid VirtIO address
    li a0, 0x21
    call sbi_putchar
    j reboot

virtio_init_done:
    # Store MMIO base in global data
    sd s3, 0(s5)              # globals+0x000 = mmio_base
    # Store struct base
    sd s4, 8(s5)              # globals+0x008 = struct_base

    # Set disk I/O function pointers
    la t0, virtio_read_sector
    sd t0, 0x88(s5)           # globals+0x088 = disk_read_fn
    la t0, virtio_write_sector
    sd t0, 0x90(s5)           # globals+0x090 = disk_write_fn

    # Restore and return
    ld ra, 0(sp)
    ld s0, 8(sp)
    ld s3, 16(sp)
    ld s4, 24(sp)
    ld s5, 32(sp)
    addi sp, sp, 48
    ret

#============================================================
# disk_read_sector: Read one 512-byte sector via function pointer
# a0 = sector number, a1 = destination buffer address
# Returns: a0 = 0 on success
# Dispatches through disk_read_fn at globals+0x088
#============================================================
disk_read_sector:
    lui t0, 0x40180
    slli t0, t0, 1              # t0 = 0x80300000
    ld t0, 0x88(t0)             # disk_read_fn
    jr t0

#============================================================
# disk_write_sector: Write one 512-byte sector via function pointer
# a0 = sector number, a1 = source buffer address
# Returns: a0 = 0 on success
# Dispatches through disk_write_fn at globals+0x090
#============================================================
disk_write_sector:
    lui t0, 0x40180
    slli t0, t0, 1              # t0 = 0x80300000
    ld t0, 0x90(t0)             # disk_write_fn
    jr t0

#============================================================
# virtio_read_sector: Read one 512-byte sector from disk
# a0 = sector number, a1 = destination buffer address
# Returns: a0 = 0 on success
#============================================================
virtio_read_sector:
    addi sp, sp, -48
    sd ra, 0(sp)
    sd s0, 8(sp)              # initial used.idx
    sd s1, 16(sp)             # buffer address
    sd s3, 24(sp)             # MMIO base
    sd s4, 32(sp)             # struct base
    mv s1, a1                 # save buffer

    # Load MMIO base and struct base from globals
    lui t0, 0x40180
    slli t0, t0, 1            # t0 = 0x80300000
    ld s3, 0(t0)              # MMIO base
    ld s4, 8(t0)              # struct base

    # Save initial used.idx before submitting
    lui t0, 1
    add t0, s4, t0            # t0 = used ring (s4 + 0x1000)
    lhu s0, 2(t0)             # s0 = initial used.idx

    # --- Set up request header at s4 + 0x2000 ---
    lui t0, 2
    add t0, s4, t0            # t0 = header address
    sw zero, 0(t0)            # type = 0 (IN/read)
    sw zero, 4(t0)            # reserved = 0
    sd a0, 8(t0)              # sector number

    # --- Set up status byte at s4 + 0x2010 ---
    lui t0, 2
    add t0, s4, t0
    addi t0, t0, 0x10
    li t1, 0xFF
    sb t1, 0(t0)              # status = 0xFF (pending)

    # --- Set up descriptor 0: header (read-only) ---
    # desc[0].addr = s4 + 0x2000
    lui t0, 2
    add t0, s4, t0
    sd t0, 0(s4)              # desc[0].addr
    li t0, 16
    sw t0, 8(s4)              # desc[0].len = 16
    li t0, 1                  # NEXT flag
    sh t0, 12(s4)             # desc[0].flags
    li t0, 1
    sh t0, 14(s4)             # desc[0].next = 1

    # --- Set up descriptor 1: data buffer (device writes) ---
    # desc[1] at s4 + 16
    sd s1, 16(s4)             # desc[1].addr = buffer
    li t0, 512
    sw t0, 24(s4)             # desc[1].len = 512
    li t0, 3                  # NEXT | WRITE
    sh t0, 28(s4)             # desc[1].flags
    li t0, 2
    sh t0, 30(s4)             # desc[1].next = 2

    # --- Set up descriptor 2: status byte (device writes) ---
    # desc[2] at s4 + 32
    # status at s4 + 0x2010
    lui t0, 2
    add t0, s4, t0
    addi t0, t0, 0x10
    sd t0, 32(s4)             # desc[2].addr = status
    li t0, 1
    sw t0, 40(s4)             # desc[2].len = 1
    li t0, 2                  # WRITE
    sh t0, 44(s4)             # desc[2].flags
    sh zero, 46(s4)           # desc[2].next = 0

    # --- Add to available ring (at s4 + 0x80) ---
    addi a0, s4, 0x80         # a0 = avail ring base
    sh zero, 0(a0)            # avail.flags = 0
    lhu t0, 2(a0)             # current avail.idx
    # ring[idx % queue_size] at offset 4 + (idx & 7)*2
    andi t1, t0, 7            # t1 = idx % 8 (queue_size = 8)
    slli t1, t1, 1
    addi t1, t1, 4
    add t1, a0, t1
    sh zero, 0(t1)            # ring[idx % 8] = 0 (chain head)
    addi t0, t0, 1
    sh t0, 2(a0)              # avail.idx++ (wraps at 16-bit per spec)

    # Memory fence and notify
    fence
    sw zero, 0x50(s3)         # QueueNotify = 0

    # --- Poll used ring ---
    lui t0, 1
    add a0, s4, t0            # a0 = used ring (s4 + 0x1000)
virtio_read_poll:
    fence
    lhu t0, 2(a0)             # current used.idx
    beq t0, s0, virtio_read_poll

    # Acknowledge interrupt
    lw t0, 0x60(s3)           # InterruptStatus
    sw t0, 0x64(s3)           # InterruptACK

    # Check status byte
    lui t0, 2
    add t0, s4, t0
    addi t0, t0, 0x10
    lbu a0, 0(t0)             # status (0 = success)

    # Restore and return
    ld ra, 0(sp)
    ld s0, 8(sp)
    ld s1, 16(sp)
    ld s3, 24(sp)
    ld s4, 32(sp)
    addi sp, sp, 48
    ret

#============================================================
# virtio_write_sector: Write one 512-byte sector to disk
# a0 = sector number, a1 = source buffer address
# Returns: a0 = 0 on success
#============================================================
virtio_write_sector:
    addi sp, sp, -48
    sd ra, 0(sp)
    sd s0, 8(sp)
    sd s1, 16(sp)
    sd s3, 24(sp)
    sd s4, 32(sp)
    mv s1, a1                 # save buffer

    # Load globals
    lui t0, 0x40180
    slli t0, t0, 1
    ld s3, 0(t0)
    ld s4, 8(t0)

    # Save initial used.idx
    lui t0, 1
    add t0, s4, t0
    lhu s0, 2(t0)

    # Set up request header (type = 1 = OUT/write)
    lui t0, 2
    add t0, s4, t0
    li t1, 1
    sw t1, 0(t0)              # type = 1 (OUT/write)
    sw zero, 4(t0)            # reserved
    sd a0, 8(t0)              # sector number

    # Status byte
    lui t0, 2
    add t0, s4, t0
    addi t0, t0, 0x10
    li t1, 0xFF
    sb t1, 0(t0)

    # Descriptor 0: header (read-only)
    lui t0, 2
    add t0, s4, t0
    sd t0, 0(s4)
    li t0, 16
    sw t0, 8(s4)
    li t0, 1                  # NEXT
    sh t0, 12(s4)
    li t0, 1
    sh t0, 14(s4)

    # Descriptor 1: data buffer (device reads, no WRITE flag)
    sd s1, 16(s4)
    li t0, 512
    sw t0, 24(s4)
    li t0, 1                  # NEXT only (device reads)
    sh t0, 28(s4)
    li t0, 2
    sh t0, 30(s4)

    # Descriptor 2: status (device writes)
    lui t0, 2
    add t0, s4, t0
    addi t0, t0, 0x10
    sd t0, 32(s4)
    li t0, 1
    sw t0, 40(s4)
    li t0, 2                  # WRITE
    sh t0, 44(s4)
    sh zero, 46(s4)

    # Add to available ring
    addi a0, s4, 0x80
    sh zero, 0(a0)
    lhu t0, 2(a0)
    andi t1, t0, 7            # idx % 8 (queue_size = 8)
    slli t1, t1, 1
    addi t1, t1, 4
    add t1, a0, t1
    sh zero, 0(t1)
    addi t0, t0, 1
    sh t0, 2(a0)

    # Notify
    fence
    sw zero, 0x50(s3)

    # Poll used ring
    lui t0, 1
    add a0, s4, t0
virtio_write_poll:
    fence
    lhu t0, 2(a0)
    beq t0, s0, virtio_write_poll

    # ACK interrupt
    lw t0, 0x60(s3)
    sw t0, 0x64(s3)

    # Check status
    lui t0, 2
    add t0, s4, t0
    addi t0, t0, 0x10
    lbu a0, 0(t0)

    ld ra, 0(sp)
    ld s0, 8(sp)
    ld s1, 16(sp)
    ld s3, 24(sp)
    ld s4, 32(sp)
    addi sp, sp, 48
    ret

#============================================================
# SPI+SD Driver (SiFive SPI controller + SD card over SPI)
#
# SiFive SPI registers (offsets from base):
#   SCKDIV  0x00  Clock divisor
#   SCKMODE 0x04  SPI mode (polarity/phase)
#   CSID    0x10  Chip select ID
#   CSDEF   0x14  CS default (active-low)
#   CSMODE  0x18  CS mode (0=auto, 2=hold, 3=off)
#   TXDATA  0x48  TX FIFO (bit 31 = full)
#   RXDATA  0x4C  RX FIFO (bit 31 = empty)
#   FCTRL   0x60  Flash interface control (must be 0 for raw SPI)
#============================================================

#============================================================
# spi_transfer: Exchange one byte over SPI
# a0 = byte to send
# Returns: a0 = byte received
# Expects SPI base in globals+0x098
#============================================================
spi_transfer:
    lui t0, 0x40180
    slli t0, t0, 1              # t0 = 0x80300000
    ld t0, 0x98(t0)             # SPI base

    # Wait for TX not full (bit 31 = 0)
spi_tx_wait:
    lw t1, 0x48(t0)             # TXDATA
    bltz t1, spi_tx_wait        # bit 31 set = full
    # Write byte
    sw a0, 0x48(t0)

    # Wait for RX not empty (bit 31 = 0)
spi_rx_wait:
    lw a0, 0x4C(t0)             # RXDATA
    bltz a0, spi_rx_wait        # bit 31 set = empty
    andi a0, a0, 0xFF
    ret

#============================================================
# spi_sd_cmd: Send an SD command and get R1 response
# a0 = command byte (0x40 | cmd_index)
# a1 = 32-bit argument
# a2 = CRC byte
# Returns: a0 = R1 response byte
#============================================================
spi_sd_cmd:
    addi sp, sp, -16
    sd ra, 0(sp)
    sd s0, 8(sp)

    # spi_transfer only clobbers a0/t0/t1, so a1 (arg) and a2 (CRC) survive

    # Send command byte (a0 already has it)
    call spi_transfer

    # Send 4 argument bytes (big-endian, a1 preserved across calls)
    srli a0, a1, 24
    andi a0, a0, 0xFF
    call spi_transfer
    srli a0, a1, 16
    andi a0, a0, 0xFF
    call spi_transfer
    srli a0, a1, 8
    andi a0, a0, 0xFF
    call spi_transfer
    andi a0, a1, 0xFF
    call spi_transfer

    # Send CRC byte (a2 preserved across calls)
    mv a0, a2
    call spi_transfer

    # Poll for response (up to 8 bytes, wait for bit 7 = 0)
    li s0, 8
spi_sd_cmd_poll:
    li a0, 0xFF
    call spi_transfer
    andi t0, a0, 0x80
    beqz t0, spi_sd_cmd_done       # bit 7 clear = valid R1 response
    addi s0, s0, -1
    bnez s0, spi_sd_cmd_poll
    li a0, 0xFF                 # timeout

spi_sd_cmd_done:
    ld ra, 0(sp)
    ld s0, 8(sp)
    addi sp, sp, 16
    ret

#============================================================
# spi_sd_init: Configure SPI+SD for stage 2 use
# a0 = SPI controller MMIO base (from fdt_find_storage)
# Stage 1 already initialized the SD card. This just stores
# the SPI base in globals and sets disk function pointers.
#============================================================
spi_sd_init:
    # Leaf function — no calls, no stack needed

    # Store SPI base in globals
    lui t0, 0x40180
    slli t0, t0, 1              # t0 = 0x80300000
    sd a0, 0x98(t0)             # globals+0x098 = spi_base
    sd a0, 0(t0)                # globals+0x000 = mmio_base (reuse)

    # Set disk function pointers
    la t1, spi_sd_read_sector
    sd t1, 0x88(t0)             # disk_read_fn
    la t1, spi_sd_write_sector
    sd t1, 0x90(t0)             # disk_write_fn

    ret

#============================================================
# spi_sd_read_sector: Read one 512-byte sector from SD card
# a0 = sector number, a1 = destination buffer address
# Returns: a0 = 0 on success
#============================================================
spi_sd_read_sector:
    addi sp, sp, -24
    sd ra, 0(sp)
    sd s0, 8(sp)
    sd s3, 16(sp)

    mv s0, a1                   # s0 = buffer
    mv s3, a0                   # s3 = sector

    # CMD17: READ_SINGLE_BLOCK (byte address = sector * 512)
    li a0, 0x51                 # CMD17 = 0x40 | 17
    slli a1, s3, 9              # sector * 512 for byte addressing
    li a2, 0xFF
    call spi_sd_cmd

    # Wait for data token (0xFE)
    # First 0xFF consumes the bridge RESPONSE→DATA_START transition
spi_sd_read_wait_token:
    li a0, 0xFF
    call spi_transfer
    li t0, 0xFE
    bne a0, t0, spi_sd_read_wait_token

    # Read 512 bytes
    li s3, 512
spi_sd_read_loop:
    li a0, 0xFF
    call spi_transfer
    sb a0, 0(s0)
    addi s0, s0, 1
    addi s3, s3, -1
    bnez s3, spi_sd_read_loop

    # Read 2 CRC bytes (discard)
    li a0, 0xFF
    call spi_transfer
    li a0, 0xFF
    call spi_transfer

    li a0, 0                    # success

    ld ra, 0(sp)
    ld s0, 8(sp)
    ld s3, 16(sp)
    addi sp, sp, 24
    ret

#============================================================
# spi_sd_write_sector: Write one 512-byte sector to SD card
# a0 = sector number, a1 = source buffer address
# Returns: a0 = 0 on success
#============================================================
spi_sd_write_sector:
    addi sp, sp, -24
    sd ra, 0(sp)
    sd s0, 8(sp)
    sd s3, 16(sp)

    mv s0, a1                   # s0 = buffer
    mv s3, a0                   # s3 = sector

    # CMD24: WRITE_SINGLE_BLOCK (byte address = sector * 512)
    li a0, 0x58                 # CMD24 = 0x40 | 24
    slli a1, s3, 9              # sector * 512 for byte addressing
    li a2, 0xFF
    call spi_sd_cmd

    # Send data token (0xFE)
    # First 0xFF consumes the RESPONSE→CMD transition, then 0xFE starts write
    li a0, 0xFF
    call spi_transfer
    li a0, 0xFE
    call spi_transfer

    # Write 512 bytes
    li s3, 512
spi_sd_write_loop:
    lbu a0, 0(s0)
    call spi_transfer
    addi s0, s0, 1
    addi s3, s3, -1
    bnez s3, spi_sd_write_loop

    # Send 2 dummy CRC bytes
    li a0, 0xFF
    call spi_transfer
    li a0, 0xFF
    call spi_transfer

    # Wait for data response token
    li a0, 0xFF
    call spi_transfer

    # Wait while card is busy (DO = 0x00)
spi_sd_write_busy:
    li a0, 0xFF
    call spi_transfer
    beqz a0, spi_sd_write_busy

    li a0, 0                    # success

    ld ra, 0(sp)
    ld s0, 8(sp)
    ld s3, 16(sp)
    addi sp, sp, 24
    ret

#============================================================
# internalshell: Main command loop (runs in S-mode, paging OFF)
# Reads commands from stdin (disk) and dispatches them
#============================================================
internalshell:
    addi sp, sp, -64
    sd ra, 0(sp)
    sd s0, 8(sp)
    sd s1, 16(sp)
    sd s2, 24(sp)
    sd s3, 32(sp)
    sd s4, 40(sp)
    sd s5, 48(sp)
    sd s6, 56(sp)

shell_loop:
    call read_stdin_byte
    mv s0, a0                # s0 = first char of command

    # End of input (null byte)
    beqz s0, shell_done

    # Skip newlines and carriage returns
    li t0, 0x0A
    beq s0, t0, shell_loop
    li t0, 0x0D
    beq s0, t0, shell_loop

    # Skip comments (lines starting with '#')
    li t0, 0x23
    beq s0, t0, shell_skip_comment

    # Check for 's' (src command)
    li t0, 0x73
    beq s0, t0, handle_src

    # Check for 'h' (hex0 command)
    li t0, 0x68
    beq s0, t0, handle_hex0

    # Check for 'f' (enable flush)
    li t0, 0x66
    beq s0, t0, handle_flush

    # Other character: external command
    j handle_other_command

shell_skip_comment:
    call read_stdin_byte
    li t0, 0x0A
    bne a0, t0, shell_skip_comment
    j shell_loop

shell_done:
    # Print "Done.\n"
    li a0, 0x44
    call sbi_putchar
    li a0, 0x6F
    call sbi_putchar
    li a0, 0x6E
    call sbi_putchar
    li a0, 0x65
    call sbi_putchar
    li a0, 0x2E
    call sbi_putchar
    li a0, 0x0A
    call sbi_putchar

    # Flush disk
    call flush_disk

    # Shutdown
    j reboot

#============================================================
# handle_flush: 'f' command - enable disk flushing
#============================================================
handle_flush:
    # Skip rest of line (newline)
    call read_stdin_byte

    # Set enable_flush = 1
    lui t0, 0x40180
    slli t0, t0, 1
    li t1, 1
    sd t1, 0x48(t0)

    # Print "f\n"
    li a0, 0x66
    call sbi_putchar
    li a0, 0x0A
    call sbi_putchar

    j shell_loop

#============================================================
# handle_src: 's' command - read file from stdin
# Format: src N filename\n<N bytes>
# Already read 's', need to skip "rc "
# Register plan:
#   s1 = byte count (decrements to 0)
#   s2 = original byte count
#   s3 = file descriptor table entry address
#   s4 = write pointer (into file data area)
#============================================================
handle_src:
    # Print "src "
    li a0, 0x73
    call sbi_putchar
    li a0, 0x72
    call sbi_putchar
    li a0, 0x63
    call sbi_putchar
    li a0, 0x20
    call sbi_putchar

    # Skip "rc "
    call read_stdin_byte     # 'r'
    call read_stdin_byte     # 'c'
    call read_stdin_byte     # ' '

    # Parse decimal count into s1
    li s1, 0
src_parse_count:
    call read_stdin_byte
    li t0, 0x20              # space
    beq a0, t0, src_count_done
    li t0, 10
    mul s1, s1, t0
    addi a0, a0, -0x30
    add s1, s1, a0
    j src_parse_count
src_count_done:
    mv s2, s1                # s2 = original count

    # Read filename into scratch buffer at 0xA0000000
    lui s3, 0x50000
    slli s3, s3, 1           # s3 = 0xA0000000 (reused below)
    mv s4, s3                # s4 = write cursor
src_read_name:
    call read_stdin_byte
    li t0, 0x0A              # newline
    beq a0, t0, src_name_done
    sb a0, 0(s4)
    addi s4, s4, 1
    j src_read_name
src_name_done:
    sb zero, 0(s4)           # null-terminate

    # Print filename + newline
    mv a0, s3
    call print_string
    li a0, 0x0A
    call sbi_putchar

    # Resolve to absolute path
    mv a0, s3
    call absolute_path
    mv s3, a0                # s3 = absolute path in scratch

    # Allocate new file entry
    lui t0, 0x40180
    slli t0, t0, 1           # globals
    ld s4, 0x10(t0)          # s4 = next_filenum (our file index)

    # Copy filename to file names table (0x80800000 + index * 1024)
    lui t1, 0x50010
    slli t1, t1, 1
    slli t2, s4, 10
    add t1, t1, t2           # dest
    mv t2, s3                # src
src_copy_fname:
    lbu t3, 0(t2)
    sb t3, 0(t1)
    beqz t3, src_fname_done
    addi t1, t1, 1
    addi t2, t2, 1
    j src_copy_fname
src_fname_done:

    # Set up global file descriptor (0x81000000 + index * 16)
    lui t0, 0x50410
    slli t0, t0, 1
    slli t1, s4, 4
    add s3, t0, t1           # s3 = &file_desc entry
    lui t0, 0x40180
    slli t0, t0, 1
    ld t1, 0x18(t0)          # next_file_address
    sd t1, 0(s3)             # file_address
    sd zero, 8(s3)           # file_length = 0

    # Increment next_filenum
    ld t1, 0x10(t0)
    addi t1, t1, 1
    sd t1, 0x10(t0)

    # s4 = write pointer = file_address
    ld s4, 0(s3)

    # Read s1 bytes from stdin and write to file
src_read_data:
    beqz s1, src_data_done
    call read_stdin_byte
    sb a0, 0(s4)
    addi s4, s4, 1
    addi s1, s1, -1
    j src_read_data
src_data_done:

    # Set file length = original count (s2)
    sd s2, 8(s3)

    # Advance next_file_address by count
    lui t0, 0x40180
    slli t0, t0, 1
    ld t1, 0x18(t0)
    add t1, t1, s2
    sd t1, 0x18(t0)

    j shell_loop

#============================================================
# handle_hex0: 'h' command - compile hex0 source to binary
# Format: hex0 input output\n
# Already read 'h', need to skip "ex0 "
# Register plan:
#   s1 = input filename (in scratch)
#   s2 = output filename (in scratch + 0x400)
#   s3 = input file address
#   s4 = input file length / read offset
#   s5 = output file desc entry
#   s6 = output write pointer
#   s0 = hex state (0=first nibble, 1=second nibble), high nibble
#============================================================
handle_hex0:
    # Print "hex0 "
    li a0, 0x68
    call sbi_putchar
    li a0, 0x65
    call sbi_putchar
    li a0, 0x78
    call sbi_putchar
    li a0, 0x30
    call sbi_putchar
    li a0, 0x20
    call sbi_putchar

    # Skip "ex0 "
    call read_stdin_byte     # 'e'
    call read_stdin_byte     # 'x'
    call read_stdin_byte     # '0'
    call read_stdin_byte     # ' '

    # Read input filename into scratch at 0xA0000000
    lui s1, 0x50000
    slli s1, s1, 1           # s1 = 0xA0000000
    mv s4, s1                # write cursor
hex0_read_input:
    call read_stdin_byte
    li t0, 0x20              # space
    beq a0, t0, hex0_input_done
    sb a0, 0(s4)
    addi s4, s4, 1
    j hex0_read_input
hex0_input_done:
    sb zero, 0(s4)           # null-terminate

    # Print input filename + space
    mv a0, s1
    call print_string
    li a0, 0x20
    call sbi_putchar

    # Read output filename into scratch + 0x400
    lui s2, 0x50000
    slli s2, s2, 1
    addi s2, s2, 0x400       # s2 = 0xA0000400
    mv s4, s2
hex0_read_output:
    call read_stdin_byte
    li t0, 0x0A              # newline
    beq a0, t0, hex0_output_done
    sb a0, 0(s4)
    addi s4, s4, 1
    j hex0_read_output
hex0_output_done:
    sb zero, 0(s4)

    # Print output filename + newline
    mv a0, s2
    call print_string
    li a0, 0x0A
    call sbi_putchar

    # Resolve input filename and find file
    mv a0, s1
    call absolute_path
    mv s1, a0
    call find_file
    bltz a0, shell_loop      # file not found, skip
    mv s4, a0                # s4 = input file index

    # Get input file address and length
    lui t0, 0x50410
    slli t0, t0, 1
    slli t1, s4, 4
    add t0, t0, t1
    ld s3, 0(t0)             # s3 = input file address
    ld s4, 8(t0)             # s4 = input file length

    # Resolve output filename and create file
    mv a0, s2
    call absolute_path
    mv s2, a0

    # Allocate output file
    lui t0, 0x40180
    slli t0, t0, 1
    ld s5, 0x10(t0)          # s5 = output file index

    # Copy output filename to file names table
    lui t1, 0x50010
    slli t1, t1, 1
    slli t2, s5, 10
    add t1, t1, t2
    mv t2, s2
hex0_copy_outname:
    lbu t3, 0(t2)
    sb t3, 0(t1)
    beqz t3, hex0_outname_done
    addi t1, t1, 1
    addi t2, t2, 1
    j hex0_copy_outname
hex0_outname_done:

    # Set up output file descriptor
    lui t0, 0x50410
    slli t0, t0, 1
    slli t1, s5, 4
    add s5, t0, t1           # s5 = &output file desc
    lui t0, 0x40180
    slli t0, t0, 1
    ld t1, 0x18(t0)          # next_file_address
    sd t1, 0(s5)             # file_address
    sd zero, 8(s5)           # file_length = 0

    # Increment next_filenum
    ld t1, 0x10(t0)
    addi t1, t1, 1
    sd t1, 0x10(t0)

    # s6 = output write pointer
    ld s6, 0(s5)

    # Compile hex0: read input file byte by byte
    # s0 low byte = hex state flag (0=need first nibble, nonzero=have first)
    # s0 byte 1 = high nibble value
    li s0, 0                 # state = 0
    li s1, 0                 # read offset into input file

hex0_compile_loop:
    # Check if we've read all input bytes
    bge s1, s4, hex0_compile_done

    # Read one byte from input file
    add t0, s3, s1           # addr = file_address + offset
    lbu a0, 0(t0)
    addi s1, s1, 1

    # Skip comments (# and ;)
    li t0, 0x23              # '#'
    beq a0, t0, hex0_skip_comment
    li t0, 0x3B              # ';'
    beq a0, t0, hex0_skip_comment

    # Convert hex char to nibble
    # '0'-'9' -> 0-9
    li t0, 0x30
    blt a0, t0, hex0_compile_loop    # < '0', skip
    li t0, 0x3A
    blt a0, t0, hex0_digit           # '0'-'9'
    # 'A'-'F' -> 10-15
    li t0, 0x41
    blt a0, t0, hex0_compile_loop    # < 'A', skip
    li t0, 0x47
    blt a0, t0, hex0_upper           # 'A'-'F'
    # 'a'-'f' -> 10-15
    li t0, 0x61
    blt a0, t0, hex0_compile_loop    # < 'a', skip
    li t0, 0x67
    blt a0, t0, hex0_lower           # 'a'-'f'
    j hex0_compile_loop              # > 'f', skip

hex0_digit:
    addi a0, a0, -0x30       # nibble = char - '0'
    j hex0_got_nibble

hex0_upper:
    addi a0, a0, -0x37       # nibble = char - 'A' + 10
    j hex0_got_nibble

hex0_lower:
    addi a0, a0, -0x57       # nibble = char - 'a' + 10
    j hex0_got_nibble

hex0_got_nibble:
    # Check state
    andi t0, s0, 0xFF
    bnez t0, hex0_second_nibble

    # First nibble: save it
    slli a0, a0, 4           # high nibble
    slli a0, a0, 8           # shift to byte 1 of s0
    li t0, 1                 # state = have first nibble
    or s0, a0, t0
    j hex0_compile_loop

hex0_second_nibble:
    # Combine with saved high nibble
    srli t0, s0, 8
    andi t0, t0, 0xF0        # high nibble
    or t0, t0, a0            # full byte
    sb t0, 0(s6)             # write to output
    addi s6, s6, 1
    li s0, 0                 # reset state
    j hex0_compile_loop

hex0_skip_comment:
    # Skip to end of line
    bge s1, s4, hex0_compile_done
    add t0, s3, s1
    lbu a0, 0(t0)
    addi s1, s1, 1
    li t0, 0x0A              # newline
    bne a0, t0, hex0_skip_comment
    j hex0_compile_loop

hex0_compile_done:
    # Set output file length
    ld t0, 0(s5)             # output file start
    sub t0, s6, t0           # length = write_ptr - start
    sd t0, 8(s5)

    # Advance next_file_address
    lui t1, 0x40180
    slli t1, t1, 1
    ld t2, 0x18(t1)
    add t2, t2, t0           # advance by length
    sd t2, 0x18(t1)

    j shell_loop

#============================================================
# handle_other_command: Execute external program
# First char already in s0
# Format: command_name arg\n
# Register plan:
#   s1 = command name buffer (0xA0000000)
#   s2 = argument buffer (0xA0000400)
#   s3, s4 = temporaries
#============================================================
handle_other_command:
    # Check if we need to flush disk
    lui t0, 0x40180
    slli t0, t0, 1
    ld t1, 0x48(t0)
    beqz t1, hoc_no_flush
    call flush_disk
hoc_no_flush:

    # Command name buffer at scratch + 0x800
    lui s1, 0x50000
    slli s1, s1, 1
    addi t0, zero, 1
    slli t0, t0, 11          # t0 = 0x800
    add s1, s1, t0           # s1 = 0xA0000800
    # Store first char (already in s0)
    sb s0, 0(s1)
    addi s2, s1, 1           # write cursor

    # Read rest of command name until space
hoc_read_name:
    call read_stdin_byte
    li t0, 0x20              # space
    beq a0, t0, hoc_name_done
    sb a0, 0(s2)
    addi s2, s2, 1
    j hoc_read_name
hoc_name_done:
    sb zero, 0(s2)           # null-terminate command name

    # Argument buffer at scratch + 0xC00
    lui s2, 0x50000
    slli s2, s2, 1
    addi t0, zero, 3
    slli t0, t0, 10          # t0 = 0xC00
    add s2, s2, t0           # s2 = 0xA0000C00
    mv s3, s2                # write cursor
hoc_read_arg:
    call read_stdin_byte
    li t0, 0x0A              # newline
    beq a0, t0, hoc_arg_done
    sb a0, 0(s3)
    addi s3, s3, 1
    j hoc_read_arg
hoc_arg_done:
    sb zero, 0(s3)           # null-terminate argument

    # Print command name + space + arg + newline
    mv a0, s1
    call print_string
    li a0, 0x20
    call sbi_putchar
    mv a0, s2
    call print_string
    li a0, 0x0A
    call sbi_putchar

    # Set up argv in global data: cmd_args at globals+0x58
    # argv[0] = command name, argv[1] = arg, argv[2] = NULL
    lui t0, 0x40180
    slli t0, t0, 1
    sd s1, 0x58(t0)          # argv[0]
    sd s2, 0x60(t0)          # argv[1]
    sd zero, 0x68(t0)        # argv[2] = NULL
    sd zero, 0x70(t0)        # envp[0] = NULL

    # Resolve command name to absolute path
    mv a0, s1
    call absolute_path
    mv s1, a0

    # Find executable file
    call find_file
    bltz a0, hoc_not_found
    mv s3, a0                # s3 = file index

    # Get file address and length
    lui t0, 0x50410
    slli t0, t0, 1
    slli t1, s3, 4
    add t0, t0, t1
    ld s3, 0(t0)             # s3 = file address
    ld s4, 8(t0)             # s4 = file length

    # Increment next_process_num
    lui t0, 0x40180
    slli t0, t0, 1
    ld t1, 0x20(t0)
    addi t1, t1, 1
    sd t1, 0x20(t0)

    # Get process descriptor for new process
    call get_process_base
    mv s5, a0                # s5 = proc descriptor

    # Copy cwd from previous process
    lui t0, 1
    sub t0, s5, t0           # prev proc
    addi t1, t0, 0x100       # prev cwd
    addi t2, s5, 0x100       # new cwd
    li t3, 256
hoc_copy_cwd:
    beqz t3, hoc_cwd_done
    lbu t4, 0(t1)
    sb t4, 0(t2)
    addi t1, t1, 1
    addi t2, t2, 1
    addi t3, t3, -1
    j hoc_copy_cwd
hoc_cwd_done:

    # Clear open file descriptors
    addi a0, s5, 0x200
    li a1, 0xE00
    call memset_zero

    # Parse 64-bit ELF header
    ld s6, 0x18(s3)          # entry point (VA)
    ld t0, 0x20(s3)          # e_phoff
    add s4, s3, t0           # s4 = first phdr address
    lhu s0, 0x38(s3)         # s0 = e_phnum

    # Zero 2MB of user process area at PA 0x80600000
    lui a0, 0x40300
    slli a0, a0, 1
    lui a1, 0x200
    call memset_zero

    # Reset brk
    lui t0, 0x40180
    slli t0, t0, 1
    lui t1, 0x40380
    slli t1, t1, 1           # 0x80700000
    sd t1, 0x40(t0)

    # Load program headers
hoc_load_phdr:
    beqz s0, hoc_load_done
    lw t0, 0(s4)             # p_type
    li t1, 1                 # PT_LOAD
    bne t0, t1, hoc_next_phdr

    ld t0, 0x08(s4)          # p_offset
    add a1, s3, t0           # src = file + p_offset
    ld t0, 0x10(s4)          # p_vaddr (VA)
    lui t1, 0x40000
    slli t1, t1, 1
    add a0, t0, t1           # dest = PA = VA + 0x80000000
    ld a2, 0x20(s4)          # p_filesz
    call memcpy

    # Update brk = max(brk, end_of_segment_PA + padding)
    ld t0, 0x10(s4)
    ld t1, 0x20(s4)
    add t0, t0, t1           # end VA
    lui t1, 0x40000
    slli t1, t1, 1
    add t0, t0, t1           # end PA
    lui t1, 2
    add t0, t0, t1           # +0x2000 padding
    lui t1, 0x40180
    slli t1, t1, 1
    ld t2, 0x40(t1)
    bge t2, t0, hoc_next_phdr
    sd t0, 0x40(t1)

hoc_next_phdr:
    addi s4, s4, 56
    addi s0, s0, -1
    j hoc_load_phdr

hoc_load_done:
    # Set process_address
    lui t0, 0x40300
    slli t0, t0, 1
    sd t0, 0(s5)

    # Clear forked flag
    sd zero, 0x20(s5)

    # Save current sp at proc[1]+0x10 (fixed location for shell return)
    lui t0, 0x40200
    slli t0, t0, 1
    lui t1, 1
    add t0, t0, t1           # proc[1] = 0x80401000
    sd sp, 0x10(t0)

    # Set up user stack at PA 0x90000000 (VA 0x10000000)
    lui t0, 0x48000
    slli s0, t0, 1           # s0 = 0x90000000

    # Push NULL (envp terminator)
    addi s0, s0, -8
    sd zero, 0(s0)

    # Push NULL (argv terminator)
    addi s0, s0, -8
    sd zero, 0(s0)

    # Push argv[1] VA = arg string
    # arg is at PA s2 = 0xA0000C00. But user needs VA.
    # Copy arg to user-accessible area at PA 0x8FF00000 (VA 0x0FF00000)
    lui t0, 0x47F80
    slli s3, t0, 1           # s3 = 0x8FF00000
    mv a0, s3                # dest
    mv a1, s2                # src (arg string at PA)
    li a2, 256
    call memcpy
    # VA of arg = 0x0FF00000
    lui t0, 0x40000
    slli t0, t0, 1
    sub t0, s3, t0           # VA = PA - 0x80000000
    addi s0, s0, -8
    sd t0, 0(s0)             # argv[1] = VA of arg

    # Push argv[0] VA = command name
    # Copy command name to PA 0x8FF00100 (VA 0x0FF00100)
    addi s4, s3, 0x100       # PA
    mv a0, s4
    mv a1, s1                # src (command name at PA)
    li a2, 256
    call memcpy
    lui t0, 0x40000
    slli t0, t0, 1
    sub t0, s4, t0           # VA
    addi s0, s0, -8
    sd t0, 0(s0)             # argv[0] = VA of cmd name

    # Push argc = 2
    addi s0, s0, -8
    li t0, 2
    sd t0, 0(s0)

    # User stack VA = PA - 0x80000000
    lui t0, 0x40000
    slli t0, t0, 1
    sub s0, s0, t0           # s0 = user stack VA

    # --- Transition to U-mode ---
    fence
    fence.i

    # Clear SPP (bit 8), SPIE (bit 5), SIE (bit 1) in sstatus
    li t0, 0x122
    csrrc zero, sstatus, t0

    # Set sepc = entry point VA (s6)
    csrrw zero, sepc, s6

    # Set sscratch = sp (kernel stack, for trap handler)
    csrrw zero, sscratch, sp

    # Enable paging
    lui t0, 0x40180
    slli t0, t0, 1
    ld t0, 0x78(t0)          # satp_value
    csrrw zero, satp, t0
    sfence.vma

    # Set sp = user stack VA and sret
    mv sp, s0
    sret

    # --- We never reach here directly ---
    # When the user program calls exit, syscall_exit runs.
    # exit_to_shell restores sp from proc descriptor and does ret.
    # That ret returns here (to the instruction after the call that
    # led us here... but we used 'j', not 'call').
    # Actually, exit_to_shell loads sp from proc+0x10 and does ret.
    # Since we saved sp BEFORE sret, ret will pop ra from that sp.
    # But ra on the kernel stack at that point is... from the call
    # chain that led to handle_other_command.
    # handle_other_command was jumped to from shell_loop (j instruction).
    # So ra is still whatever internalshell set. This won't work.
    # We need to save a return address.

    # Let me fix this: instead of saving sp, save sp and put a
    # known return address. After exit_to_shell does ret,
    # we need to end up back at shell_loop.

    # The fix: exit_to_shell will jump to shell_return instead of ret.

hoc_not_found:
    # Print "?\n"
    li a0, 0x3F
    call sbi_putchar
    li a0, 0x0A
    call sbi_putchar
    j shell_loop

# Return point after user program exits
shell_return:
    # Disable paging (we're back in S-mode)
    csrrw zero, satp, zero
    sfence.vma
    j shell_loop

#============================================================
# flush_disk: Write /dev/hda file contents back to disk
#============================================================
flush_disk:
    addi sp, sp, -32
    sd ra, 0(sp)
    sd s0, 8(sp)
    sd s1, 16(sp)
    sd s2, 24(sp)

    # Find /dev/hda
    lui a0, 0x50000
    slli a0, a0, 1           # scratch = 0xA0000000
    li t0, 0x2F              # '/'
    sb t0, 0(a0)
    li t0, 0x64              # 'd'
    sb t0, 1(a0)
    li t0, 0x65              # 'e'
    sb t0, 2(a0)
    li t0, 0x76              # 'v'
    sb t0, 3(a0)
    li t0, 0x2F              # '/'
    sb t0, 4(a0)
    li t0, 0x68              # 'h'
    sb t0, 5(a0)
    li t0, 0x64              # 'd'
    sb t0, 6(a0)
    li t0, 0x61              # 'a'
    sb t0, 7(a0)
    sb zero, 8(a0)
    call find_file
    bltz a0, flush_done

    # Get file address and length
    lui t0, 0x50410
    slli t0, t0, 1
    slli t1, a0, 4
    add t0, t0, t1
    ld s0, 0(t0)             # file_address
    ld s1, 8(t0)             # file_length

    # Write sector by sector
    li s2, 0                 # sector number
flush_sector_loop:
    blez s1, flush_done

    # Write 512 bytes from s0 to disk sector s2
    mv a0, s2                # sector number
    mv a1, s0                # source buffer
    call disk_write_sector

    addi s0, s0, 512
    addi s1, s1, -512
    addi s2, s2, 1
    j flush_sector_loop

flush_done:
    ld ra, 0(sp)
    ld s0, 8(sp)
    ld s1, 16(sp)
    ld s2, 24(sp)
    addi sp, sp, 32
    ret

#============================================================
# main: Boot sequence
#============================================================
main:
    # Set sp = 0xA8000000 (kernel stack top)
    lui t0, 0x54000
    slli sp, t0, 1

    # Save a0 = stdin_sector and a1 = DTB pointer from stage1
    mv s6, a0
    mv s7, a1

    # Load RAM base into s2 = 0x80210000
    call load_ram_base

    # Set up trap handler early (before any MMIO access)
    addi t0, s2, 4
    csrrw zero, stvec, t0
    # Set sscratch = kernel stack top (needed for trap handler)
    csrrw zero, sscratch, sp
    # Disable all S-mode interrupts (timer, external, software)
    csrrw zero, sie, zero

    # Parse device tree to find storage device
    mv a0, s7
    call fdt_find_storage        # a0 = MMIO base, a1 = type

    # Dispatch to appropriate storage driver
    li t0, 1
    beq a1, t0, init_virtio      # type 1 = VirtIO
    li t0, 2
    beq a1, t0, init_spi_sd      # type 2 = SPI+SD
    j reboot                      # unknown storage: reboot (halt)

init_virtio:
    call virtio_init
    j storage_ready

init_spi_sd:
    call spi_sd_init

storage_ready:

    # --- Initialize filesystem ---

    # Initialize global data
    lui t0, 0x40180
    slli t0, t0, 1            # t0 = 0x80300000

    # next_filenum = 3 (files 0-2 reserved)
    li t1, 3
    sd t1, 0x10(t0)

    # next_file_address = 0xD4000000
    lui t1, 0x6A000
    slli t1, t1, 1
    sd t1, 0x18(t0)

    # next_process_num = 1
    li t1, 1
    sd t1, 0x20(t0)

    # next_save_process_address = 0xB0000000
    lui t1, 0x58000
    slli t1, t1, 1
    sd t1, 0x28(t0)

    # enable_flush = 0
    sd zero, 0x48(t0)

    # have_userspace = 0
    sd zero, 0x50(t0)

    # Store DTB pointer in globals for future use
    sd s7, 0x80(t0)

    # Initialize brk = 0x80700000 (PA, 1MB above ELF base)
    lui t1, 0x40380
    slli t1, t1, 1            # t1 = 0x80700000
    sd t1, 0x40(t0)

    # Initialize stdin_sector from stage1 (a0 saved in s6), offset = 512 (force first read)
    sd s6, 0x30(t0)
    li t1, 512
    sd t1, 0x38(t0)

    # Zero process descriptors (16 * 4096 = 64KB at 0x80400000)
    lui a0, 0x40200
    slli a0, a0, 1
    lui a1, 0x10
    call memset_zero

    # Zero file names area (8MB at 0x80800000)
    lui a0, 0x50010
    slli a0, a0, 1
    lui a1, 0x800
    call memset_zero

    # Zero file descriptors area (512KB at 0x81000000)
    lui a0, 0x50410
    slli a0, a0, 1
    lui a1, 0x80
    call memset_zero

    # Set process 0 current_dir = "/"
    lui t0, 0x40200
    slli t0, t0, 1
    li t1, 0x2F
    sb t1, 0x100(t0)
    sb zero, 0x101(t0)
    # Also set process 1 current_dir = "/"
    lui t2, 1
    add t0, t0, t2
    sb t1, 0x100(t0)
    sb zero, 0x101(t0)

    # Set up trap handler
    # stvec = s2 + 4 (trap_handler is at offset 4 from _start)
    addi t0, s2, 4
    csrrw zero, stvec, t0

    # Set up Sv39 page table
    call setup_page_table

    # Jump to internal shell
    j internalshell
