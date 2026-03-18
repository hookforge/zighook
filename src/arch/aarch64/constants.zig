//! AArch64-specific encoding constants shared across the backend.

/// AArch64 `brk #0`.
pub const brk_opcode: u32 = 0xD420_0000;

/// Mask used to recognize any `brk #imm16`.
pub const brk_mask: u32 = 0xFFE0_001F;

/// `ldr x16, #8`
pub const ldr_x16_literal_8: u32 = 0x5800_0050;

/// `br x16`
pub const br_x16: u32 = 0xD61F_0200;
