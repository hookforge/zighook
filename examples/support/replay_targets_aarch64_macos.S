.text
.p2align 2

// Returns the absolute address of `_demo_adr_expected`.
// This is the simplest PC-relative data-producing instruction to replay.
.globl _demo_adr_target
.globl _demo_adr_patchpoint
.globl _demo_adr_expected
_demo_adr_target:
_demo_adr_patchpoint:
    adr x0, _demo_adr_expected
    ret

.p2align 3
_demo_adr_expected:
    .quad 0x0102030405060708

// Returns the 4 KiB page base containing `_demo_adrp_data`.
// `adrp` is extremely common in compiler-generated code on Apple platforms.
.p2align 2
.globl _demo_adrp_target
.globl _demo_adrp_patchpoint
_demo_adrp_target:
_demo_adrp_patchpoint:
    adrp x0, _demo_adrp_data@PAGE
    ret

// Loads a 64-bit literal directly from a PC-relative literal pool entry.
.p2align 2
.globl _demo_ldr_x_literal_target
.globl _demo_ldr_x_literal_patchpoint
.globl _demo_ldr_x_literal_value
_demo_ldr_x_literal_target:
_demo_ldr_x_literal_patchpoint:
    ldr x0, _demo_ldr_x_literal_value
    ret

.p2align 3
_demo_ldr_x_literal_value:
    .quad 0x1122334455667788

// Loads a 32-bit literal and writes it to `w0`, which zero-extends into `x0`.
.p2align 2
.globl _demo_ldr_w_literal_target
.globl _demo_ldr_w_literal_patchpoint
.globl _demo_ldr_w_literal_value
_demo_ldr_w_literal_target:
_demo_ldr_w_literal_patchpoint:
    ldr w0, _demo_ldr_w_literal_value
    ret

.p2align 2
_demo_ldr_w_literal_value:
    .long 0x89ABCDEF

// Loads a 32-bit FP literal into `s0` and stores the full `q0` bits to memory.
// The preceding `movi` makes stale upper bits obvious if replay gets the
// scalar-register semantics wrong.
.p2align 2
.globl _demo_ldr_s_literal_target
.globl _demo_ldr_s_literal_patchpoint
.globl _demo_ldr_s_literal_value
_demo_ldr_s_literal_target:
    movi v0.16b, #0xff
_demo_ldr_s_literal_patchpoint:
    ldr s0, _demo_ldr_s_literal_value
    str q0, [x0]
    ret

.p2align 2
_demo_ldr_s_literal_value:
    .long 0x3F800000

// Loads a 64-bit FP literal into `d0` and stores the resulting `q0` bits.
.p2align 2
.globl _demo_ldr_d_literal_target
.globl _demo_ldr_d_literal_patchpoint
.globl _demo_ldr_d_literal_value
_demo_ldr_d_literal_target:
    movi v0.16b, #0xff
_demo_ldr_d_literal_patchpoint:
    ldr d0, _demo_ldr_d_literal_value
    str q0, [x0]
    ret

.p2align 3
_demo_ldr_d_literal_value:
    .quad 0x4000000000000000

// Loads a full 128-bit literal into `q0` and stores it back to memory.
.p2align 2
.globl _demo_ldr_q_literal_target
.globl _demo_ldr_q_literal_patchpoint
.globl _demo_ldr_q_literal_value
_demo_ldr_q_literal_target:
    movi v0.16b, #0xff
_demo_ldr_q_literal_patchpoint:
    ldr q0, _demo_ldr_q_literal_value
    str q0, [x0]
    ret

.p2align 4
_demo_ldr_q_literal_value:
    .quad 0x8877665544332211
    .quad 0x0F1E2D3C4B5A6978

// Loads a signed 32-bit literal and sign-extends it into `x0`.
.p2align 2
.globl _demo_ldrsw_literal_target
.globl _demo_ldrsw_literal_patchpoint
.globl _demo_ldrsw_literal_value
_demo_ldrsw_literal_target:
_demo_ldrsw_literal_patchpoint:
    ldrsw x0, _demo_ldrsw_literal_value
    ret

.p2align 2
_demo_ldrsw_literal_value:
    .long 0xFFFFFF80

// Calls a helper through a PC-relative `bl`.
.p2align 2
.globl _demo_bl_target
.globl _demo_bl_patchpoint
_demo_bl_target:
    mov x9, x30
_demo_bl_patchpoint:
    bl _demo_bl_helper
    mov x30, x9
    ret

_demo_bl_helper:
    mov w0, #77
    ret

// Branches on the flags produced by a preceding `cmp`.
.p2align 2
.globl _demo_b_eq_target
.globl _demo_b_eq_patchpoint
_demo_b_eq_target:
    cmp w0, w1
_demo_b_eq_patchpoint:
    b.eq _demo_b_eq_taken
    mov w0, #1
    ret

_demo_b_eq_taken:
    mov w0, #2
    ret

// Branches on whether `x0` is zero.
.p2align 2
.globl _demo_cbz_target
.globl _demo_cbz_patchpoint
_demo_cbz_target:
_demo_cbz_patchpoint:
    cbz x0, _demo_cbz_zero
    mov w0, #3
    ret

_demo_cbz_zero:
    mov w0, #4
    ret

// Branches on bit 3 of `x0`.
.p2align 2
.globl _demo_tbz_target
.globl _demo_tbz_patchpoint
_demo_tbz_target:
_demo_tbz_patchpoint:
    tbz x0, #3, _demo_tbz_clear
    mov w0, #5
    ret

_demo_tbz_clear:
    mov w0, #6
    ret

// Stores callback-provided `q0` bits to memory. The trapped instruction is a
// plain `nop`, so the test exercises context remapping / write-back instead of
// replay decoding.
.p2align 2
.globl _demo_fp_context_target
.globl _demo_fp_context_patchpoint
_demo_fp_context_target:
_demo_fp_context_patchpoint:
    nop
    str q0, [x0]
    ret

.data
.p2align 3

// Data symbol used by the `adrp` smoke target.
.globl _demo_adrp_data
_demo_adrp_data:
    .quad 0xCAFEBABEDEADBEEF
