//! Backend constants shared across the runtime patching modules.

/// Maximum number of active entries in each fixed-size runtime registry.
pub const max_hooks = 256;

/// Maximum amount of original instruction bytes cached per address.
///
/// The current backend only needs 4 or 16 bytes depending on the operation, but
/// keeping the storage at 16 bytes mirrors the Rust implementation and leaves
/// enough room for far jump restoration.
pub const max_saved_bytes = 16;

/// AArch64 `brk #0`.
pub const brk_opcode: u32 = 0xD420_0000;

/// Mask used to recognize any `brk #imm16`.
pub const brk_mask: u32 = 0xFFE0_001F;

/// `ldr x16, #8`
pub const ldr_x16_literal_8: u32 = 0x5800_0050;

/// `br x16`
pub const br_x16: u32 = 0xD61F_0200;
