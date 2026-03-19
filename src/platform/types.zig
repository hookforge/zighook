//! Shared platform-layer helper types.

/// Describes what kind of executable scratch page a trampoline needs.
pub const TrampolineKind = enum {
    /// Ordinary replay stubs with no architectural locality requirement.
    generic,
    /// Replay stubs for x86 RIP-relative instructions, which must stay within
    /// the signed 32-bit displacement window of the displaced instruction.
    rip_relative,
};
