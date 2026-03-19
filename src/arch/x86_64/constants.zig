//! x86_64 trap-instruction constants.

pub const int3_opcode: u8 = 0xCC;
pub const int3_bytes = [_]u8{int3_opcode};
