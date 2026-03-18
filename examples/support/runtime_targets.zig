//! Shared extern declarations for the example and test runtime targets.
//!
//! The corresponding machine code lives in
//! `examples/support/runtime_targets_aarch64_macos.S`.

extern fn demo_add_target(a: i32, b: i32) callconv(.c) i32;
extern fn demo_mul_replacement(a: i32, b: i32) callconv(.c) i32;
extern var demo_add_patchpoint: u8;

pub const add_target = demo_add_target;
pub const mul_replacement = demo_mul_replacement;

/// Returns the address of the demo function entry (`add w0, w0, w1; ret`).
pub fn targetAddress() u64 {
    return @intFromPtr(&demo_add_target);
}

/// Returns the address of the replacement function entry (`mul w0, w0, w1; ret`).
pub fn replacementAddress() u64 {
    return @intFromPtr(&demo_mul_replacement);
}

/// Returns the address of the single instruction that is safe to instrument.
pub fn patchpointAddress() u64 {
    return @intFromPtr(&demo_add_patchpoint);
}
