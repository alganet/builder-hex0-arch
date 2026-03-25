; SPDX-FileCopyrightText: 2026 Alexandre Gomes Gaigalas <alganet@gmail.com>
; SPDX-License-Identifier: Apache-2.0
;
; Builder-hex0 AArch64 Stage 2
;
; A minimal kernel for bootstrapping compilers from source on AArch64.
; Inspired by builder-hex0 (https://github.com/ironmeld/builder-hex0).
;
; Boot: qemu-system-aarch64 -machine virt -cpu cortex-a53 -m 2G -nographic \
;       -kernel builder-hex0-aarch64-stage1-virt.bin \
;       -drive file=disk.img,format=raw,if=none,id=hd0 \
;       -device virtio-blk-device,drive=hd0 --no-reboot
;
; Compiled by stage 1 from hex0 source on disk to 0x40210000.
; On entry: x0 = next disk sector (filesystem start), x1 = DTB pointer
;
; Memory layout (physical addresses):
;   0x40100000  Page table (4KB aligned, level 1)
;   0x40210000  Kernel code (base)
;   0x40300000  Kernel global data (variables)
;   0x40500000  VirtIO structures (desc/avail/used/buffers)
;   0x40600000  User process area (VA 0x00600000 via page table)
;   0x50000000  User stack top (VA 0x10000000, grows down)
;   0x60000000  Scratch buffer (64KB)
;   0x60010000  stdin device buffer (64KB)
;   0x60900000  File names (16MB, 16384 entries x 1024 bytes)
;   0x60400000  Process descriptors (16 x 4096)
;   0x60820000  File descriptors (512KB, 32768 x 16 bytes)
;   0x7B800000  Kernel stack top (grows down)
;   0x42000000  Preload buffer (8MB, raspi3b only, PA 0x02000000 slow zone)
;   0x78000000  Saved process memory (bump allocator)
;   0xA1900000  File data (bump allocator, grows up to 0xBFFFFFFF)
;
; AArch64 paging (1GB block descriptors, level 1 table):
;   Entry 0: VA 0x00000000-0x3FFFFFFF -> PA 0x40000000 (User, Normal memory)
;   Entry 1: VA 0x40000000-0x7FFFFFFF -> PA 0x40000000 (Kernel, Normal memory)
;   Entry 2: VA 0x80000000-0xBFFFFFFF -> PA 0x80000000 (Kernel, Normal, upper RAM)
;   Entry 3: VA 0xC0000000-0xFFFFFFFF -> PA 0x00000000 (Device nGnRE, MMIO)
;   MMU stays on during kernel execution. Entry 3 maps MMIO at VA 0xC0000000+.
;
; Global data at 0x40300000:
;   +0x000: storage_mmio_base (8 bytes)
;   +0x008: virtio_struct_base (8 bytes)
;   +0x010: next_filenum (8 bytes)
;   +0x018: next_file_address (8 bytes)
;   +0x020: next_process_num (8 bytes)
;   +0x028: next_save_process_address (8 bytes)
;   +0x030: stdin_sector (8 bytes)
;   +0x038: stdin_offset (8 bytes)
;   +0x040: current_brk (8 bytes)
;   +0x048: enable_flush (8 bytes)
;   +0x050: have_userspace (8 bytes)
;   +0x058: cmd_args (3x8: argv[0], argv[1], NULL)
;   +0x070: cmd_env (1x8: NULL)
;   +0x078: stdin_buf_ptr (8 bytes, preload buffer pointer)
;   +0x080: dtb_pointer (8 bytes)
;   +0x088: disk_read_fn (8 bytes)
;   +0x090: disk_write_fn (8 bytes)
;   +0x098: spi_base (8 bytes)
;   +0x0A0: uart_base (8 bytes)
;   +0x0A8: board_has_sdhci (8 bytes)
;
; Process descriptor (4096 bytes each, at 0x60400000):
;   +0x000: process_address (8)
;   +0x008: brk (8)
;   +0x010: saved_stack_pointer (8)
;   +0x018: saved_stack_pointer_fork (8)
;   +0x020: forked (8)
;   +0x028: saved_brk (8)
;   +0x030: child_exit_code (8)
;   +0x038: saved_process_mem_addr (8)
;   +0x040: saved_process_mem_len (8)
;   +0x048: saved_stack_addr (8)
;   +0x050: saved_stack_len (8)
;   +0x058: saved_user_stack_addr (8)
;   +0x060: saved_user_stack_len (8)
;   +0x100: current_dir (256 bytes)
;   +0x200: open_files (448 entries x 8 bytes)
;
; Register conventions:
;   x19-x28 = callee-saved (s0-s9 equivalent)
;   x9-x15  = caller-saved temporaries (t0-t6 equivalent)
;   x0-x7   = arguments/return (a0-a7 equivalent)
;   x8      = syscall number
;   x30/lr  = link register (ra equivalent)
;   sp      = stack pointer
;
; Trap frame layout (272 bytes, 16-byte aligned):
;   offset 0:   x0  (arg0 / return value)
;   offset 8:   x1  (arg1)
;   offset 16:  x2  (arg2)
;   offset 24:  x3  (arg3)
;   offset 32:  x4
;   offset 40:  x5
;   offset 48:  x6
;   offset 56:  x7
;   offset 64:  x8  (syscall number)
;   offset 72:  x9
;   offset 80:  x10
;   offset 88:  x11
;   offset 96:  x12
;   offset 104: x13
;   offset 112: x14
;   offset 120: x15
;   offset 128: x16
;   offset 136: x17
;   offset 144: x18
;   offset 152: x19
;   offset 160: x20
;   offset 168: x21
;   offset 176: x22
;   offset 184: x23
;   offset 192: x24
;   offset 200: x25
;   offset 208: x26
;   offset 216: x27
;   offset 224: x28
;   offset 232: x29
;   offset 240: x30
;   offset 248: SP_EL0
;   offset 256: ELR_EL1
;   offset 264: padding (alignment)

_start:
    b _trampoline

;============================================================
; Exception vector table (must be 2KB aligned)
; 16 entries x 128 bytes each = 2048 bytes
; We only handle Lower EL AArch64 Synchronous (offset 0x400)
;============================================================
.align 11
exception_vectors:
    ; Current EL with SP_EL0 - Synchronous
    b reboot
    .align 7
    ; Current EL with SP_EL0 - IRQ
    b reboot
    .align 7
    ; Current EL with SP_EL0 - FIQ
    b reboot
    .align 7
    ; Current EL with SP_EL0 - SError
    b reboot
    .align 7

    ; Current EL with SP_ELx - Synchronous
    b reboot
    .align 7
    ; Current EL with SP_ELx - IRQ
    b reboot
    .align 7
    ; Current EL with SP_ELx - FIQ
    b reboot
    .align 7
    ; Current EL with SP_ELx - SError
    b reboot
    .align 7

    ; Lower EL AArch64 - Synchronous (SVC handler) - offset 0x400
    b trap_handler
    .align 7
    ; Lower EL AArch64 - IRQ
    b reboot
    .align 7
    ; Lower EL AArch64 - FIQ
    b reboot
    .align 7
    ; Lower EL AArch64 - SError
    b reboot
    .align 7

    ; Lower EL AArch32 - Synchronous
    b reboot
    .align 7
    ; Lower EL AArch32 - IRQ
    b reboot
    .align 7
    ; Lower EL AArch32 - FIQ
    b reboot
    .align 7
    ; Lower EL AArch32 - SError
    b reboot
    .align 7

;============================================================
; Trap handler
; Entered on SVC from EL0. CPU auto-saves PC to ELR_EL1,
; PSTATE to SPSR_EL1, switches to SP_EL1.
;============================================================
trap_handler:
    ; Save x9 before using it as scratch (push to stack temporarily)
    sub sp, sp, #272
    str x9, [sp, #72]

    ; Save all general-purpose registers
    str x0, [sp, #0]
    str x1, [sp, #8]
    str x2, [sp, #16]
    str x3, [sp, #24]
    str x4, [sp, #32]
    str x5, [sp, #40]
    str x6, [sp, #48]
    str x7, [sp, #56]
    str x8, [sp, #64]
    ; x9 already saved above
    str x10, [sp, #80]
    str x11, [sp, #88]
    str x12, [sp, #96]
    str x13, [sp, #104]
    str x14, [sp, #112]
    str x15, [sp, #120]
    str x16, [sp, #128]
    str x17, [sp, #136]
    str x18, [sp, #144]
    str x19, [sp, #152]
    str x20, [sp, #160]
    str x21, [sp, #168]
    str x22, [sp, #176]
    str x23, [sp, #184]
    str x24, [sp, #192]
    str x25, [sp, #200]
    str x26, [sp, #208]
    str x27, [sp, #216]
    str x28, [sp, #224]
    str x29, [sp, #232]
    str x30, [sp, #240]

    ; Save user SP
    mrs x9, sp_el0
    str x9, [sp, #248]

    ; Save return address
    mrs x9, elr_el1
    str x9, [sp, #256]

    ; Check ESR_EL1 for SVC from AArch64 (EC=0x15)
    mrs x9, esr_el1
    lsr x9, x9, #26
    cmp x9, #0x15
    b.eq dispatch

    ; Not SVC: print crash info and terminate with exit code 139
    mrs x20, esr_el1
    mrs x21, elr_el1
    mrs x22, far_el1
    mrs x23, sp_el0
    mov x0, #0x21                 ; '!'
    bl uart_putchar
    lsr x0, x20, #26             ; exception class
    bl print_hex_byte
    mov x0, #0x3A
    bl uart_putchar
    mov x0, x21                  ; ELR
    bl print_hex32
    mov x0, #0x40                ; '@'
    bl uart_putchar
    mov x0, x22                  ; FAR
    bl print_hex32
    mov x0, #0x2C                ; ','
    bl uart_putchar
    mov x0, x23                  ; SP_EL0
    bl print_hex32
    mov x0, #0x2C                ; ','
    bl uart_putchar
    ldr x0, [sp, #240]           ; x30 from trap frame
    bl print_hex32
    mov x0, #0x2C                ; ','
    bl uart_putchar
    movz x9, #0x4030, lsl #16
    ldr x0, [x9, #0x18]         ; next_file_address
    bl print_hex32
    mov x0, #0x0A
    bl uart_putchar
    mov x9, #139
    str x9, [sp, #0]
    b syscall_exit

; Dispatch syscall based on x8
dispatch:
    ldr x8, [sp, #64]
    cmp x8, #64
    b.eq tramp_write
    cmp x8, #93
    b.eq tramp_exit
    cmp x8, #214
    b.eq tramp_brk
    cmp x8, #63
    b.eq tramp_read
    cmp x8, #56
    b.eq tramp_openat
    cmp x8, #57
    b.eq tramp_close
    cmp x8, #62
    b.eq tramp_lseek
    cmp x8, #49
    b.eq tramp_chdir
    cmp x8, #17
    b.eq tramp_getcwd
    cmp x8, #48
    b.eq tramp_faccessat
    cmp x8, #34
    b.eq tramp_mkdirat
    cmp x8, #220
    b.eq tramp_clone
    cmp x8, #221
    b.eq tramp_execve
    cmp x8, #95
    b.eq tramp_waitid
    movz x9, #260
    cmp x8, x9
    b.eq tramp_wait4
    cmp x8, #96
    b.eq tramp_stub
    cmp x8, #29
    b.eq tramp_stub
    cmp x8, #53
    b.eq tramp_stub

    movn x9, #0
    str x9, [sp, #0]
    b trap_exit

; Trampolines
tramp_write:
    b syscall_write
tramp_exit:
    b syscall_exit
tramp_brk:
    b syscall_brk
tramp_read:
    b syscall_read
tramp_openat:
    b syscall_openat
tramp_close:
    b syscall_close
tramp_lseek:
    b syscall_lseek
tramp_chdir:
    b syscall_chdir
tramp_getcwd:
    b syscall_getcwd
tramp_faccessat:
    b syscall_faccessat
tramp_mkdirat:
    b syscall_mkdirat
tramp_clone:
    b syscall_clone
tramp_execve:
    b syscall_execve
tramp_waitid:
    b syscall_waitid
tramp_wait4:
    b syscall_wait4
tramp_stub:
    b syscall_stub_zero

;============================================================
; trap_exit: Restore all registers and eret
; NOTE: No ELR_EL1 += 4 needed (AArch64 SVC returns to next insn)
;============================================================
trap_exit:
    ; Restore ELR_EL1
    ldr x9, [sp, #256]
    msr elr_el1, x9

    ; Restore user SP
    ldr x9, [sp, #248]
    msr sp_el0, x9

    ; Set SPSR_EL1 = 0 (return to EL0, AArch64, interrupts unmasked)
    movz x9, #0
    msr spsr_el1, x9

    ; Restore all registers
    ldr x0, [sp, #0]
    ldr x1, [sp, #8]
    ldr x2, [sp, #16]
    ldr x3, [sp, #24]
    ldr x4, [sp, #32]
    ldr x5, [sp, #40]
    ldr x6, [sp, #48]
    ldr x7, [sp, #56]
    ldr x8, [sp, #64]
    ; x9 restored last (used as scratch)
    ldr x10, [sp, #80]
    ldr x11, [sp, #88]
    ldr x12, [sp, #96]
    ldr x13, [sp, #104]
    ldr x14, [sp, #112]
    ldr x15, [sp, #120]
    ldr x16, [sp, #128]
    ldr x17, [sp, #136]
    ldr x18, [sp, #144]
    ldr x19, [sp, #152]
    ldr x20, [sp, #160]
    ldr x21, [sp, #168]
    ldr x22, [sp, #176]
    ldr x23, [sp, #184]
    ldr x24, [sp, #192]
    ldr x25, [sp, #200]
    ldr x26, [sp, #208]
    ldr x27, [sp, #216]
    ldr x28, [sp, #224]
    ldr x29, [sp, #232]
    ldr x30, [sp, #240]

    ; Deallocate frame and restore x9
    ldr x9, [sp, #72]
    add sp, sp, #272

    eret

;============================================================
; syscall_write: write(fd, buf, count) -> count
; x0(0)=fd, x1(8)=buf, x2(16)=count
;============================================================
syscall_write:
    ; Load args from trap frame
    ldr x21, [sp, #0]            ; fd
    ldr x22, [sp, #8]            ; buf (VA)
    ldr x23, [sp, #16]           ; count
    mov x24, x23                 ; save original count

    ; Translate buf VA -> PA: PA = VA + 0x40000000
    movz x9, #0x4000, lsl #16
    add x22, x22, x9

    ; If fd <= 2, write to console
    cmp x21, #3
    b.lt write_console
    b write_file

write_console:
write_loop:
    cbz x23, write_done
    ldrb w0, [x22]
    bl uart_putchar
    add x22, x22, #1
    sub x23, x23, #1
    b write_loop

write_done:
    str x24, [sp, #0]
    b trap_exit

write_file:
    ; x21=fd, x22=buf, x23=count, x24=original count
    ; Get file info from process fd table
    mov x0, x21
    bl fd_to_file_index
    mov x25, x0                  ; x25 = global file index

    ; Get file_address and file_length from global descriptor
    movz x9, #0x6082, lsl #16    ; 0x60820000
    lsl x10, x25, #4             ; index * 16
    add x26, x9, x10             ; x26 = &global_fd[file_index]
    ldr x27, [x26, #0]           ; file_address
    ldr x28, [x26, #8]           ; file_length

    ; Get current_offset from process fd
    bl get_process_base
    add x0, x0, #0x200
    lsl x9, x21, #3
    add x19, x0, x9              ; x19 = &open_files[fd]
    ldr w21, [x19, #4]           ; current_offset (reuse x21, fd no longer needed)

write_file_loop:
    cbz x23, write_file_done

    ; Copy byte from user buf to file
    ldrb w9, [x22]
    add x10, x27, x21            ; dest = file_address + offset
    strb w9, [x10]

    add x22, x22, #1
    add x21, x21, #1             ; offset++
    sub x23, x23, #1

    ; If offset > file_length, extend file
    cmp x28, x21
    b.ge write_file_loop

    ; Extend: file_length = offset
    mov x28, x21
    str x28, [x26, #8]           ; update file_length

    ; Also advance next_file_address
    movz x9, #0x4030, lsl #16
    ldr x10, [x9, #0x18]
    add x10, x10, #1
    str x10, [x9, #0x18]         ; next_file_address++

    b write_file_loop

write_file_done:
    ; Update current_offset in process fd
    str w21, [x19, #4]
    ; Return original count
    str x24, [sp, #0]
    b trap_exit

;============================================================
; syscall_brk: brk(addr) -> addr
; x0(0)=addr. If addr==0, return current brk.
;============================================================
syscall_brk:
    ldr x9, [sp, #0]             ; requested addr (VA, or 0)

    ; Global data at 0x40300000
    movz x10, #0x4030, lsl #16
    ldr x11, [x10, #0x40]        ; current brk (PA)

    cbz x9, brk_return_current

    ; Convert VA to PA: PA = VA + 0x40000000
    movz x12, #0x4000, lsl #16
    add x9, x9, x12              ; PA = new brk

    ; Zero memory from old brk to new brk if extending
    cmp x11, x9
    b.ge brk_store
    mov x13, x11                 ; x13 = cursor = old brk (PA)
brk_zero_loop:
    cmp x13, x9
    b.ge brk_store
    strb wzr, [x13]
    add x13, x13, #1
    b brk_zero_loop

brk_store:
    str x9, [x10, #0x40]         ; store new brk (PA)
    ; Return VA to user
    sub x9, x9, x12
    str x9, [sp, #0]
    b trap_exit

brk_return_current:
    ; Return current brk as VA = PA - 0x40000000
    movz x12, #0x4000, lsl #16
    sub x11, x11, x12
    str x11, [sp, #0]
    b trap_exit

;============================================================
; syscall_read: read(fd, buf, count) -> bytes_read
; x0(0)=fd, x1(8)=buf, x2(16)=count
;============================================================
syscall_read:
    ldr x21, [sp, #0]            ; fd
    ldr x22, [sp, #8]            ; buf (VA)
    ldr x23, [sp, #16]           ; count
    mov x24, x23                 ; save original count

    ; Translate buf VA -> PA
    movz x9, #0x4000, lsl #16
    add x22, x22, x9

    cbnz x21, read_file          ; if fd != 0, read from file

    ; Read from stdin (disk)
read_stdin_loop:
    cbz x23, read_stdin_done

    ; Load global data base
    movz x9, #0x4030, lsl #16
    ldr x10, [x9, #0x30]         ; stdin_sector
    ldr x11, [x9, #0x38]         ; stdin_offset

    ; stdin buffer at 0x60010000
    movz x0, #0x6001, lsl #16

    ; If offset >= 512, read next sector
    cmp x11, #512
    b.lt read_stdin_have_data

    ; Read next sector
    mov x0, x10                  ; sector number
    movz x1, #0x6001, lsl #16    ; buffer = 0x60010000
    bl disk_read_sector
    ; Advance sector, reset offset
    movz x9, #0x4030, lsl #16
    ldr x10, [x9, #0x30]
    add x10, x10, #1
    str x10, [x9, #0x30]         ; stdin_sector++
    str xzr, [x9, #0x38]         ; stdin_offset = 0
    mov x11, #0                  ; x11 = offset = 0

read_stdin_have_data:
    ; Read one byte from stdin buffer
    movz x0, #0x6001, lsl #16
    add x0, x0, x11              ; buffer + offset
    ldrb w12, [x0]               ; byte

    ; Store to user buffer
    strb w12, [x22]
    add x22, x22, #1
    sub x23, x23, #1

    ; Update stdin_offset
    movz x9, #0x4030, lsl #16
    ldr x11, [x9, #0x38]
    add x11, x11, #1
    str x11, [x9, #0x38]

    b read_stdin_loop

read_stdin_done:
    str x24, [sp, #0]            ; return original count
    b trap_exit

read_file:
    ; x21=fd, x22=buf, x23=count
    ; Get file info from process fd table
    mov x0, x21
    bl fd_to_file_index
    mov x25, x0                  ; x25 = global file index

    ; Get file_address and file_length from global descriptor
    movz x9, #0x6082, lsl #16    ; 0x60820000
    lsl x10, x25, #4
    add x9, x9, x10
    ldr x26, [x9, #0]            ; file_address
    ldr x27, [x9, #8]            ; file_length

    ; Get current_offset from process fd
    bl get_process_base
    add x0, x0, #0x200
    lsl x9, x21, #3
    add x28, x0, x9              ; x28 = &open_files[fd]
    ldr w19, [x28, #4]           ; current_offset

    ; Read loop
    mov x24, #0                  ; bytes read

read_file_loop:
    cbz x23, read_file_done
    ; Check if offset >= length (EOF)
    cmp x19, x27
    b.ge read_file_done

    ; Copy one byte
    add x9, x26, x19             ; src = file_address + offset
    ldrb w10, [x9]
    strb w10, [x22]
    add x22, x22, #1
    add x19, x19, #1
    sub x23, x23, #1
    add x24, x24, #1
    b read_file_loop

read_file_done:
    ; Update current_offset
    str w19, [x28, #4]

    ; Return bytes read
    str x24, [sp, #0]
    b trap_exit

;============================================================
; syscall_openat: openat(dirfd, pathname, flags, mode)
; x0(0)=dirfd(ignored), x1(8)=pathname, x2(16)=flags
; Returns: fd number or -1
;============================================================
syscall_openat:
    ldr x21, [sp, #8]            ; pathname (x1, VA)
    ldr x22, [sp, #16]           ; flags (x2)

    ; Translate pathname VA -> PA
    movz x9, #0x4000, lsl #16
    add x21, x21, x9

    ; Resolve to absolute path
    mov x0, x21
    bl absolute_path
    mov x21, x0                  ; x21 = absolute path in scratch buffer

    ; Check O_CREAT (bit 6 = 0x40)
    and x9, x22, #0x40
    cbnz x9, openat_create

    ; Open existing file
    mov x0, x21
    bl find_file
    cmp x0, #0
    b.lt openat_fail
    mov x23, x0                  ; x23 = file index

    b openat_alloc_fd

openat_create:
    ; Check parent directory exists
    ; Find last '/' in path
    mov x9, x21
    mov x10, x21                 ; x10 = last slash position (default: start)
openat_find_slash:
    ldrb w11, [x9]
    cbz w11, openat_check_parent
    cmp w11, #0x2F
    b.ne openat_next_char
    mov x10, x9
openat_next_char:
    add x9, x9, #1
    b openat_find_slash

openat_check_parent:
    ; If slash is first char, parent is root (always exists)
    cmp x10, x21
    b.eq openat_do_create

    ; Temporarily null-terminate at last slash
    mov x25, x10                 ; save slash position
    ldrb w24, [x25]
    strb wzr, [x25]
    mov x0, x21
    bl find_file
    strb w24, [x25]              ; restore slash
    cmp x0, #0
    b.lt openat_fail

openat_do_create:
    ; Allocate new file entry
    movz x9, #0x4030, lsl #16    ; globals base
    ldr x23, [x9, #0x10]         ; x23 = next_filenum (our new file index)

    ; Copy filename to file names table
    ; dest = 0x60900000 + x23 * 1024
    movz x10, #0x6090, lsl #16
    lsl x11, x23, #10
    add x10, x10, x11            ; destination
    mov x11, x21                 ; source
openat_copy_name:
    ldrb w12, [x11]
    strb w12, [x10]
    cbz w12, openat_name_done
    add x10, x10, #1
    add x11, x11, #1
    b openat_copy_name
openat_name_done:

    ; Set up global file descriptor
    ; fd_entry = 0x60820000 + x23 * 16
    movz x9, #0x6082, lsl #16
    lsl x10, x23, #4
    add x9, x9, x10

    ; file_address = next_file_address (aligned to 8 for ELF compatibility)
    movz x10, #0x4030, lsl #16
    ldr x11, [x10, #0x18]        ; next_file_address
    add x11, x11, #7
    and x11, x11, #0xFFFFFFFFFFFFFFF8
    str x11, [x10, #0x18]        ; store aligned next_file_address
    str x11, [x9, #0]            ; store file_address
    str xzr, [x9, #8]            ; file_length = 0

    ; Increment next_filenum
    ldr x11, [x10, #0x10]
    add x11, x11, #1
    str x11, [x10, #0x10]

openat_alloc_fd:
    ; Allocate a process fd slot (start from fd 4)
    bl get_process_base
    add x0, x0, #0x200           ; open_files array
    mov x9, #4                   ; start fd
    mov x10, #448                ; max entries
openat_find_fd:
    cmp x9, x10
    b.ge openat_fail
    lsl x11, x9, #3              ; fd * 8
    add x11, x0, x11
    ldr w12, [x11]               ; global_file_index
    cbz w12, openat_got_fd
    add x9, x9, #1
    b openat_find_fd

openat_got_fd:
    ; Store file index and reset offset
    str w23, [x11]               ; global_file_index
    str wzr, [x11, #4]           ; current_offset = 0
    ; Return fd
    str x9, [sp, #0]
    b trap_exit

openat_fail:
    movn x9, #0
    str x9, [sp, #0]
    b trap_exit

;============================================================
; syscall_close: close(fd) -> 0
; x0(0)=fd
;============================================================
syscall_close:
    ldr x21, [sp, #0]

    bl get_process_base
    add x0, x0, #0x200           ; open_files
    lsl x9, x21, #3
    add x0, x0, x9
    str wzr, [x0]                ; clear slot (mark free)

    str xzr, [sp, #0]            ; return 0
    b trap_exit

;============================================================
; syscall_lseek: lseek(fd, offset, whence) -> new_offset
; x0(0)=fd, x1(8)=offset, x2(16)=whence
;============================================================
syscall_lseek:
    ldr x21, [sp, #0]            ; fd
    ldr x22, [sp, #8]            ; offset
    ldr x23, [sp, #16]           ; whence

    bl get_process_base
    add x0, x0, #0x200
    lsl x9, x21, #3
    add x24, x0, x9              ; x24 = &open_files[fd]

    ; SEEK_SET (whence == 0)
    cbnz x23, lseek_not_set
    str w22, [x24, #4]
    str x22, [sp, #0]
    b trap_exit

lseek_not_set:
    cmp x23, #1
    b.ne lseek_end

    ; SEEK_CUR (whence == 1)
    ldr w9, [x24, #4]
    add x9, x9, x22
    str w9, [x24, #4]
    str x9, [sp, #0]
    b trap_exit

lseek_end:
    ; SEEK_END (whence == 2)
    ldr w9, [x24]                ; global file index
    movz x10, #0x6082, lsl #16   ; 0x60820000
    lsl x11, x9, #4
    add x10, x10, x11
    ldr x9, [x10, #8]            ; file_length
    add x9, x9, x22              ; length + offset
    str w9, [x24, #4]
    str x9, [sp, #0]
    b trap_exit

;============================================================
; syscall_chdir: chdir(path) -> 0 or -1
; x0(0)=path
;============================================================
syscall_chdir:
    ldr x21, [sp, #0]            ; path (VA)

    ; Translate VA -> PA
    movz x9, #0x4000, lsl #16
    add x21, x21, x9

    ; Resolve to absolute path
    mov x0, x21
    bl absolute_path
    mov x21, x0

    ; Special case: "/" always exists (skip find_file)
    ldrb w9, [x21]
    cmp w9, #0x2F
    b.ne chdir_find
    ldrb w9, [x21, #1]
    cbz w9, chdir_copy_path        ; "/" alone -> skip find_file

chdir_find:
    ; Find the file
    mov x0, x21
    bl find_file
    cmp x0, #0
    b.lt chdir_fail

    ; Check it's a directory (file_length == 0)
    movz x9, #0x6082, lsl #16
    lsl x10, x0, #4
    add x9, x9, x10
    ldr x10, [x9, #8]            ; file_length
    cbnz x10, chdir_fail         ; not a directory

chdir_copy_path:
    ; Copy path to process current_dir
    bl get_process_base
    add x22, x0, #0x100          ; dest = proc->current_dir

    mov x9, x21                  ; source
    mov x10, x22                 ; dest
    mov x12, #0                  ; track last char
chdir_copy:
    ldrb w11, [x9]
    strb w11, [x10]
    cbz w11, chdir_check_slash
    mov w12, w11
    add x9, x9, #1
    add x10, x10, #1
    b chdir_copy

chdir_check_slash:
    ; Append trailing '/' if not present
    cmp w12, #0x2F
    b.eq chdir_ok
    mov w11, #0x2F
    strb w11, [x10]
    add x10, x10, #1
    strb wzr, [x10]
chdir_ok:
    str xzr, [sp, #0]            ; return 0
    b trap_exit

chdir_fail:
    movn x9, #0
    str x9, [sp, #0]
    b trap_exit

;============================================================
; syscall_getcwd: getcwd(buf, size) -> buf or -1
; x0(0)=buf, x1(8)=size
;============================================================
syscall_getcwd:
    ldr x21, [sp, #0]            ; buf (VA)
    ldr x22, [sp, #8]            ; size

    ; Translate buf VA -> PA
    movz x9, #0x4000, lsl #16
    add x21, x21, x9

    bl get_process_base
    add x0, x0, #0x100           ; current_dir
    mov x9, x0                   ; src
    mov x10, x21                 ; dest

    ; Check for root "/"
    ldrb w11, [x9]
    cmp w11, #0x2F
    b.ne getcwd_copy
    ldrb w11, [x9, #1]
    cbnz w11, getcwd_copy
    ; Root: copy "/" + null
    mov w11, #0x2F
    strb w11, [x10]
    strb wzr, [x10, #1]
    b getcwd_return

getcwd_copy:
    ldrb w11, [x9]
    cbz w11, getcwd_strip
    strb w11, [x10]
    add x9, x9, #1
    add x10, x10, #1
    b getcwd_copy

getcwd_strip:
    ; Strip trailing '/'
    sub x10, x10, #1
    ldrb w11, [x10]
    cmp w11, #0x2F
    b.ne getcwd_no_strip
    strb wzr, [x10]
    b getcwd_return
getcwd_no_strip:
    add x10, x10, #1
    strb wzr, [x10]

getcwd_return:
    ; Return original VA (x21 is PA, convert back to VA)
    movz x9, #0x4000, lsl #16
    sub x9, x21, x9              ; VA = PA - 0x40000000
    str x9, [sp, #0]             ; return buf (VA)
    b trap_exit

;============================================================
; syscall_faccessat: faccessat(dirfd, pathname, mode, flags)
; x0(0)=dirfd(ignored), x1(8)=pathname
; Returns: 0 if file exists, -1 if not
;============================================================
syscall_faccessat:
    ldr x21, [sp, #8]            ; pathname (x1, VA)

    ; Translate VA -> PA
    movz x9, #0x4000, lsl #16
    add x21, x21, x9

    mov x0, x21
    bl absolute_path
    bl find_file

    cmp x0, #0
    b.lt faccessat_fail
    str xzr, [sp, #0]            ; return 0
    b trap_exit
faccessat_fail:
    movn x9, #0
    str x9, [sp, #0]
    b trap_exit

;============================================================
; syscall_mkdirat: mkdirat(dirfd, pathname, mode)
; x0(0)=dirfd(ignored), x1(8)=pathname
; Returns: 0 on success, -1 on failure
;============================================================
syscall_mkdirat:
    ldr x21, [sp, #8]            ; pathname (x1, VA)

    ; Translate VA -> PA
    movz x9, #0x4000, lsl #16
    add x21, x21, x9

    ; Resolve to absolute path
    mov x0, x21
    bl absolute_path
    mov x21, x0

    ; Check parent directory exists (find last '/')
    mov x9, x21
    mov x10, x21                 ; default last slash = start
mkdirat_find_slash:
    ldrb w11, [x9]
    cbz w11, mkdirat_check_parent
    cmp w11, #0x2F
    b.ne mkdirat_next_char
    mov x10, x9
mkdirat_next_char:
    add x9, x9, #1
    b mkdirat_find_slash

mkdirat_check_parent:
    cmp x10, x21
    b.eq mkdirat_do_create       ; root parent always exists

    mov x25, x10                 ; save slash position
    ldrb w24, [x25]
    strb wzr, [x25]
    mov x0, x21
    bl find_file
    strb w24, [x25]              ; restore slash
    cmp x0, #0
    b.lt mkdirat_fail

mkdirat_do_create:
    ; Allocate new file entry
    movz x9, #0x4030, lsl #16
    ldr x23, [x9, #0x10]         ; next_filenum

    ; Copy name to file names table
    movz x10, #0x6090, lsl #16   ; 0x60900000
    lsl x11, x23, #10
    add x10, x10, x11
    mov x11, x21
mkdirat_copy_name:
    ldrb w12, [x11]
    strb w12, [x10]
    cbz w12, mkdirat_name_done
    add x10, x10, #1
    add x11, x11, #1
    b mkdirat_copy_name
mkdirat_name_done:

    ; Set up global file descriptor (length = 0 = directory)
    movz x9, #0x6082, lsl #16
    lsl x10, x23, #4
    add x9, x9, x10
    movz x10, #0x4030, lsl #16
    ldr x11, [x10, #0x18]        ; next_file_address
    add x11, x11, #7
    and x11, x11, #0xFFFFFFFFFFFFFFF8
    str x11, [x10, #0x18]        ; store aligned next_file_address
    str x11, [x9, #0]            ; file_address
    str xzr, [x9, #8]            ; file_length = 0

    ; Increment next_filenum
    ldr x11, [x10, #0x10]
    add x11, x11, #1
    str x11, [x10, #0x10]

    str xzr, [sp, #0]            ; return 0
    b trap_exit

mkdirat_fail:
    movn x9, #0
    str x9, [sp, #0]
    b trap_exit

;============================================================
; syscall_stub_zero: Return 0 for unimplemented stubs
;============================================================
syscall_stub_zero:
    str xzr, [sp, #0]
    b trap_exit

;============================================================
; syscall_clone: clone/fork simulation
; Saves parent state, returns 0 (as child). Parent resumes
; when child calls exit, returning 1.
;============================================================
syscall_clone:
    ; Get current process descriptor
    bl get_process_base
    mov x21, x0                  ; x21 = proc base

    ; Save brk to saved_brk (+0x28)
    movz x9, #0x4030, lsl #16
    ldr x10, [x9, #0x40]         ; current brk (PA)
    str x10, [x21, #0x28]        ; saved_brk

    ; Save kernel sp to saved_stack_pointer_fork (+0x18)
    mov x9, sp
    str x9, [x21, #0x18]

    ; Set forked flag (+0x20)
    ldr x9, [x21, #0x20]
    add x9, x9, #1
    str x9, [x21, #0x20]

    ; Save stack: copy from sp to kernel_stack_top (0x68000000)
    movz x9, #0x7B80, lsl #16    ; x9 = 0x7B800000 (stack top)
    mov x10, sp                  ; x10 = current sp (can't use sp directly in sub reg)
    sub x10, x9, x10             ; x10 = stack length

    ; Get save address from next_save_process_address
    movz x9, #0x4030, lsl #16
    ldr x22, [x9, #0x28]         ; next_save_process_address
    str x22, [x21, #0x48]        ; save stack save address

    movz x9, #0x7B80, lsl #16
    mov x10, sp
    sub x10, x9, x10             ; stack length
    str x10, [x21, #0x50]        ; save stack length

    ; Copy stack to save area
    mov x0, x22                  ; dest = save area
    mov x1, sp                   ; src = current sp
    mov x2, x10                  ; len
    bl memcpy

    ; Advance next_save_process_address
    movz x9, #0x4030, lsl #16
    ldr x10, [x9, #0x28]
    ldr x11, [x21, #0x50]        ; stack length
    add x10, x10, x11
    str x10, [x9, #0x28]

    ; Save process memory: from process_address to brk
    ldr x23, [x21, #0]           ; process_address (PA)
    movz x9, #0x4030, lsl #16
    ldr x24, [x9, #0x40]         ; brk (PA)
    sub x10, x24, x23            ; process memory length

    ; Get save address
    movz x9, #0x4030, lsl #16
    ldr x25, [x9, #0x28]         ; next save addr
    str x25, [x21, #0x38]        ; saved_process_mem_addr

    sub x2, x24, x23             ; length
    str x2, [x21, #0x40]         ; saved_process_mem_len

    ; Copy process memory
    mov x0, x25                  ; dest
    mov x1, x23                  ; src = process_address (PA)
    bl memcpy

    ; Advance next_save_process_address
    movz x9, #0x4030, lsl #16
    ldr x10, [x9, #0x28]
    ldr x11, [x21, #0x40]        ; process mem length
    add x10, x10, x11
    str x10, [x9, #0x28]

    ; Save user stack: from MIN(SP_EL0, x18) PA to 0x50000000
    ; M2-Planet uses x18 as data stack pointer which diverges from SP_EL0.
    ; We must save the entire range that either stack uses.
    ; Only use x18 if it looks like a valid stack pointer (between brk VA and SP_EL0).
    ldr x23, [sp, #248]          ; SP_EL0 (VA)
    ldr x9, [sp, #144]           ; x18 (VA) - M2-Planet data stack
    cmp x9, x23
    b.hs clone_sp_ok             ; x18 >= SP_EL0, not a lower stack
    movz x10, #0x0060, lsl #16   ; minimum valid VA (0x00600000, user base)
    cmp x9, x10
    b.lo clone_sp_ok             ; x18 < 0x00600000, not a valid stack pointer
    mov x23, x9                  ; use x18 (it's a valid lower stack pointer)
clone_sp_ok:
    movz x9, #0x4000, lsl #16
    add x23, x23, x9             ; user sp (PA) = VA + 0x40000000

    movz x9, #0x5000, lsl #16    ; x9 = 0x50000000 (user stack top PA)
    sub x24, x9, x23             ; user stack length

    ; Get save address
    movz x9, #0x4030, lsl #16
    ldr x25, [x9, #0x28]         ; next save addr
    str x25, [x21, #0x58]        ; saved_user_stack_addr
    str x24, [x21, #0x60]        ; saved_user_stack_len

    ; Copy user stack to save area
    mov x0, x25                  ; dest
    mov x1, x23                  ; src = user sp (PA)
    mov x2, x24                  ; len
    bl memcpy

    ; Advance next_save_process_address
    movz x9, #0x4030, lsl #16
    ldr x10, [x9, #0x28]
    add x10, x10, x24
    str x10, [x9, #0x28]

    ; Copy CWD from parent proc to child proc
    ; Parent = proc[next_process_num-1], Child will be proc[next_process_num]
    movz x9, #0x4030, lsl #16
    ldr x10, [x9, #0x20]         ; next_process_num
    movz x9, #0x6040, lsl #16
    movz x11, #0x1000
    mul x12, x10, x11            ; child offset = next_process_num * 4096
    sub x13, x10, #1
    mul x13, x13, x11            ; parent offset = (next_process_num-1) * 4096
    add x12, x9, x12             ; child proc base
    add x13, x9, x13             ; parent proc base
    ; Copy 256 bytes of CWD (offset +0x100)
    add x12, x12, #0x100         ; child CWD
    add x13, x13, #0x100         ; parent CWD
    mov x14, #256
clone_copy_cwd:
    ldrb w15, [x13]
    strb w15, [x12]
    add x13, x13, #1
    add x12, x12, #1
    sub x14, x14, #1
    cbnz x14, clone_copy_cwd

    ; Return 0 (child return from fork)
    str xzr, [sp, #0]
    b trap_exit

;============================================================
; syscall_execve: execve(pathname, argv, envp)
; x0(0)=pathname, x1(8)=argv, x2(16)=envp
;============================================================
syscall_execve:
    ldr x21, [sp, #0]            ; pathname (VA)
    ldr x22, [sp, #8]            ; argv (VA)
    ldr x23, [sp, #16]           ; envp (VA)

    ; Translate all pointers VA -> PA (add 0x40000000 for Entry 1 kernel VA)
    movz x9, #0x4000, lsl #16
    add x21, x21, x9
    add x22, x22, x9
    add x23, x23, x9

    ; Copy pathname to safe buffer at 0x60000400 (won't be zeroed by memset)
    ; User memory at PA 0x00600000+ gets zeroed during execve, destroying pathname
    mov x9, x21                  ; src = pathname (kernel VA)
    movz x10, #0x6000, lsl #16
    movk x10, #0x0400            ; dest = 0x60000400 (scratch+0x400)
    mov x11, #1024               ; max copy length safety limit
execve_copy_path:
    ldrb w12, [x9]
    strb w12, [x10]
    add x9, x9, #1
    add x10, x10, #1
    cbz w12, execve_copy_done
    sub x11, x11, #1
    cbnz x11, execve_copy_path
    strb wzr, [x10]              ; NUL-terminate if max length reached
execve_copy_done:
    ; x21 now points to safe copy
    movz x21, #0x6000, lsl #16
    movk x21, #0x0400

    ; Check if current process forked
    bl get_process_base
    mov x24, x0                  ; current proc
    ldr x9, [x24, #0x20]         ; forked flag
    cbnz x9, execve_forked

    ; Not forked: check if first process
    movz x9, #0x4030, lsl #16
    ldr x10, [x9, #0x20]         ; next_process_num
    cmp x10, #1
    b.ne execve_overlay

    ; First process: save original sp at proc[1]+0x10
    movz x9, #0x6040, lsl #16    ; 0x40400000
    movz x10, #0x1000
    add x9, x9, x10              ; proc[1] = 0x60401000
    mov x10, sp
    str x10, [x9, #0x10]         ; save kernel sp for return-to-shell
    b execve_prepare_stack

execve_forked:
    ; Forked: create new process after fork
    sub x9, x9, #1
    str x9, [x24, #0x20]
    b execve_prepare_stack

execve_overlay:
    ; Not forked, not first: overlay current process
    b execve_prepare_stack

execve_prepare_stack:
    ; Set up user stack at PA 0x50000000 (VA 0x10000000)

    ; First, count argc
    mov x9, x22                  ; argv
    mov x25, #0                  ; argc
    ; VA range limit: 0x40000000 (1GB)
    movz x11, #0x4000, lsl #16
execve_count_args:
    ldr x10, [x9]
    cbz x10, execve_counted
    cmp x10, x11
    b.hs execve_counted          ; pointer out of valid VA range
    add x25, x25, #1
    add x9, x9, #8
    b execve_count_args
execve_counted:
    ; String storage on user stack, growing DOWN from PA 0x50000000.
    movz x27, #0x5000, lsl #16   ; x27 = 0x50000000 (string storage PA)

    ; ---- Phase 1: Copy argv strings ----
    ; Temp argv VA array at PA 0x60001000
    movz x28, #0x6000, lsl #16
    movz x9, #0x1000
    add x28, x28, x9             ; x28 = 0x60001000 (temp VA array)

    mov x19, x22                 ; x19 = argv array iterator (PA)
    mov x24, x25                 ; x24 = argc (from count loop)
    mov x25, #0                  ; copy counter
execve_copy_argv:
    cmp x25, x24
    b.ge execve_argv_done
    ldr x10, [x19]               ; argv[i] pointer (VA)
    cbz x10, execve_argv_done

    ; Translate argv[i] VA -> PA
    movz x11, #0x4000, lsl #16
    add x1, x10, x11             ; src (PA)

    ; Allocate string slot on user stack (grow down)
    sub x27, x27, #256
    ; Copy string from x1 to x27 (256 bytes max)
    mov x0, x27                  ; dest (PA)
    mov x2, #256
    bl memcpy

    ; Calculate VA for this string: VA = PA - 0x40000000
    movz x10, #0x4000, lsl #16
    sub x10, x27, x10            ; VA

    ; Store VA in temp array
    lsl x11, x25, #3
    add x11, x28, x11
    str x10, [x11]

    add x25, x25, #1
    add x19, x19, #8
    b execve_copy_argv

execve_argv_done:
    mov x24, x25                 ; x24 = argc (final)

    ; ---- Phase 2: Copy envp strings ----
    ; Temp envp VA array at PA 0x60002000
    movz x28, #0x6000, lsl #16
    movz x9, #0x2000
    add x28, x28, x9             ; x28 = 0x60002000

    mov x19, x23                 ; x19 = envp array iterator (PA)
    mov x25, #0                  ; envc counter
execve_copy_envp:
    ldr x10, [x19]               ; envp[i] pointer (VA)
    cbz x10, execve_envp_done
    movz x11, #0x4000, lsl #16
    cmp x10, x11
    b.hs execve_envp_done        ; out of valid VA range

    ; Translate VA -> PA
    movz x11, #0x4000, lsl #16
    add x1, x10, x11             ; src (PA)

    ; Allocate string slot on user stack (grow down)
    sub x27, x27, #256
    mov x0, x27                  ; dest (PA)
    mov x2, #256
    bl memcpy

    movz x10, #0x4000, lsl #16
    sub x10, x27, x10            ; VA

    lsl x11, x25, #3
    add x11, x28, x11
    str x10, [x11]

    add x25, x25, #1
    add x19, x19, #8
    b execve_copy_envp

execve_envp_done:
    ; x24 = argc, x25 = envc
    ; Save envc to stack for later
    sub sp, sp, #16
    str x25, [sp]                ; save envc

    ; ---- Phase 3: Build stack ----
    mov x26, x27

    ; Push NULL (envp terminator)
    sub x26, x26, #8
    str xzr, [x26]

    ; Push envp pointers in reverse order
    ldr x9, [sp]                 ; x9 = envc
    movz x12, #0x6000, lsl #16
    movz x13, #0x2000
    add x12, x12, x13            ; x12 = 0x60002000 (envp VA array)
execve_push_envp:
    cbz x9, execve_push_envp_done
    sub x9, x9, #1
    lsl x10, x9, #3
    add x10, x12, x10
    ldr x10, [x10]               ; VA
    sub x26, x26, #8
    str x10, [x26]
    b execve_push_envp
execve_push_envp_done:
    add sp, sp, #16              ; pop saved envc

    ; Push NULL (argv terminator)
    sub x26, x26, #8
    str xzr, [x26]

    ; Push argv pointers in reverse order
    mov x9, x24                  ; x9 = argc
    movz x12, #0x6000, lsl #16
    movz x13, #0x1000
    add x12, x12, x13            ; x12 = 0x60001000 (argv VA array)
execve_push_argv:
    cbz x9, execve_push_argc
    sub x9, x9, #1
    lsl x10, x9, #3
    add x10, x12, x10
    ldr x10, [x10]               ; VA
    sub x26, x26, #8
    str x10, [x26]
    b execve_push_argv

execve_push_argc:
    ; Push argc
    sub x26, x26, #8
    str x24, [x26]               ; x24 = argc

    ; Now x26 = user stack PA. Calculate VA = x26 - 0x40000000
    movz x9, #0x4000, lsl #16
    sub x26, x26, x9             ; x26 = user stack VA

    ; --- Load ELF ---
    ; Resolve program name
    mov x0, x21
    bl absolute_path
    mov x21, x0
    mov x0, x21
    bl find_file
    cmp x0, #0
    b.lt execve_fail
    mov x27, x0                  ; x27 = file index

    ; Get file address and length
    movz x9, #0x6082, lsl #16    ; 0x60820000
    lsl x10, x27, #4
    add x9, x9, x10
    ldr x28, [x9, #0]            ; file_address (PA)
    ldr x19, [x9, #8]            ; file_length

    ; Increment next_process_num
    movz x9, #0x4030, lsl #16
    ldr x10, [x9, #0x20]
    add x10, x10, #1
    str x10, [x9, #0x20]

    ; Get new process descriptor
    bl get_process_base
    mov x24, x0                  ; x24 = new proc descriptor

    ; Copy cwd from previous process
    movz x9, #0x1000
    sub x9, x24, x9              ; prev proc
    add x10, x9, #0x100          ; prev cwd
    add x11, x24, #0x100         ; new cwd
    mov x12, #256
execve_copy_cwd:
    cbz x12, execve_cwd_done
    ldrb w13, [x10]
    strb w13, [x11]
    add x10, x10, #1
    add x11, x11, #1
    sub x12, x12, #1
    b execve_copy_cwd
execve_cwd_done:

    ; Clear new process open file descriptors
    add x0, x24, #0x200
    movz x1, #0xE00
    bl memset_zero

    ; Parse 64-bit ELF header
    ldr x21, [x28, #0x18]        ; entry point (VA)

    ldr x9, [x28, #0x20]         ; e_phoff
    add x22, x28, x9             ; x22 = phdr address (PA)

    ldrh w23, [x28, #0x38]       ; e_phnum

    ; Zero user process area: 8MB starting at PA 0x40600000
    ; Must clear beyond 2MB to zero stale heap data from previous processes
    movz x0, #0x4060, lsl #16
    movz x1, #0x80, lsl #16      ; 0x800000 = 8MB
    bl memset_zero

    ; Reset brk to process base
    movz x9, #0x4060, lsl #16
    movz x10, #0x4030, lsl #16
    str x9, [x10, #0x40]         ; brk = 0x40600000

    ; Load each program header (56 bytes each for ELF64)
execve_load_phdr:
    cbz x23, execve_load_done

    ; Check p_type == PT_LOAD (1)
    ldr w9, [x22]
    cmp w9, #1
    b.ne execve_next_phdr

    ldr x9, [x22, #0x08]         ; p_offset
    add x1, x28, x9              ; src = file_address + p_offset

    ldr x9, [x22, #0x10]         ; p_vaddr (VA)
    movz x10, #0x4000, lsl #16
    add x0, x9, x10              ; dest = PA = VA + 0x40000000

    ldr x2, [x22, #0x20]         ; p_filesz
    bl memcpy

    ; Track end of loaded segments for brk
    ldr x9, [x22, #0x10]         ; p_vaddr
    ldr x10, [x22, #0x20]        ; p_filesz
    add x9, x9, x10              ; end of segment (VA)
    movz x10, #0x4000, lsl #16
    add x9, x9, x10              ; end (PA)
    movz x10, #0x2000
    add x9, x9, x10              ; +0x2000 padding

    ; Set brk = max across segments
    movz x10, #0x4030, lsl #16
    ldr x11, [x10, #0x40]
    cmp x11, x9
    b.ge execve_next_phdr
    str x9, [x10, #0x40]

execve_next_phdr:
    add x22, x22, #56
    sub x23, x23, #1
    b execve_load_phdr

execve_load_done:
    ; Set process_address in descriptor
    movz x9, #0x4060, lsl #16    ; PA 0x40600000
    str x9, [x24, #0]

    ; Clear forked flag
    str xzr, [x24, #0x20]

    ; Deallocate trap frame
    add sp, sp, #272

    ; Ensure new code is visible (I-cache coherence)
    ic iallu
    dsb sy
    isb

    ; Set ELR_EL1 = entry point VA
    msr elr_el1, x21

    ; Set SPSR_EL1 = 0 (EL0, AArch64, interrupts unmasked)
    movz x9, #0
    msr spsr_el1, x9

    ; Set user SP and eret
    msr sp_el0, x26
    eret

execve_fail:
    movn x9, #0
    str x9, [sp, #0]
    b trap_exit

;============================================================
; syscall_exit: exit(code)
; x0(0)=exit code
;============================================================
syscall_exit:
    ldr x21, [sp, #0]            ; exit code

    ; Decrement next_process_num
    movz x9, #0x4030, lsl #16
    ldr x10, [x9, #0x20]
    sub x10, x10, #1
    str x10, [x9, #0x20]         ; next_process_num--

    ; If returning to shell (next_process_num == 1)
    cmp x10, #1
    b.eq exit_to_shell

    ; Returning to parent after fork
    sub x11, x10, #1             ; parent index
    lsl x11, x11, #12            ; * 4096
    movz x12, #0x6040, lsl #16   ; 0x40400000
    add x22, x12, x11            ; x22 = parent proc descriptor

    ; Save child exit code
    str x21, [x22, #0x30]

    ; Restore parent process memory
    ldr x0, [x22, #0]            ; dest = process_address (PA)
    ldr x1, [x22, #0x38]         ; src = saved_process_mem_addr
    ldr x2, [x22, #0x40]         ; len = saved_process_mem_len
    bl memcpy

    ; Deallocate save area
    movz x9, #0x4030, lsl #16
    ldr x10, [x22, #0x48]        ; saved stack addr
    str x10, [x9, #0x28]         ; next_save_process_address

    ; Restore parent brk
    ldr x10, [x22, #0x28]        ; saved_brk
    str x10, [x9, #0x40]         ; current_brk

    ; Restore parent stack pointer
    ldr x9, [x22, #0x18]         ; saved_stack_pointer_fork
    mov sp, x9

    ; Restore parent stack contents
    ldr x1, [x22, #0x48]         ; src = saved stack addr
    mov x0, sp                   ; dest = sp
    ldr x2, [x22, #0x50]         ; len = saved stack len
    bl memcpy

    ; Restore parent user stack
    ; Compute dest from saved length: dest = 0x50000000 - saved_user_stack_len
    movz x0, #0x5000, lsl #16    ; user stack top PA
    ldr x2, [x22, #0x60]         ; len = saved_user_stack_len
    sub x0, x0, x2               ; dest = stack top - len (= original save start)
    ldr x1, [x22, #0x58]         ; src = saved_user_stack_addr
    bl memcpy

    ; Flush I-cache after restoring parent code/data
    ic iallu
    dsb sy
    isb

    ; Return 1 (parent return from fork)
    mov x9, #1
    str x9, [sp, #0]             ; x0 = 1 in trap frame
    b trap_exit

exit_to_shell:
    ; Restore kernel sp from proc[1]+0x10
    movz x9, #0x6040, lsl #16
    movz x10, #0x1000
    add x9, x9, x10              ; proc[1] = 0x60401000
    ldr x9, [x9, #0x10]
    mov sp, x9

    ; Jump to shell_return
    b shell_return

;============================================================
; syscall_waitid: waitid(idtype, id, infop, options, ...)
;============================================================
syscall_waitid:
    bl get_process_base
    ldr x9, [x0, #0x30]          ; child_exit_code

    ; a2 = infop (VA)
    ldr x10, [sp, #16]           ; x2 = infop
    cbz x10, waitid_no_write

    ; Translate infop VA -> PA
    movz x11, #0x4000, lsl #16
    add x10, x10, x11

    ; Write exit code shifted left by 8
    lsl x9, x9, #8
    str w9, [x10]

waitid_no_write:
    str xzr, [sp, #0]            ; return 0
    b trap_exit

;============================================================
; syscall_wait4: wait4(pid, wstatus, options, rusage)
; x0(0)=pid, x1(8)=wstatus_ptr
;============================================================
syscall_wait4:
    bl get_process_base
    ldr x9, [x0, #0x30]          ; child_exit_code

    ; Get wstatus pointer (x1)
    ldr x10, [sp, #8]            ; x1 = wstatus (VA)
    cbz x10, wait4_no_write

    ; Translate VA -> PA
    movz x11, #0x4000, lsl #16
    add x10, x10, x11

    ; Write wstatus = (exit_code << 8)
    lsl x9, x9, #8
    str w9, [x10]

wait4_no_write:
    ; Return child pid (1)
    mov x9, #1
    str x9, [sp, #0]
    b trap_exit

;============================================================
; uart_putchar: Print character in x0 via PL011 UART
; x0 = character to print
;============================================================
uart_putchar:
    sub sp, sp, #16
    str x30, [sp]
    movz x9, #0x4030, lsl #16
    ldr x9, [x9, #0xA0]
uart_wait:
    bl uart_read_fr               ; bl/ret breaks TCG translation block
    and w10, w10, #0x20           ; bit 5 = TXFF (TX FIFO full)
    cbnz w10, uart_wait
    strb w0, [x9]                 ; write to DR
    ldr x30, [sp]
    add sp, sp, #16
    ret

; uart_read_fr: Read PL011 FR register (breaks TCG TB caching)
uart_read_fr:
    ldr w10, [x9, #0x18]
    ret

;============================================================
; print_hex_nibble: Print nibble (0-15) in x0
;============================================================
print_hex_nibble:
    cmp x0, #10
    b.ge print_hex_alpha
    add x0, x0, #0x30
    b uart_putchar
print_hex_alpha:
    add x0, x0, #0x57
    b uart_putchar

;============================================================
; print_hex_byte: Print byte in x0 as 2 hex digits
;============================================================
print_hex_byte:
    sub sp, sp, #16
    str x30, [sp]
    str x19, [sp, #8]
    mov x19, x0
    lsr x0, x19, #4
    and x0, x0, #0xF
    bl print_hex_nibble
    mov x0, x19
    and x0, x0, #0xF
    bl print_hex_nibble
    ldr x30, [sp]
    ldr x19, [sp, #8]
    add sp, sp, #16
    ret

;============================================================
; print_hex32: Print 32-bit value in x0 as 8 hex digits
;============================================================
print_hex32:
    sub sp, sp, #16
    str x30, [sp]
    str x19, [sp, #8]
    mov x19, x0

    lsr x0, x19, #28
    and x0, x0, #0xF
    bl print_hex_nibble
    lsr x0, x19, #24
    and x0, x0, #0xF
    bl print_hex_nibble
    lsr x0, x19, #20
    and x0, x0, #0xF
    bl print_hex_nibble
    lsr x0, x19, #16
    and x0, x0, #0xF
    bl print_hex_nibble
    lsr x0, x19, #12
    and x0, x0, #0xF
    bl print_hex_nibble
    lsr x0, x19, #8
    and x0, x0, #0xF
    bl print_hex_nibble
    lsr x0, x19, #4
    and x0, x0, #0xF
    bl print_hex_nibble
    mov x0, x19
    and x0, x0, #0xF
    bl print_hex_nibble

    ldr x30, [sp]
    ldr x19, [sp, #8]
    add sp, sp, #16
    ret

;============================================================
; print_string: Print null-terminated string at x0
;============================================================
print_string:
    sub sp, sp, #16
    str x30, [sp]
    str x19, [sp, #8]
    mov x19, x0
print_string_loop:
    ldrb w0, [x19]
    cbz w0, print_string_done
    bl uart_putchar
    add x19, x19, #1
    b print_string_loop
print_string_done:
    ldr x30, [sp]
    ldr x19, [sp, #8]
    add sp, sp, #16
    ret

;============================================================
; load_ram_base: Load 0x40210000 into x20
;============================================================
load_ram_base:
    movz x20, #0x4021, lsl #16
    ret

;============================================================
; load_data_base: Load 0x40300000 into x9
;============================================================
load_data_base:
    movz x9, #0x4030, lsl #16
    ret

;============================================================
; reboot: PSCI SYSTEM_RESET via HVC
;============================================================
reboot:
    movz x9, #0x4030, lsl #16
    ldr x10, [x9, #0xA8]         ; board_has_sdhci?
    cbnz x10, reboot_raspi

    ; Virt: PSCI SYSTEM_RESET via HVC
    movz x0, #0x0009
    movk x0, #0x8400, lsl #16    ; 0x84000009 = PSCI SYSTEM_RESET
    hvc #0
    b reboot_hang

reboot_raspi:
    ; Raspi3b: BCM2835 PM watchdog reset
    movz x9, #0x7F10, lsl #16    ; PM base VA = 0x7F100000 (PA 0x3F100000)
    ; Set PM_RSTS to 0 (reset, not poweroff)
    movz x10, #0x5A00, lsl #16   ; PM_PASSWORD
    str w10, [x9, #0x20]         ; PM_RSTS = password | 0
    ; Set PM_WDOG timeout
    movz x10, #0x5A00, lsl #16
    movk x10, #0x000A             ; PM_PASSWORD | 10 ticks
    str w10, [x9, #0x24]         ; PM_WDOG
    ; Trigger full reset
    movz x10, #0x5A00, lsl #16
    movk x10, #0x0020             ; PM_PASSWORD | PM_RSTC_WRCFG_FULL_RESET
    str w10, [x9, #0x1C]         ; PM_RSTC
reboot_hang:
    wfe
    b reboot_hang

;============================================================
; memset_zero: Zero memory from x0 to x0+x1
; x0 = start address, x1 = byte count (must be multiple of 8)
;============================================================
memset_zero:
    cbz x1, memset_done
    str xzr, [x0]
    add x0, x0, #8
    sub x1, x1, #8
    b memset_zero
memset_done:
    ret

;============================================================
; memcpy: Copy memory
; x0 = dest, x1 = src, x2 = byte count
; Returns: x0 = dest (preserved)
;============================================================
memcpy:
    mov x9, x0                   ; save dest for return
memcpy_loop:
    cbz x2, memcpy_done
    ldrb w10, [x1]
    strb w10, [x0]
    add x0, x0, #1
    add x1, x1, #1
    sub x2, x2, #1
    b memcpy_loop
memcpy_done:
    mov x0, x9
    ret

;============================================================
; bswap32: Byte-swap a 32-bit value
; x0 = input, Returns: x0 = byte-swapped
;============================================================
bswap32:
    rev w0, w0
    ret

;============================================================
; read_stdin_byte: Read one byte from stdin (disk)
; Returns: x0 = byte read
;============================================================
read_stdin_byte:
    sub sp, sp, #16
    str x30, [sp]
    str x19, [sp, #8]

    ; Load global data base
    movz x9, #0x4030, lsl #16
    ldr x10, [x9, #0x38]         ; stdin_offset

    ; Check if pre-loaded buffer exists (raspi3b uses CMD18 preload)
    ldr x11, [x9, #0x78]         ; stdin_buf_ptr (0 if no preload)
    cbz x11, rsb_per_sector

    ; --- Pre-loaded path (raspi3b) ---
    ; If offset >= 512, advance to next sector in pre-loaded buffer
    cmp x10, #512
    b.lt rsb_have_data
    add x11, x11, #512
    ; Check if past preload end (0x42000000 + 16128*512 = 0x427E0000)
    movz x12, #0x427E, lsl #16
    cmp x11, x12
    b.hs rsb_preload_exhausted
    str x11, [x9, #0x78]
    str xzr, [x9, #0x38]
    mov x10, #0
    b rsb_have_data

rsb_preload_exhausted:
    ; Switch from preload buffer to per-sector SDHCI reads
    str xzr, [x9, #0x78]         ; stdin_buf_ptr = 0
    mov x10, #512
    str x10, [x9, #0x38]         ; stdin_offset = 512 (trigger sector read)
    b rsb_per_sector

rsb_per_sector:
    ; --- Per-sector path (virt or post-preload fallback) ---
    cmp x10, #512
    b.lt rsb_have_data_sector
    ; Read next sector via disk_read_sector
    ldr x0, [x9, #0x30]          ; sector number
    movz x1, #0x6001, lsl #16    ; buffer = 0x60010000
    bl disk_read_sector
    movz x9, #0x4030, lsl #16
    ldr x10, [x9, #0x30]
    add x10, x10, #1
    str x10, [x9, #0x30]         ; stdin_sector++
    str xzr, [x9, #0x38]         ; stdin_offset = 0
    mov x10, #0
rsb_have_data_sector:
    movz x19, #0x6001, lsl #16
    add x19, x19, x10
    ldrb w0, [x19]
    b rsb_update_offset

rsb_have_data:
    ; Read from pre-loaded stdin buffer
    movz x9, #0x4030, lsl #16
    ldr x19, [x9, #0x78]         ; current sector buffer pointer
    add x19, x19, x10
    ldrb w0, [x19]

rsb_update_offset:
    ; Update stdin_offset
    movz x9, #0x4030, lsl #16
    ldr x10, [x9, #0x38]
    add x10, x10, #1
    str x10, [x9, #0x38]

    ldr x30, [sp]
    ldr x19, [sp, #8]
    add sp, sp, #16
    ret

;============================================================
; setup_page_table: Create AArch64 page table at PA 0x40100000
; Entry 0: VA 0x00000000-0x3FFFFFFF -> PA 0x40000000 (User, Normal)
; Entry 1: VA 0x40000000-0x7FFFFFFF -> PA 0x40000000 (Kernel, Normal)
; Entry 2: VA 0x80000000-0xBFFFFFFF -> PA 0x80000000 (Kernel, Normal, upper RAM)
; Entry 3: VA 0xC0000000-0xFFFFFFFF -> PA 0x00000000 (Device nGnRE, MMIO)
; Also sets MAIR_EL1, TCR_EL1, TTBR0_EL1
;============================================================
setup_page_table:
    sub sp, sp, #16
    str x30, [sp]

    ; Zero page table (4KB at 0x40100000)
    movz x0, #0x4010, lsl #16
    movz x1, #0x1000
    bl memset_zero

    ; MAIR_EL1: attr0=0xFF (Normal WB), attr1=0x04 (Device nGnRE)
    movz x0, #0x04FF
    msr mair_el1, x0

    ; TCR_EL1: T0SZ=25 (39-bit VA), IRGN0=1, ORGN0=1, SH0=3, TG0=0 (4KB)
    ; = 25 | (1<<8) | (1<<10) | (3<<12) = 0x3519
    movz x0, #0x3519
    msr tcr_el1, x0

    ; TTBR0_EL1 = page table physical address
    movz x0, #0x4010, lsl #16
    msr ttbr0_el1, x0

    ; Page table base
    movz x0, #0x4010, lsl #16

    ; Entry 0: VA 0x00000000 -> PA 0x40000000
    ; Block descriptor for level 1 (1GB blocks)
    ; Attrs: AF(1<<10) | SH(3<<8) | AP_EL0(1<<6) | AttrIdx(0)<<2 | 0b01 (block)
    ; = 0x40000000 | (1<<10) | (3<<8) | (1<<6) | (0<<2) | 1
    ; = 0x40000000 | 0x400 | 0x300 | 0x40 | 0x01 = 0x40000741
    movz x9, #0x4000, lsl #16
    movk x9, #0x0741
    str x9, [x0, #0]              ; entry 0

    ; Entry 1: VA 0x40000000 -> PA 0x40000000
    ; Kernel mapping: no AP_EL0 bit
    ; = 0x40000000 | (1<<10) | (3<<8) | (0<<2) | 1
    ; = 0x40000000 | 0x400 | 0x300 | 0x01 = 0x40000701
    movz x9, #0x4000, lsl #16
    movk x9, #0x0701
    str x9, [x0, #8]              ; entry 1

    ; Entry 2: VA 0x80000000 -> PA 0x80000000 (kernel RAM, upper 1GB, Normal)
    ; Identity-map for file data at 0x94000000, saved process mem at 0xB0000000, etc.
    ; = 0x80000000 | 0x400 | 0x300 | 0x01 = 0x80000701
    movz x9, #0x8000, lsl #16
    movk x9, #0x0701
    str x9, [x0, #16]             ; entry 2

    ; Entry 3: VA 0xC0000000 -> PA 0x00000000 (device memory for MMIO <0x40000000)
    ; AttrIdx=1 (device), AF, no user access
    ; = 0x00000000 | 0x400 | 0x300 | 0x04 | 0x01 = 0x00000705
    movz x9, #0x0705
    str x9, [x0, #24]             ; entry 3

    ldr x30, [sp]
    add sp, sp, #16
    ret

;============================================================
; _trampoline: Board-detection entry point
;============================================================
_trampoline:
    adr x9, _trampoline
    movz x10, #0x4000, lsl #16
    cmp x9, x10
    b.hs tramp_virt

    ; --- Raspi3b: build L1+L2 page tables at PA 0x00200000, enable MMU ---
    ; L1 at PA 0x200000 (32 bytes)
    ; L2_0 at PA 0x201000 (4096 bytes) for Entry 0 (user+kernel)
    ; L2_1 at PA 0x202000 (4096 bytes) for Entry 1 (kernel-only)
    ; Use x12 (not x0 — x0 holds stdin_sector from stage1)
    ; Zero 12KB (L1 + L2_0 + L2_1)
    movz x12, #0x0020, lsl #16
    movz x9, #0
    movz x10, #0x3000
tramp_zero:
    str xzr, [x12, x9]
    add x9, x9, #8
    cmp x9, x10
    b.lt tramp_zero

    ; --- L1 table at PA 0x200000 ---
    movz x12, #0x0020, lsl #16
    ; Entry 0: TABLE → L2_0 at PA 0x201000
    movz x9, #0x0020, lsl #16
    movk x9, #0x1003
    str x9, [x12, #0]
    ; Entry 1: TABLE → L2_1 at PA 0x202000
    movz x9, #0x0020, lsl #16
    movk x9, #0x2003
    str x9, [x12, #8]
    ; Entry 2: 1GB Block, Normal WB, kernel-only (for file data at VA 0x80000000+)
    movz x9, #0x0701
    str x9, [x12, #16]

    ; --- Fill L2_0 at PA 0x201000 (user+kernel) ---
    ; Entries 0-503: Normal WB, kernel-only initially (0x0701)
    ; Entries 504-511: Device nGnRE (0x0705)
    movz x12, #0x0020, lsl #16
    movk x12, #0x1000
    movz x9, #0
    movz x10, #0x0020, lsl #16
tramp_l2_fill:
    mul x11, x9, x10
    cmp x9, #504
    b.ge tramp_l2_device
    movz x13, #0x0701
    orr x11, x11, x13
    b tramp_l2_store
tramp_l2_device:
    movz x13, #0x0705
    orr x11, x11, x13
tramp_l2_store:
    lsl x13, x9, #3
    str x11, [x12, x13]
    add x9, x9, #1
    cmp x9, #512
    b.lt tramp_l2_fill

    ; --- Copy L2_0 to L2_1 at PA 0x202000 (same content, kernel-only) ---
    movz x9, #0x0020, lsl #16
    movk x9, #0x1000             ; src = L2_0
    movz x10, #0x0020, lsl #16
    movk x10, #0x2000            ; dst = L2_1
    movz x11, #0
tramp_l2_copy:
    ldr x12, [x9, x11]
    str x12, [x10, x11]
    add x11, x11, #8
    cmp x11, #4096
    b.lt tramp_l2_copy

    movz x9, #0x04FF
    msr mair_el1, x9
    movz x9, #0x3519
    msr tcr_el1, x9
    movz x9, #0x0020, lsl #16
    msr ttbr0_el1, x9
    isb

    mrs x9, sctlr_el1
    orr x9, x9, #1
    orr x9, x9, #4
    orr x9, x9, #0x1000
    msr sctlr_el1, x9
    isb

    ; Fix L2 entries 0-503: add AP_EL0 via kernel VA 0x40201000 (Entry 1 → PA 0x201000)
    ; Change 0x0701 → 0x0741 (add bit 6 = AP_EL0)
    ; MUST NOT use TLBI (hangs on raspi3b QEMU). DSB+ISB sufficient.
    movz x9, #0x4020, lsl #16
    movk x9, #0x1000             ; x9 = VA 0x40201000 (L2 table via Entry 1)
    movz x10, #0
tramp_fix_l2:
    lsl x11, x10, #3             ; offset = index * 8
    add x11, x9, x11
    ldr x12, [x11]               ; current descriptor
    orr x12, x12, #0x40          ; set bit 6 (AP_EL0)
    str x12, [x11]
    add x10, x10, #1
    cmp x10, #504                ; only fix Normal WB entries, not Device
    b.lt tramp_fix_l2
    dsb sy
    isb

    ; Jump to main at VA (PA + 0x40000000 via Entry 1)
    mov x27, #3                   ; board type = SDHCI (raspi3b)
    adr x9, main
    movz x10, #0x4000, lsl #16
    add x9, x9, x10
    br x9

tramp_virt:
    mov x27, #0                   ; board type = not SDHCI (virt)
    b main

;============================================================
; strcmp: Compare two null-terminated strings
; x0 = str1, x1 = str2
; Returns: x0 = 0 if equal, nonzero if different
;============================================================
strcmp:
    ldrb w9, [x0]
    ldrb w10, [x1]
    cmp w9, w10
    b.ne strcmp_diff
    cbz w9, strcmp_equal
    add x0, x0, #1
    add x1, x1, #1
    b strcmp
strcmp_equal:
    mov x0, #0
    ret
strcmp_diff:
    sub x0, x9, x10
    ret

;============================================================
; get_process_base: Get base of current process descriptor
; Returns: x0 = 0x60400000 + (next_process_num - 1) * 0x1000
;============================================================
get_process_base:
    movz x9, #0x4030, lsl #16
    ldr x10, [x9, #0x20]         ; next_process_num
    sub x10, x10, #1
    lsl x10, x10, #12            ; * 4096
    movz x9, #0x6040, lsl #16
    add x0, x9, x10
    ret

;============================================================
; absolute_path: Resolve path to absolute
; x0 = input path (null-terminated)
; Returns: x0 = pointer to resolved path in scratch buffer (0x60000000)
;============================================================
absolute_path:
    sub sp, sp, #32
    str x30, [sp]
    str x19, [sp, #8]
    str x20, [sp, #16]
    str x21, [sp, #24]

    mov x19, x0                  ; input path
    ; Output buffer = scratch at 0x60000000
    movz x20, #0x6000, lsl #16   ; x20 = output pointer
    mov x21, x20                 ; x21 = output start (for return)

    ; Strip leading "./" if present
    ldrb w9, [x19]
    cmp w9, #0x2E                ; '.'
    b.ne abs_no_dot
    ldrb w9, [x19, #1]
    cmp w9, #0x2F                ; '/'
    b.ne abs_no_dot
    add x19, x19, #2             ; skip "./"
abs_no_dot:

    ; Check if absolute (starts with '/')
    ldrb w9, [x19]
    cmp w9, #0x2F
    b.eq abs_copy_input

    ; Relative: prepend cwd
    bl get_process_base
    add x0, x0, #0x100           ; current_dir at +0x100
abs_copy_cwd:
    ldrb w9, [x0]
    cbz w9, abs_copy_input
    strb w9, [x20]
    add x0, x0, #1
    add x20, x20, #1
    b abs_copy_cwd

abs_copy_input:
    ldrb w9, [x19]
    strb w9, [x20]
    cbz w9, abs_done
    add x19, x19, #1
    add x20, x20, #1
    b abs_copy_input

abs_done:
    ; Normalize: resolve /../ sequences in-place
    mov x19, x21                 ; x19 = scan pointer
abs_norm_scan:
    ldrb w9, [x19]
    cbz w9, abs_norm_done
    cmp w9, #0x2F                ; '/'
    b.ne abs_norm_next
    ldrb w9, [x19, #1]
    cmp w9, #0x2E                ; '.'
    b.ne abs_norm_next
    ldrb w9, [x19, #2]
    cmp w9, #0x2E                ; '.'
    b.ne abs_norm_next
    ldrb w9, [x19, #3]
    cmp w9, #0x2F
    b.eq abs_norm_found
    cbz w9, abs_norm_found_end
    b abs_norm_next
abs_norm_found:
    ; Found "/../" at x19. Remove preceding dir component.
    mov x11, x19                 ; x11 = start of "/../"
    cmp x19, x21
    b.eq abs_norm_skip           ; at root
    sub x19, x19, #1
abs_norm_back:
    cmp x19, x21
    b.eq abs_norm_do_remove
    ldrb w9, [x19]
    cmp w9, #0x2F
    b.eq abs_norm_do_remove
    sub x19, x19, #1
    b abs_norm_back
abs_norm_do_remove:
    add x12, x11, #3             ; source (after "/..")
abs_norm_copy:
    ldrb w9, [x12]
    strb w9, [x19]
    cbz w9, abs_norm_restart
    add x12, x12, #1
    add x19, x19, #1
    b abs_norm_copy
abs_norm_restart:
    mov x19, x21                 ; restart scan
    b abs_norm_scan
abs_norm_skip:
    add x12, x11, #3             ; source after "/.."
    mov x19, x21                 ; dest = start
abs_norm_skip_copy:
    ldrb w9, [x12]
    strb w9, [x19]
    cbz w9, abs_norm_restart
    add x12, x12, #1
    add x19, x19, #1
    b abs_norm_skip_copy
abs_norm_found_end:
    ; "/.." at end of string
    mov x11, x19
    cmp x19, x21
    b.eq abs_norm_trunc_root
    sub x19, x19, #1
abs_norm_back_end:
    cmp x19, x21
    b.eq abs_norm_trunc
    ldrb w9, [x19]
    cmp w9, #0x2F
    b.eq abs_norm_trunc
    sub x19, x19, #1
    b abs_norm_back_end
abs_norm_trunc:
    strb wzr, [x19]
    ; If result is empty, make it "/"
    ldrb w9, [x21]
    cbnz w9, abs_norm_done
    mov w9, #0x2F
    strb w9, [x21]
    strb wzr, [x21, #1]
    b abs_norm_done
abs_norm_trunc_root:
    mov w9, #0x2F
    strb w9, [x21]
    strb wzr, [x21, #1]
    b abs_norm_done
abs_norm_next:
    add x19, x19, #1
    b abs_norm_scan
abs_norm_done:
    mov x0, x21                  ; return output buffer start

    ldr x30, [sp]
    ldr x19, [sp, #8]
    ldr x20, [sp, #16]
    ldr x21, [sp, #24]
    add sp, sp, #32
    ret

;============================================================
; find_file: Search for file by absolute path name
; x0 = path (absolute, null-terminated)
; Returns: x0 = file index (>= 3), or -1 if not found
;============================================================
find_file:
    sub sp, sp, #32
    str x30, [sp]
    str x19, [sp, #8]
    str x20, [sp, #16]
    str x21, [sp, #24]

    mov x19, x0                  ; saved path

    ; Load next_filenum
    movz x9, #0x4030, lsl #16
    ldr x20, [x9, #0x10]         ; next_filenum
    sub x20, x20, #1             ; start from last file

    ; File names base = 0x60900000
    movz x21, #0x6090, lsl #16

find_file_loop:
    cmp x20, #3
    b.lt find_file_not_found

    ; filename address = 0x60900000 + file_index * 1024
    lsl x9, x20, #10
    add x0, x21, x9
    mov x1, x19
    bl strcmp
    cbz x0, find_file_found

    sub x20, x20, #1
    b find_file_loop

find_file_not_found:
    movn x0, #0
    b find_file_ret

find_file_found:
    mov x0, x20

find_file_ret:
    ldr x30, [sp]
    ldr x19, [sp, #8]
    ldr x20, [sp, #16]
    ldr x21, [sp, #24]
    add sp, sp, #32
    ret

;============================================================
; fd_to_file_index: Get global file index from process fd
; x0 = fd
; Returns: x0 = global file index
;============================================================
fd_to_file_index:
    sub sp, sp, #16
    str x30, [sp]
    str x19, [sp, #8]
    mov x19, x0

    bl get_process_base
    add x0, x0, #0x200           ; open_files at +0x200
    lsl x9, x19, #3              ; fd * 8
    add x0, x0, x9
    ldr w0, [x0]                 ; global file index

    ldr x30, [sp]
    ldr x19, [sp, #8]
    add sp, sp, #16
    ret

;============================================================
; fdt_find_storage: Parse FDT to find storage device
; x0 = DTB pointer
; Returns: x0 = MMIO base (0 if not found), x1 = type (0/1/2)
;============================================================
fdt_find_storage:
    sub sp, sp, #96
    str x30, [sp]
    str x19, [sp, #8]
    str x20, [sp, #16]
    str x21, [sp, #24]
    str x22, [sp, #32]
    str x23, [sp, #40]
    str x24, [sp, #48]
    str x26, [sp, #56]
    str x27, [sp, #64]
    str x28, [sp, #72]
    str x25, [sp, #80]

    cbz x0, fdt_not_found
    mov x19, x0                    ; x19 = DTB base

    ; Validate FDT magic: 0xd00dfeed big-endian = 0xedfe0dd0 as LE lw
    ldr w9, [x19]
    movz x10, #0x0dd0
    movk x10, #0xedfe, lsl #16
    cmp w9, w10
    b.ne fdt_not_found

    ; Get structure block offset
    ldr w0, [x19, #8]
    bl bswap32
    add x20, x19, x0               ; x20 = struct block pointer

    ; Get strings block offset
    ldr w0, [x19, #0xC]
    bl bswap32
    add x21, x19, x0               ; x21 = strings block base

    mov x22, #0                    ; node type
    mov x23, #0                    ; candidate MMIO address
    mov x28, #0                    ; SPI base
    mov x25, #0                    ; mmc_found flag

fdt_walk:
    ldr w0, [x20]
    bl bswap32
    mov x27, x0                    ; token
    add x20, x20, #4

    cmp x27, #9
    b.eq fdt_walk_done
    cmp x27, #1
    b.eq fdt_begin_node
    cmp x27, #2
    b.eq fdt_end_node
    cmp x27, #3
    b.eq fdt_prop
    b fdt_walk

fdt_begin_node:
    mov x22, #0
    mov x23, #0

    ldr w9, [x20]

    ; "virt" = 0x74726976
    movz x10, #0x6976
    movk x10, #0x7472, lsl #16
    cmp w9, w10
    b.ne fdt_check_spi
    mov x22, #1
    b fdt_skip_name

fdt_check_spi:
    ; "spi@" = 0x40697073
    movz x10, #0x7073
    movk x10, #0x4069, lsl #16
    cmp w9, w10
    b.ne fdt_check_mmc
    mov x22, #2
    b fdt_skip_name

fdt_check_mmc:
    ; "mmc@" = 0x40636d6d
    movz x10, #0x6d6d
    movk x10, #0x4063, lsl #16
    cmp w9, w10
    b.ne fdt_skip_name
    cbz x28, fdt_skip_name
    mov x25, #1

fdt_skip_name:
    ldrb w9, [x20]
    add x20, x20, #1
    cbnz w9, fdt_skip_name
    add x20, x20, #3
    and x20, x20, #0xFFFFFFFFFFFFFFFC
    b fdt_walk

fdt_end_node:
    cmp x22, #1
    b.ne fdt_end_check_spi
    cbz x23, fdt_walk

    ; Probe VirtIO magic
    ldr w9, [x23]
    movz x10, #0x6976
    movk x10, #0x7472, lsl #16
    cmp w9, w10
    b.ne fdt_walk
    ldr w9, [x23, #8]
    cmp w9, #2
    b.ne fdt_walk

    mov x0, x23
    mov x1, #1
    b fdt_found

fdt_end_check_spi:
    cmp x22, #2
    b.ne fdt_walk
    cbz x23, fdt_walk
    mov x28, x23
    b fdt_walk

fdt_prop:
    ldr w0, [x20]
    bl bswap32
    mov x24, x0                    ; prop_len

    ldr w0, [x20, #4]
    bl bswap32
    mov x26, x0                    ; nameoff

    add x20, x20, #8

    cbz x22, fdt_prop_skip

    ; Check "reg\0" (byte-by-byte to avoid alignment fault)
    add x9, x21, x26
    ldrb w10, [x9]
    cmp w10, #0x72                   ; 'r'
    b.ne fdt_prop_skip
    ldrb w10, [x9, #1]
    cmp w10, #0x65                   ; 'e'
    b.ne fdt_prop_skip
    ldrb w10, [x9, #2]
    cmp w10, #0x67                   ; 'g'
    b.ne fdt_prop_skip
    ldrb w10, [x9, #3]
    cbnz w10, fdt_prop_skip          ; must be '\0'

    ; Extract MMIO base (8-byte)
    ldr w0, [x20]
    bl bswap32
    lsl x23, x0, #32
    ldr w0, [x20, #4]
    bl bswap32
    orr x23, x23, x0

    cmp x22, #2
    b.ne fdt_prop_skip
    mov x28, x23

fdt_prop_skip:
    add x20, x20, x24
    add x20, x20, #3
    and x20, x20, #0xFFFFFFFFFFFFFFFC
    b fdt_walk

fdt_walk_done:
    cbz x25, fdt_not_found
    cbz x28, fdt_not_found
    mov x0, x28
    mov x1, #2
    b fdt_found

fdt_not_found:
    mov x0, #0
    mov x1, #0

fdt_found:
    ldr x30, [sp]
    ldr x19, [sp, #8]
    ldr x20, [sp, #16]
    ldr x21, [sp, #24]
    ldr x22, [sp, #32]
    ldr x23, [sp, #40]
    ldr x24, [sp, #48]
    ldr x26, [sp, #56]
    ldr x27, [sp, #64]
    ldr x28, [sp, #72]
    ldr x25, [sp, #80]
    add sp, sp, #96
    ret

;============================================================
; virtio_init: Initialize VirtIO block device
; x0 = MMIO base address
;============================================================
virtio_init:
    sub sp, sp, #48
    str x30, [sp]
    str x19, [sp, #8]
    str x21, [sp, #16]
    str x22, [sp, #24]
    str x23, [sp, #32]

    cbz x0, virtio_init_fail
    mov x21, x0

    movz x22, #0x4050, lsl #16   ; VirtIO structs base
    movz x23, #0x4030, lsl #16   ; globals base

    ; Reset device
    str wzr, [x21, #0x70]

    ; Set ACKNOWLEDGE
    mov w9, #1
    str w9, [x21, #0x70]

    ; Set DRIVER
    mov w9, #3
    str w9, [x21, #0x70]

    ; Check version
    ldr w9, [x21, #4]
    cmp w9, #2
    b.eq virtio_modern_setup

virtio_legacy_setup:
    str wzr, [x21, #0x20]

    mov x0, x22
    movz x1, #0x2000
    bl memset_zero

    movz w9, #0x1000
    str w9, [x21, #0x28]

    str wzr, [x21, #0x30]

    mov w9, #8
    str w9, [x21, #0x38]

    movz w9, #0x1000
    str w9, [x21, #0x3C]

    ; QueuePFN = 0x40500000 / 4096 = 0x40500
    movz w9, #0x0500
    movk w9, #0x0004, lsl #16
    str w9, [x21, #0x40]

    mov w9, #7
    str w9, [x21, #0x70]

    b virtio_init_done

virtio_modern_setup:
    str wzr, [x21, #0x24]
    str wzr, [x21, #0x20]

    mov w9, #0xB
    str w9, [x21, #0x70]

    ldr w9, [x21, #0x70]
    and w9, w9, #8
    cbz w9, reboot

    mov x0, x22
    movz x1, #0x2000
    bl memset_zero

    str wzr, [x21, #0x30]

    mov w9, #8
    str w9, [x21, #0x38]

    mov w9, w22
    str w9, [x21, #0x80]
    lsr x9, x22, #32
    str w9, [x21, #0x84]

    add x9, x22, #0x80
    str w9, [x21, #0x90]
    lsr x10, x22, #32
    str w10, [x21, #0x94]

    movz x9, #0x1000
    add x9, x22, x9
    str w9, [x21, #0xA0]
    lsr x10, x22, #32
    str w10, [x21, #0xA4]

    mov w9, #1
    str w9, [x21, #0x44]

    mov w9, #0xF
    str w9, [x21, #0x70]

    b virtio_init_done

virtio_init_fail:
    mov x0, #0x21
    bl uart_putchar
    b reboot

virtio_init_done:
    ; Convert MMIO PA to VA by adding 0xC0000000 (Entry 3 mapping)
    movz x9, #0xC000, lsl #16
    add x21, x21, x9
    str x21, [x23, #0]
    str x22, [x23, #8]

    adr x9, virtio_read_sector
    str x9, [x23, #0x88]
    adr x9, virtio_write_sector
    str x9, [x23, #0x90]

    ldr x30, [sp]
    ldr x19, [sp, #8]
    ldr x21, [sp, #16]
    ldr x22, [sp, #24]
    ldr x23, [sp, #32]
    add sp, sp, #48
    ret

;============================================================
; disk_read_sector / disk_write_sector: dispatch via fn pointer
;============================================================
disk_read_sector:
    movz x9, #0x4030, lsl #16
    ldr x9, [x9, #0x88]
    br x9

disk_write_sector:
    movz x9, #0x4030, lsl #16
    ldr x9, [x9, #0x90]
    br x9

;============================================================
; virtio_read_sector: Read one 512-byte sector
; x0 = sector, x1 = dest buffer
;============================================================
virtio_read_sector:
    sub sp, sp, #48
    str x30, [sp]
    str x19, [sp, #8]
    str x20, [sp, #16]
    str x21, [sp, #24]
    str x22, [sp, #32]
    mov x20, x1

    movz x9, #0x4030, lsl #16
    ldr x21, [x9, #0]
    ldr x22, [x9, #8]

    movz x9, #0x1000
    add x9, x22, x9
    ldrh w19, [x9, #2]

    ; Header at x22 + 0x2000
    movz x9, #0x2000
    add x9, x22, x9
    str wzr, [x9]
    str wzr, [x9, #4]
    str x0, [x9, #8]

    ; Status byte
    movz x9, #0x2000
    add x9, x22, x9
    add x9, x9, #0x10
    mov w10, #0xFF
    strb w10, [x9]

    ; Desc 0
    movz x9, #0x2000
    add x9, x22, x9
    str x9, [x22]
    mov w9, #16
    str w9, [x22, #8]
    mov w9, #1
    strh w9, [x22, #12]
    mov w9, #1
    strh w9, [x22, #14]

    ; Desc 1
    str x20, [x22, #16]
    mov w9, #512
    str w9, [x22, #24]
    mov w9, #3
    strh w9, [x22, #28]
    mov w9, #2
    strh w9, [x22, #30]

    ; Desc 2
    movz x9, #0x2000
    add x9, x22, x9
    add x9, x9, #0x10
    str x9, [x22, #32]
    mov w9, #1
    str w9, [x22, #40]
    mov w9, #2
    strh w9, [x22, #44]
    strh wzr, [x22, #46]

    ; Available ring
    add x0, x22, #0x80
    strh wzr, [x0]
    ldrh w9, [x0, #2]
    and w10, w9, #7
    lsl w10, w10, #1
    add w10, w10, #4
    add x10, x0, x10
    strh wzr, [x10]
    add w9, w9, #1
    strh w9, [x0, #2]

    dsb sy
    str wzr, [x21, #0x50]

    movz x9, #0x1000
    add x0, x22, x9
virtio_read_poll:
    dsb sy
    ldrh w9, [x0, #2]
    cmp w9, w19
    b.eq virtio_read_poll

    ldr w9, [x21, #0x60]
    str w9, [x21, #0x64]

    movz x9, #0x2000
    add x9, x22, x9
    add x9, x9, #0x10
    ldrb w0, [x9]

    ldr x30, [sp]
    ldr x19, [sp, #8]
    ldr x20, [sp, #16]
    ldr x21, [sp, #24]
    ldr x22, [sp, #32]
    add sp, sp, #48
    ret

;============================================================
; virtio_write_sector: Write one 512-byte sector
; x0 = sector, x1 = source buffer
;============================================================
virtio_write_sector:
    sub sp, sp, #48
    str x30, [sp]
    str x19, [sp, #8]
    str x20, [sp, #16]
    str x21, [sp, #24]
    str x22, [sp, #32]
    mov x20, x1

    movz x9, #0x4030, lsl #16
    ldr x21, [x9, #0]
    ldr x22, [x9, #8]

    movz x9, #0x1000
    add x9, x22, x9
    ldrh w19, [x9, #2]

    ; Header (type=1 write)
    movz x9, #0x2000
    add x9, x22, x9
    mov w10, #1
    str w10, [x9]
    str wzr, [x9, #4]
    str x0, [x9, #8]

    ; Status
    movz x9, #0x2000
    add x9, x22, x9
    add x9, x9, #0x10
    mov w10, #0xFF
    strb w10, [x9]

    ; Desc 0
    movz x9, #0x2000
    add x9, x22, x9
    str x9, [x22]
    mov w9, #16
    str w9, [x22, #8]
    mov w9, #1
    strh w9, [x22, #12]
    mov w9, #1
    strh w9, [x22, #14]

    ; Desc 1 (device reads)
    str x20, [x22, #16]
    mov w9, #512
    str w9, [x22, #24]
    mov w9, #1
    strh w9, [x22, #28]
    mov w9, #2
    strh w9, [x22, #30]

    ; Desc 2
    movz x9, #0x2000
    add x9, x22, x9
    add x9, x9, #0x10
    str x9, [x22, #32]
    mov w9, #1
    str w9, [x22, #40]
    mov w9, #2
    strh w9, [x22, #44]
    strh wzr, [x22, #46]

    ; Available ring
    add x0, x22, #0x80
    strh wzr, [x0]
    ldrh w9, [x0, #2]
    and w10, w9, #7
    lsl w10, w10, #1
    add w10, w10, #4
    add x10, x0, x10
    strh wzr, [x10]
    add w9, w9, #1
    strh w9, [x0, #2]

    dsb sy
    str wzr, [x21, #0x50]

    movz x9, #0x1000
    add x0, x22, x9
virtio_write_poll:
    dsb sy
    ldrh w9, [x0, #2]
    cmp w9, w19
    b.eq virtio_write_poll

    ldr w9, [x21, #0x60]
    str w9, [x21, #0x64]

    movz x9, #0x2000
    add x9, x22, x9
    add x9, x9, #0x10
    ldrb w0, [x9]

    ldr x30, [sp]
    ldr x19, [sp, #8]
    ldr x20, [sp, #16]
    ldr x21, [sp, #24]
    ldr x22, [sp, #32]
    add sp, sp, #48
    ret

;============================================================
; SPI+SD Driver
;============================================================

spi_transfer:
    movz x9, #0x4030, lsl #16
    ldr x9, [x9, #0x98]
spi_tx_wait:
    ldr w10, [x9, #0x48]
    cmp w10, #0
    b.lt spi_tx_wait
    str w0, [x9, #0x48]
spi_rx_wait:
    ldr w0, [x9, #0x4C]
    cmp w0, #0
    b.lt spi_rx_wait
    and x0, x0, #0xFF
    ret

spi_sd_cmd:
    sub sp, sp, #16
    str x30, [sp]
    str x19, [sp, #8]

    bl spi_transfer

    lsr x0, x1, #24
    and x0, x0, #0xFF
    bl spi_transfer
    lsr x0, x1, #16
    and x0, x0, #0xFF
    bl spi_transfer
    lsr x0, x1, #8
    and x0, x0, #0xFF
    bl spi_transfer
    and x0, x1, #0xFF
    bl spi_transfer

    mov x0, x2
    bl spi_transfer

    mov x19, #8
spi_sd_cmd_poll:
    mov x0, #0xFF
    bl spi_transfer
    and x9, x0, #0x80
    cbz x9, spi_sd_cmd_done
    sub x19, x19, #1
    cbnz x19, spi_sd_cmd_poll
    mov x0, #0xFF

spi_sd_cmd_done:
    ldr x30, [sp]
    ldr x19, [sp, #8]
    add sp, sp, #16
    ret

spi_sd_init:
    movz x9, #0x4030, lsl #16
    ; Convert SPI MMIO PA to VA by adding 0xC0000000 (Entry 3 mapping)
    movz x10, #0xC000, lsl #16
    add x0, x0, x10
    str x0, [x9, #0x98]
    str x0, [x9, #0]

    adr x10, spi_sd_read_sector
    str x10, [x9, #0x88]
    adr x10, spi_sd_write_sector
    str x10, [x9, #0x90]
    ret

spi_sd_read_sector:
    sub sp, sp, #32
    str x30, [sp]
    str x19, [sp, #8]
    str x21, [sp, #16]

    mov x19, x1
    mov x21, x0

    mov x0, #0x51
    lsl x1, x21, #9
    mov x2, #0xFF
    bl spi_sd_cmd

spi_sd_read_wait_token:
    mov x0, #0xFF
    bl spi_transfer
    cmp x0, #0xFE
    b.ne spi_sd_read_wait_token

    mov x21, #512
spi_sd_read_loop:
    mov x0, #0xFF
    bl spi_transfer
    strb w0, [x19]
    add x19, x19, #1
    sub x21, x21, #1
    cbnz x21, spi_sd_read_loop

    mov x0, #0xFF
    bl spi_transfer
    mov x0, #0xFF
    bl spi_transfer

    mov x0, #0

    ldr x30, [sp]
    ldr x19, [sp, #8]
    ldr x21, [sp, #16]
    add sp, sp, #32
    ret

spi_sd_write_sector:
    sub sp, sp, #32
    str x30, [sp]
    str x19, [sp, #8]
    str x21, [sp, #16]

    mov x19, x1
    mov x21, x0

    mov x0, #0x58
    lsl x1, x21, #9
    mov x2, #0xFF
    bl spi_sd_cmd

    mov x0, #0xFF
    bl spi_transfer
    mov x0, #0xFE
    bl spi_transfer

    mov x21, #512
spi_sd_write_loop:
    ldrb w0, [x19]
    bl spi_transfer
    add x19, x19, #1
    sub x21, x21, #1
    cbnz x21, spi_sd_write_loop

    mov x0, #0xFF
    bl spi_transfer
    mov x0, #0xFF
    bl spi_transfer

    mov x0, #0xFF
    bl spi_transfer

spi_sd_write_busy:
    mov x0, #0xFF
    bl spi_transfer
    cbz x0, spi_sd_write_busy

    mov x0, #0

    ldr x30, [sp]
    ldr x19, [sp, #8]
    ldr x21, [sp, #16]
    add sp, sp, #32
    ret

;============================================================
; internalshell: Main command loop (runs in EL1, MMU ON)
;============================================================
internalshell:
    sub sp, sp, #64
    str x30, [sp]
    str x19, [sp, #8]
    str x20, [sp, #16]
    str x21, [sp, #24]
    str x22, [sp, #32]
    str x23, [sp, #40]
    str x24, [sp, #48]
    str x25, [sp, #56]

    ; Pre-load stdin data using CMD18 (raspi3b only — SDHCI PIO)
    ; On virt, skip preload (uses per-sector VirtIO reads)
    movz x9, #0x4030, lsl #16
    ldr x10, [x9, #0xA8]         ; board_has_sdhci flag
    cbz x10, shell_loop           ; skip preload if no SDHCI
    ldr x22, [x9, #0x00]         ; SDHCI base
    ; Read up to 16128 sectors (8MB) starting from stdin_sector into VA 0x42000000
    ldr x20, [x9, #0x30]         ; stdin_sector
    ; Store buffer pointer in globals+0x78
    ; Set to buffer - 512 so first advance (triggered by offset=512) lands at buffer start
    movz x10, #0x41FF, lsl #16
    movk x10, #0xFE00             ; 0x42000000 - 512 = 0x41FFFE00
    str x10, [x9, #0x78]
    ; Set stdin_offset to 512 to trigger first advance
    mov x10, #512
    str x10, [x9, #0x38]
    ; CMD18: multi-block read
    movz w10, #0xFFFF
    str w10, [x22, #0x30]
    movz w10, #0x0200
    strh w10, [x22, #0x04]        ; block size = 512
    movz w10, #0x3F00
    strh w10, [x22, #0x06]        ; block count = 16128
    lsl w10, w20, #9
    str w10, [x22, #0x08]         ; arg = stdin_sector * 512
    ; CMD18 + multi-block + block count enable + read + auto CMD12
    movz w10, #0x0036
    movk w10, #0x123A, lsl #16
    str w10, [x22, #0x0C]
    ; PIO read all blocks
    movz x19, #0x4200, lsl #16    ; buffer VA 0x42000000 (PA 0x02000000, slow but safe from file data)
    movz x23, #0x3F00             ; 16128 blocks
preload_block:
    cbz x23, preload_done
    ; Wait BRR for this block
preload_brr:
    bl sdhci_read_status
    and w11, w10, #0x20
    cbz w11, preload_brr
    ; Read 128 words for this block
    mov x20, #128
preload_pio:
    ldr w11, [x22, #0x20]
    str w11, [x19]
    add x19, x19, #4
    sub x20, x20, #1
    cbnz x20, preload_pio
    sub x23, x23, #1
    b preload_block
preload_done:
    ; Advance stdin_sector past preloaded data for per-sector fallback
    movz x9, #0x4030, lsl #16
    ldr x10, [x9, #0x30]         ; stdin_sector
    movz x11, #0x3F00             ; 16128
    add x10, x10, x11
    str x10, [x9, #0x30]         ; stdin_sector += 16128
    ; Clear status
    movz w10, #0xFFFF
    str w10, [x22, #0x30]

shell_loop:
    bl read_stdin_byte
    mov x19, x0

    cbz x19, shell_done

    cmp x19, #0x0A
    b.eq shell_loop
    cmp x19, #0x0D
    b.eq shell_loop

    cmp x19, #0x23
    b.eq shell_skip_comment

    cmp x19, #0x73
    b.eq handle_src

    cmp x19, #0x68
    b.eq handle_hex0

    cmp x19, #0x66
    b.eq handle_flush

    b handle_other_command

shell_skip_comment:
    bl read_stdin_byte
    cmp x0, #0x0A
    b.ne shell_skip_comment
    b shell_loop

shell_done:
    mov x0, #0x44
    bl uart_putchar
    mov x0, #0x6F
    bl uart_putchar
    mov x0, #0x6E
    bl uart_putchar
    mov x0, #0x65
    bl uart_putchar
    mov x0, #0x2E
    bl uart_putchar
    mov x0, #0x0A
    bl uart_putchar

    bl flush_disk
    b reboot

;============================================================
; handle_flush: 'f' command
;============================================================
handle_flush:
    bl read_stdin_byte

    movz x9, #0x4030, lsl #16
    mov x10, #1
    str x10, [x9, #0x48]

    mov x0, #0x66
    bl uart_putchar
    mov x0, #0x0A
    bl uart_putchar

    b shell_loop

;============================================================
; handle_src: 's' command - read file from stdin
;============================================================
handle_src:
    mov x0, #0x73
    bl uart_putchar
    mov x0, #0x72
    bl uart_putchar
    mov x0, #0x63
    bl uart_putchar
    mov x0, #0x20
    bl uart_putchar

    bl read_stdin_byte
    bl read_stdin_byte
    bl read_stdin_byte

    mov x20, #0
src_parse_count:
    bl read_stdin_byte
    cmp x0, #0x20
    b.eq src_count_done
    mov x9, #10
    mul x20, x20, x9
    sub x0, x0, #0x30
    add x20, x20, x0
    b src_parse_count
src_count_done:
    mov x21, x20

    movz x22, #0x6000, lsl #16
    mov x23, x22
src_read_name:
    bl read_stdin_byte
    cmp x0, #0x0A
    b.eq src_name_done
    strb w0, [x23]
    add x23, x23, #1
    b src_read_name
src_name_done:
    strb wzr, [x23]

    mov x0, x22
    bl print_string
    mov x0, #0x0A
    bl uart_putchar

    mov x0, x22
    bl absolute_path
    mov x22, x0

    movz x9, #0x4030, lsl #16
    ldr x23, [x9, #0x10]

    movz x10, #0x6090, lsl #16
    lsl x11, x23, #10
    add x10, x10, x11
    mov x11, x22
src_copy_fname:
    ldrb w12, [x11]
    strb w12, [x10]
    cbz w12, src_fname_done
    add x10, x10, #1
    add x11, x11, #1
    b src_copy_fname
src_fname_done:

    movz x9, #0x6082, lsl #16
    lsl x10, x23, #4
    add x22, x9, x10
    movz x9, #0x4030, lsl #16
    ldr x10, [x9, #0x18]
    str x10, [x22]
    str xzr, [x22, #8]

    ldr x10, [x9, #0x10]
    add x10, x10, #1
    str x10, [x9, #0x10]

    ldr x23, [x22]

src_read_data:
    cbz x20, src_data_done
    bl read_stdin_byte
    strb w0, [x23]
    add x23, x23, #1
    sub x20, x20, #1
    b src_read_data
src_data_done:

    str x21, [x22, #8]

    movz x9, #0x4030, lsl #16
    ldr x10, [x9, #0x18]
    add x10, x10, x21
    str x10, [x9, #0x18]

    b shell_loop

;============================================================
; handle_hex0: 'h' command - compile hex0 source to binary
;============================================================
handle_hex0:
    mov x0, #0x68
    bl uart_putchar
    mov x0, #0x65
    bl uart_putchar
    mov x0, #0x78
    bl uart_putchar
    mov x0, #0x30
    bl uart_putchar
    mov x0, #0x20
    bl uart_putchar

    bl read_stdin_byte
    bl read_stdin_byte
    bl read_stdin_byte
    bl read_stdin_byte

    movz x20, #0x6000, lsl #16
    mov x23, x20
hex0_read_input:
    bl read_stdin_byte
    cmp x0, #0x20
    b.eq hex0_input_done
    strb w0, [x23]
    add x23, x23, #1
    b hex0_read_input
hex0_input_done:
    strb wzr, [x23]

    mov x0, x20
    bl print_string
    mov x0, #0x20
    bl uart_putchar

    movz x21, #0x6000, lsl #16
    add x21, x21, #0x400
    mov x23, x21
hex0_read_output:
    bl read_stdin_byte
    cmp x0, #0x0A
    b.eq hex0_output_done
    strb w0, [x23]
    add x23, x23, #1
    b hex0_read_output
hex0_output_done:
    strb wzr, [x23]

    mov x0, x21
    bl print_string
    mov x0, #0x0A
    bl uart_putchar

    mov x0, x20
    bl absolute_path
    mov x20, x0
    bl find_file
    cmp x0, #0
    b.lt shell_loop
    mov x23, x0

    movz x9, #0x6082, lsl #16
    lsl x10, x23, #4
    add x9, x9, x10
    ldr x22, [x9]
    ldr x23, [x9, #8]

    mov x0, x21
    bl absolute_path
    mov x21, x0

    movz x9, #0x4030, lsl #16
    ldr x24, [x9, #0x10]

    movz x10, #0x6090, lsl #16
    lsl x11, x24, #10
    add x10, x10, x11
    mov x11, x21
hex0_copy_outname:
    ldrb w12, [x11]
    strb w12, [x10]
    cbz w12, hex0_outname_done
    add x10, x10, #1
    add x11, x11, #1
    b hex0_copy_outname
hex0_outname_done:

    movz x9, #0x6082, lsl #16
    lsl x10, x24, #4
    add x24, x9, x10
    movz x9, #0x4030, lsl #16
    ldr x10, [x9, #0x18]
    add x10, x10, #7
    and x10, x10, #0xFFFFFFFFFFFFFFF8
    str x10, [x9, #0x18]         ; aligned next_file_address
    str x10, [x24]
    str xzr, [x24, #8]

    ldr x10, [x9, #0x10]
    add x10, x10, #1
    str x10, [x9, #0x10]

    ldr x25, [x24]

    mov x19, #0
    mov x20, #0

hex0_compile_loop:
    cmp x20, x23
    b.ge hex0_compile_done

    add x9, x22, x20
    ldrb w0, [x9]
    add x20, x20, #1

    cmp w0, #0x23
    b.eq hex0_skip_comment
    cmp w0, #0x3B
    b.eq hex0_skip_comment

    cmp w0, #0x30
    b.lt hex0_compile_loop
    cmp w0, #0x3A
    b.lt hex0_digit
    cmp w0, #0x41
    b.lt hex0_compile_loop
    cmp w0, #0x47
    b.lt hex0_upper
    cmp w0, #0x61
    b.lt hex0_compile_loop
    cmp w0, #0x67
    b.lt hex0_lower
    b hex0_compile_loop

hex0_digit:
    sub x0, x0, #0x30
    b hex0_got_nibble
hex0_upper:
    sub x0, x0, #0x37
    b hex0_got_nibble
hex0_lower:
    sub x0, x0, #0x57
    b hex0_got_nibble

hex0_got_nibble:
    and x9, x19, #0xFF
    cbnz x9, hex0_second_nibble

    lsl x0, x0, #4
    lsl x0, x0, #8
    mov x9, #1
    orr x19, x0, x9
    b hex0_compile_loop

hex0_second_nibble:
    lsr x9, x19, #8
    and x9, x9, #0xF0
    orr x9, x9, x0
    strb w9, [x25]
    add x25, x25, #1
    mov x19, #0
    b hex0_compile_loop

hex0_skip_comment:
    cmp x20, x23
    b.ge hex0_compile_done
    add x9, x22, x20
    ldrb w0, [x9]
    add x20, x20, #1
    cmp w0, #0x0A
    b.ne hex0_skip_comment
    b hex0_compile_loop

hex0_compile_done:
    ldr x9, [x24]
    sub x9, x25, x9
    str x9, [x24, #8]

    movz x10, #0x4030, lsl #16
    ldr x11, [x10, #0x18]
    add x11, x11, x9
    str x11, [x10, #0x18]

    b shell_loop

;============================================================
; handle_other_command: Execute external program
;============================================================
handle_other_command:
    movz x9, #0x4030, lsl #16
    ldr x10, [x9, #0x48]
    cbz x10, hoc_no_flush
    bl flush_disk
hoc_no_flush:

    movz x20, #0x6000, lsl #16
    movz x9, #0x800
    add x20, x20, x9
    strb w19, [x20]
    add x21, x20, #1

hoc_read_name:
    bl read_stdin_byte
    cmp x0, #0x20
    b.eq hoc_name_done
    strb w0, [x21]
    add x21, x21, #1
    b hoc_read_name
hoc_name_done:
    strb wzr, [x21]

    movz x21, #0x6000, lsl #16
    movz x9, #0xC00
    add x21, x21, x9
    mov x22, x21
hoc_read_arg:
    bl read_stdin_byte
    cmp x0, #0x0A
    b.eq hoc_arg_done
    strb w0, [x22]
    add x22, x22, #1
    b hoc_read_arg
hoc_arg_done:
    strb wzr, [x22]

    mov x0, x20
    bl print_string
    mov x0, #0x20
    bl uart_putchar
    mov x0, x21
    bl print_string
    mov x0, #0x0A
    bl uart_putchar

    movz x9, #0x4030, lsl #16
    str x20, [x9, #0x58]
    str x21, [x9, #0x60]
    str xzr, [x9, #0x68]
    str xzr, [x9, #0x70]

    mov x0, x20
    bl absolute_path
    mov x20, x0

    bl find_file
    cmp x0, #0
    b.lt hoc_not_found
    mov x22, x0

    movz x9, #0x6082, lsl #16
    lsl x10, x22, #4
    add x9, x9, x10
    ldr x22, [x9]
    ldr x23, [x9, #8]

    movz x9, #0x4030, lsl #16
    ldr x10, [x9, #0x20]
    add x10, x10, #1
    str x10, [x9, #0x20]

    bl get_process_base
    mov x24, x0

    movz x9, #0x1000
    sub x9, x24, x9
    add x10, x9, #0x100
    add x11, x24, #0x100
    mov x12, #256
hoc_copy_cwd:
    cbz x12, hoc_cwd_done
    ldrb w13, [x10]
    strb w13, [x11]
    add x10, x10, #1
    add x11, x11, #1
    sub x12, x12, #1
    b hoc_copy_cwd
hoc_cwd_done:

    add x0, x24, #0x200
    movz x1, #0xE00
    bl memset_zero

    ldr x25, [x22, #0x18]
    ldr x9, [x22, #0x20]
    add x23, x22, x9
    ldrh w19, [x22, #0x38]

    movz x0, #0x4060, lsl #16
    movz x1, #0x20, lsl #16
    bl memset_zero

    movz x9, #0x4030, lsl #16
    movz x10, #0x4070, lsl #16
    str x10, [x9, #0x40]

hoc_load_phdr:
    cbz x19, hoc_load_done
    ldr w9, [x23]
    cmp w9, #1
    b.ne hoc_next_phdr

    ldr x9, [x23, #0x08]
    add x1, x22, x9
    ldr x9, [x23, #0x10]
    movz x10, #0x4000, lsl #16
    add x0, x9, x10
    ldr x2, [x23, #0x20]
    bl memcpy

    ldr x9, [x23, #0x10]
    ldr x10, [x23, #0x20]
    add x9, x9, x10
    movz x10, #0x4000, lsl #16
    add x9, x9, x10
    movz x10, #0x2000
    add x9, x9, x10
    movz x10, #0x4030, lsl #16
    ldr x11, [x10, #0x40]
    cmp x11, x9
    b.ge hoc_next_phdr
    str x9, [x10, #0x40]

hoc_next_phdr:
    add x23, x23, #56
    sub x19, x19, #1
    b hoc_load_phdr

hoc_load_done:
    movz x9, #0x4060, lsl #16
    str x9, [x24]

    str xzr, [x24, #0x20]

    movz x9, #0x6040, lsl #16
    movz x10, #0x1000
    add x9, x9, x10
    mov x10, sp
    str x10, [x9, #0x10]

    movz x19, #0x5000, lsl #16

    sub x19, x19, #8
    str xzr, [x19]

    sub x19, x19, #8
    str xzr, [x19]

    ; Copy arg to PA 0x4FF00000 (VA 0x0FF00000)
    movz x22, #0x4FF0, lsl #16
    mov x0, x22
    mov x1, x21
    mov x2, #256
    bl memcpy
    movz x9, #0x4000, lsl #16
    sub x9, x22, x9
    sub x19, x19, #8
    str x9, [x19]

    ; Copy command name to PA 0x4FF00100
    add x23, x22, #0x100
    mov x0, x23
    mov x1, x20
    mov x2, #256
    bl memcpy
    movz x9, #0x4000, lsl #16
    sub x9, x23, x9
    sub x19, x19, #8
    str x9, [x19]

    sub x19, x19, #8
    mov x9, #2
    str x9, [x19]

    movz x9, #0x4000, lsl #16
    sub x19, x19, x9

    ic iallu
    dsb sy
    isb

    msr elr_el1, x25

    movz x9, #0
    msr spsr_el1, x9

    msr sp_el0, x19
    eret

hoc_not_found:
    mov x0, #0x3F
    bl uart_putchar
    mov x0, #0x0A
    bl uart_putchar
    b shell_loop

shell_return:
    b shell_loop

; sdhci_read_status: Read SDHCI interrupt status (breaks TCG TB)
; x22 = SDHCI base. Returns w10 = status.
sdhci_read_status:
    ldr w10, [x22, #0x30]
    ret

; sdhci_read_status9: Same but using x9 as base
sdhci_read_status9:
    ldr w10, [x9, #0x30]
    ret

; sdhci_cmd_wait: Wait for Command Complete (bit 0), clear status
sdhci_cmd_wait:
    sub sp, sp, #16
    str x30, [sp]
sdhci_cmd_wait_loop:
    bl sdhci_read_status
    and w11, w10, #1
    cbz w11, sdhci_cmd_wait_loop
    movz w10, #0xFFFF
    str w10, [x22, #0x30]
    ldr x30, [sp]
    add sp, sp, #16
    ret

; sdhci_pio_read_word: Read one word from SDHCI data port
; x9 = SDHCI base. Returns w11 = data word.
sdhci_pio_read_word:
    ldr w11, [x9, #0x20]
    ret

; sdhci_read_sector: Read one 512-byte sector via SDHCI PIO
; x0 = sector number, x1 = destination buffer (VA)
; to avoid QEMU TCG translation block caching of MMIO reads.
sdhci_read_sector:
    sub sp, sp, #32
    str x30, [sp]
    str x19, [sp, #8]
    str x20, [sp, #16]
    mov x20, x0                  ; sector number
    mov x19, x1                  ; destination buffer
    movz x9, #0x4030, lsl #16
    ldr x22, [x9, #0x00]
    ; CMD17 (clear only CC+BRR+TC bits, not all)
    mov w10, #0x23
    str w10, [x22, #0x30]
    movz w10, #0x0200
    strh w10, [x22, #0x04]
    mov w10, #1
    strh w10, [x22, #0x06]
    lsl w10, w20, #9
    str w10, [x22, #0x08]
    movz w10, #0x0010
    movk w10, #0x113A, lsl #16
    str w10, [x22, #0x0C]
    ; Wait BRR using bl sdhci_read_status (proven to work)
sdhci_rs_brr:
    bl sdhci_read_status
    and w11, w10, #0x20
    cbz w11, sdhci_rs_brr
    ; PIO read 128 words
    mov x20, #128
sdhci_rs_pio:
    ldr w11, [x22, #0x20]
    str w11, [x19]
    add x19, x19, #4
    sub x20, x20, #1
    cbnz x20, sdhci_rs_pio
    ; Clear only CC+BRR+TC bits after PIO read
    mov w10, #0x23
    str w10, [x22, #0x30]
    ldr x30, [sp]
    ldr x19, [sp, #8]
    ldr x20, [sp, #16]
    add sp, sp, #32
    ret

; sdhci_reinit_card: Full CMD0-CMD16 re-init (x22 = SDHCI base)
sdhci_reinit_card:
    sub sp, sp, #16
    str x30, [sp]
    ; Software reset
    mov w10, #1
    strb w10, [x22, #0x2F]
    movz w10, #0x0001
    strh w10, [x22, #0x2C]
sdhci_ric_clk:
    ldrh w10, [x22, #0x2C]
    and w10, w10, #2
    cbz w10, sdhci_ric_clk
    movz w10, #0x0005
    strh w10, [x22, #0x2C]
    mov w10, #0x0F
    strb w10, [x22, #0x29]
    mov w10, #0x0E
    strb w10, [x22, #0x2E]
    movz w10, #0xFFFF
    str w10, [x22, #0x34]
    str w10, [x22, #0x38]
    ; CMD0
    str wzr, [x22, #0x08]
    str wzr, [x22, #0x0C]
    bl sdhci_cmd_wait
    ; CMD8
    movz w10, #0x01AA
    str w10, [x22, #0x08]
    movz w10, #0x0000
    movk w10, #0x081A, lsl #16
    str w10, [x22, #0x0C]
    bl sdhci_cmd_wait
    ; CMD55
    str wzr, [x22, #0x08]
    movz w10, #0x0000
    movk w10, #0x371A, lsl #16
    str w10, [x22, #0x0C]
    bl sdhci_cmd_wait
    ; ACMD41
    movz w10, #0x8000
    movk w10, #0x40FF, lsl #16
    str w10, [x22, #0x08]
    movz w10, #0x0000
    movk w10, #0x2902, lsl #16
    str w10, [x22, #0x0C]
    bl sdhci_cmd_wait
    ; CMD2
    str wzr, [x22, #0x08]
    movz w10, #0x0000
    movk w10, #0x0209, lsl #16
    str w10, [x22, #0x0C]
    bl sdhci_cmd_wait
    ; CMD3
    str wzr, [x22, #0x08]
    movz w10, #0x0000
    movk w10, #0x031A, lsl #16
    str w10, [x22, #0x0C]
    bl sdhci_cmd_wait
    ; CMD7
    ldr w10, [x22, #0x10]
    and w10, w10, #0xFFFF0000
    str w10, [x22, #0x08]
    movz w10, #0x0000
    movk w10, #0x071A, lsl #16
    str w10, [x22, #0x0C]
    bl sdhci_cmd_wait
    ; CMD16
    movz w10, #0x200
    str w10, [x22, #0x08]
    movz w10, #0x0000
    movk w10, #0x101A, lsl #16
    str w10, [x22, #0x0C]
    bl sdhci_cmd_wait
    ldr x30, [sp]
    add sp, sp, #16
    ret

sdhci_write_sector:
    sub sp, sp, #32
    str x30, [sp]
    str x19, [sp, #8]
    str x20, [sp, #16]
    mov x20, x0                  ; sector number
    mov x19, x1                  ; source buffer
    movz x9, #0x4030, lsl #16
    ldr x9, [x9, #0x00]
    movz w10, #0xFFFF
    str w10, [x9, #0x30]
    movz w10, #0x0200
    strh w10, [x9, #0x04]
    mov w10, #1
    strh w10, [x9, #0x06]
    lsl w10, w20, #9
    str w10, [x9, #0x08]
    movz w10, #0x0000
    movk w10, #0x183A, lsl #16
    str w10, [x9, #0x0C]
sdhci_ws_bwr:
    ldr w10, [x9, #0x30]
    and w11, w10, #0x10
    cbz w11, sdhci_ws_bwr
    mov x10, #128
sdhci_ws_pio:
    ldr w11, [x19]
    add x19, x19, #4
    str w11, [x9, #0x20]
    sub x10, x10, #1
    cbnz x10, sdhci_ws_pio
sdhci_ws_tc:
    ldr w10, [x9, #0x30]
    and w11, w10, #2
    cbz w11, sdhci_ws_tc
    movz w10, #0xFFFF
    str w10, [x9, #0x30]
    ldr x30, [sp]
    ldr x19, [sp, #8]
    ldr x20, [sp, #16]
    add sp, sp, #32
    ret

;============================================================
; flush_disk: Write /dev/hda file contents back to disk
;============================================================
flush_disk:
    sub sp, sp, #32
    str x30, [sp]
    str x19, [sp, #8]
    str x20, [sp, #16]
    str x21, [sp, #24]

    movz x0, #0x6000, lsl #16
    mov w9, #0x2F
    strb w9, [x0]
    mov w9, #0x64
    strb w9, [x0, #1]
    mov w9, #0x65
    strb w9, [x0, #2]
    mov w9, #0x76
    strb w9, [x0, #3]
    mov w9, #0x2F
    strb w9, [x0, #4]
    mov w9, #0x68
    strb w9, [x0, #5]
    mov w9, #0x64
    strb w9, [x0, #6]
    mov w9, #0x61
    strb w9, [x0, #7]
    strb wzr, [x0, #8]
    bl find_file
    cmp x0, #0
    b.lt flush_done

    movz x9, #0x6082, lsl #16
    lsl x10, x0, #4
    add x9, x9, x10
    ldr x19, [x9]
    ldr x20, [x9, #8]

    ; Re-init SDHCI before writing (needed after CMD18 preload)
    movz x9, #0x4030, lsl #16
    ldr x10, [x9, #0xA8]         ; board_has_sdhci?
    cbz x10, flush_skip_reinit
    ldr x22, [x9, #0x00]         ; SDHCI base
    bl sdhci_reinit_card
flush_skip_reinit:

    mov x21, #0
flush_sector_loop:
    cmp x20, #0
    b.le flush_done

    mov x0, x21
    mov x1, x19
    bl disk_write_sector

    add x19, x19, #512
    sub x20, x20, #512
    add x21, x21, #1
    b flush_sector_loop

flush_done:
    ldr x30, [sp]
    ldr x19, [sp, #8]
    ldr x20, [sp, #16]
    ldr x21, [sp, #24]
    add sp, sp, #32
    ret

;============================================================
; main: Boot sequence
;============================================================
main:
    ; Use SP_EL1 for kernel, then set it
    msr spsel, #1
    isb
    movz x9, #0x7B80, lsl #16
    mov sp, x9                       ; SP_EL1 = 0x7B800000

    ; Save x0 = stdin_sector and x1 = DTB pointer
    mov x24, x0
    mov x25, x1
    mov x26, x2
    ; x27 is set by _trampoline (3=raspi3b, 0=virt) — do not use x3


    ; Load RAM base into x20
    bl load_ram_base

    ; Set up exception vector table
    adr x9, exception_vectors
    msr vbar_el1, x9

    ; Disable all EL1 interrupts
    msr daifset, #0xF

    ; Set UART base for non-raspi3b boards (virt: PA 0x09000000, Entry 3 VA 0xC9000000)
    cmp x27, #3
    b.eq init_sdhci
    movz x9, #0xC900, lsl #16    ; virt UART VA via Entry 3
    movz x10, #0x4030, lsl #16
    str x9, [x10, #0xA0]

    ; Parse device tree
    mov x0, x25
    bl fdt_find_storage
    cmp x1, #1
    b.eq init_virtio
    cmp x1, #2
    b.eq init_spi_sd
    b reboot
init_sdhci:
    ; SDHCI and UART accessed via Entry 1 L2 Device entries (VA = PA + 0x40000000)
    ; x26 = SDHCI PA from stage1 (0x3F300000)
    movz x9, #0x4000, lsl #16
    add x22, x26, x9             ; x22 = SDHCI VA via Entry 1 (0x7F300000)
    and x9, x26, #0xFF000000
    movz x10, #0x0020, lsl #16
    movk x10, #0x1000
    orr x9, x9, x10
    movz x10, #0x4000, lsl #16
    add x9, x9, x10              ; x9 = UART VA via Entry 1 (0x7F201000)
    movz x10, #0x4030, lsl #16
    str x9, [x10, #0xA0]         ; UART VA = 0x7F201000
    str x22, [x10, #0x00]        ; SDHCI VA = 0x7F300000

    ; Initialize PL011 UART properly
    ; 1. Disable UART
    str wzr, [x9, #0x30]
    ; 2. Set UARTLCR_H: 8-bit word length (WLEN=11) + FIFO enable (FEN=1) = 0x70
    movz w10, #0x70
    str w10, [x9, #0x2C]
    ; 3. Enable UART (UARTEN=1, TXE=1, RXE=1 = 0x301)
    movz w10, #0x0301
    str w10, [x9, #0x30]

    ; No SDHCI re-init needed — stage1 already initialized the controller.
    ; The Entry 3 VA (0xFF300000) maps to the same PA (0x3F300000) that stage1 used.
    ; On raspi3b, MMU is already on — adr gives VA directly (no offset needed)
    adr x9, sdhci_read_sector
    movz x10, #0x4030, lsl #16
    str x9, [x10, #0x88]
    adr x9, sdhci_write_sector
    movz x10, #0x4030, lsl #16
    str x9, [x10, #0x90]
    mov x9, #1
    str x9, [x10, #0xA8]         ; board_has_sdhci = 1
    b storage_ready
init_virtio:
    bl virtio_init
    ; Clear board_has_sdhci (only for non-SDHCI boards)
    movz x9, #0x4030, lsl #16
    str xzr, [x9, #0xA8]
    b storage_ready
init_spi_sd:
    bl spi_sd_init
    ; Clear board_has_sdhci (SPI+SD is not SDHCI)
    movz x9, #0x4030, lsl #16
    str xzr, [x9, #0xA8]
storage_ready:

    ; Initialize global data
    movz x9, #0x4030, lsl #16

    mov x10, #3
    str x10, [x9, #0x10]

    movz x10, #0xA190, lsl #16   ; file data start past file names end
    str x10, [x9, #0x18]

    mov x10, #1
    str x10, [x9, #0x20]

    movz x10, #0x7800, lsl #16   ; save area at VA 0x78000000 (PA 0x38000000)
    str x10, [x9, #0x28]

    ; board_has_sdhci is set by init_sdhci or cleared by init_virtio — not touched here
    str xzr, [x9, #0x48]
    str xzr, [x9, #0x50]
    str xzr, [x9, #0x78]         ; stdin_buf_ptr = 0 (no preload; raspi3b sets this later)
    mov x10, #512
    str x10, [x9, #0x38]         ; stdin_offset = 512 (trigger first sector read)

    str x25, [x9, #0x80]

    movz x10, #0x4070, lsl #16
    str x10, [x9, #0x40]

    str x24, [x9, #0x30]
    mov x10, #512
    str x10, [x9, #0x38]

    ; Zero process descriptors (64KB at 0x60400000)
    movz x0, #0x6040, lsl #16
    movz x1, #0x10, lsl #12
    bl memset_zero

    ; Zero file names area (16MB at 0x60900000)
    movz x0, #0x6090, lsl #16
    movz x1, #0x100, lsl #16
    bl memset_zero

    ; Zero file descriptors area (512KB at 0x60820000)
    movz x0, #0x6082, lsl #16
    movz x1, #0x8, lsl #16
    bl memset_zero

    ; Set process 0 current_dir = "/"
    movz x9, #0x6040, lsl #16
    mov w10, #0x2F
    strb w10, [x9, #0x100]
    strb wzr, [x9, #0x101]
    ; Process 1
    movz x10, #0x1000
    add x9, x9, x10
    mov w10, #0x2F
    strb w10, [x9, #0x100]
    strb wzr, [x9, #0x101]

    ; Set up page table (skip on raspi3b — trampoline already did it)
    cmp x27, #3
    b.eq skip_page_table
    bl setup_page_table
    ; Enable MMU (stays on forever) — preserve RES1 bits
    mrs x9, sctlr_el1
    orr x9, x9, #1
    orr x9, x9, #4
    orr x9, x9, #0x1000
    msr sctlr_el1, x9
    isb
skip_page_table:

    ; SDHCI re-init skipped — stage1's re-init left card in transfer state

sdhci_reinit_done:

    ; Jump to internal shell
    b internalshell
