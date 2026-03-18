//! zighook: experimental runtime patching and trap-based instrumentation.
//!
//! This rewrite currently implements the first backend slice:
//! - OS: macOS
//! - Architecture: AArch64 / Apple Silicon
//!
//! The design intentionally stays close to the original Rust crate:
//! - direct code patching
//! - trap-based instrumentation via `brk`
//! - signal-based function entry hooks
//! - jump detours
//! - fixed-size runtime registries

const builtin = @import("builtin");
const std = @import("std");

comptime {
    if (builtin.os.tag != .macos or builtin.cpu.arch != .aarch64) {
        @compileError("zighook currently implements only the macOS AArch64 backend.");
    }
}

const constants = @import("constants.zig");
const aarch64 = @import("arch/aarch64.zig");
const context = @import("context.zig");
const state = @import("state.zig");
const memory = @import("memory.zig");
const signal = @import("signal.zig");
const trampoline = @import("trampoline.zig");

pub const HookError = @import("error.zig").HookError;
pub const HookContext = context.HookContext;
pub const InstrumentCallback = context.InstrumentCallback;
pub const XRegisters = context.XRegisters;
pub const XRegistersNamed = context.XRegistersNamed;

/// How a trap-based API discovers the original instruction bytes it should
/// remember and, optionally, replay.
const InstallMode = enum {
    /// zighook patches the executable page at registration time.
    runtime_patch,
    /// the caller already arranged for `brk` to be present in the binary.
    prepatched,
};

/// Replaces one 32-bit instruction and returns the previous instruction word.
///
/// This API is ideal when:
/// - the patch fits in a single AArch64 instruction
/// - the caller already knows the exact opcode encoding
///
/// The original instruction is cached internally so `unhook(address)` can
/// restore the text page later and `original_opcode(address)` can report it.
pub fn patchcode(address: u64, new_opcode: u32) HookError!u32 {
    var original_bytes: [4]u8 = undefined;
    try memory.readInto(address, original_bytes[0..]);

    const inserted = try state.rememberPatch(address, original_bytes[0..]);
    errdefer if (inserted) state.discardPatch(address);

    _ = try memory.patchU32(address, new_opcode);

    const saved_opcode = std.mem.readInt(u32, original_bytes[0..], .little);
    state.cacheOriginalOpcode(address, saved_opcode);
    return saved_opcode;
}

/// Replaces an arbitrary number of bytes and returns the overwritten bytes.
///
/// The returned slice is allocated with `allocator`; the caller owns it.
///
/// Use this when the replacement does not fit in one instruction or when the
/// patch bytes come from some external encoder / assembler. zighook still keeps
/// its own restoration copy so `unhook(address)` remains available.
pub fn patch_bytes(allocator: std.mem.Allocator, address: u64, bytes: []const u8) HookError![]u8 {
    const original = try allocator.alloc(u8, bytes.len);
    errdefer allocator.free(original);

    try memory.readInto(address, original);

    const inserted = try state.rememberPatch(address, original);
    errdefer if (inserted) state.discardPatch(address);

    try memory.patchBytes(address, bytes);

    if (original.len >= 4) {
        state.cacheOriginalOpcode(address, std.mem.readInt(u32, original[0..4], .little));
    }
    return original;
}

/// Installs a trap-based instrumentation callback and replays the original
/// instruction through an internal trampoline before execution continues.
///
/// This is the closest equivalent to a "single-instruction probe":
/// - your callback sees and may edit the live register context
/// - if it leaves `ctx.pc` unchanged, zighook executes the trapped instruction
/// - execution then resumes at the following instruction
pub fn instrument(address: u64, callback: InstrumentCallback) HookError!u32 {
    return instrumentInternal(address, callback, true, false, .runtime_patch);
}

/// Installs a trap-based instrumentation callback and skips the original
/// instruction by default.
///
/// This is useful when the callback fully emulates or replaces the trapped
/// instruction. If the callback explicitly changes `ctx.pc`, that manual choice
/// still wins.
pub fn instrument_no_original(address: u64, callback: InstrumentCallback) HookError!u32 {
    return instrumentInternal(address, callback, false, false, .runtime_patch);
}

/// Hooks a function entry with a trap instruction and returns to the caller if
/// the callback does not override `ctx.pc`.
///
/// Typical usage:
/// - write the desired return value into `ctx.regs.named.x0`
/// - optionally edit other registers for side effects
/// - leave `ctx.pc` untouched so zighook returns to `lr`
pub fn inline_hook(address: u64, callback: InstrumentCallback) HookError!u32 {
    return instrumentInternal(address, callback, false, true, .runtime_patch);
}

/// Installs a direct jump detour at `address`.
///
/// Strategy:
/// - use a compact `b` instruction if possible
/// - fall back to an absolute literal-based jump sequence when required
///
/// Unlike `inline_hook(...)`, this API does not rely on signals once the patch
/// is installed: control transfers directly to `replace_fn`.
pub fn inline_hook_jump(address: u64, replace_fn: u64) HookError!u32 {
    const patch = try aarch64.makeInlineJumpPatch(address, replace_fn);
    var original: [aarch64.max_patch_len]u8 = undefined;

    try memory.readInto(address, original[0..patch.len]);

    const inserted = try state.rememberPatch(address, original[0..patch.len]);
    errdefer if (inserted) state.discardPatch(address);

    try memory.patchBytes(address, patch.bytes[0..patch.len]);

    const saved_opcode = std.mem.readInt(u32, original[0..4], .little);
    state.cacheOriginalOpcode(address, saved_opcode);
    return saved_opcode;
}

/// Restores or unregisters runtime state for a previously hooked address.
///
/// Behavior depends on how the address was installed:
/// - runtime patch APIs restore the original code bytes
/// - `prepatched::*` APIs remove runtime dispatch state only
///
/// Calling `unhook` on a direct patch made by `patchcode`, `patch_bytes`, or
/// `inline_hook_jump` restores the saved bytes and releases the cached slot.
pub fn unhook(address: u64) HookError!void {
    if (state.slotByAddress(address)) |slot| {
        if (slot.runtime_patch_installed) {
            try memory.patchBytes(address, slot.original_bytes[0..slot.original_len]);
        }

        if (state.removeHook(address)) |removed_slot| {
            if (removed_slot.trampoline_pc != 0) {
                trampoline.freeOriginalTrampoline(removed_slot.trampoline_pc);
            }
        }

        _ = state.removeCachedOriginalOpcode(address);
        return;
    }

    const patch = state.takePatch(address) orelse return error.HookNotFound;
    defer state.freeTakenPatch(patch);

    try memory.patchBytes(address, patch.original);
    _ = state.removeCachedOriginalOpcode(address);
}

/// Returns the cached original 32-bit instruction word if it is known.
///
/// This lookup covers:
/// - direct patch slots
/// - trap hook slots
/// - explicit `prepatched.cache_original_opcode(...)` registrations
pub fn original_opcode(address: u64) ?u32 {
    return state.cachedOriginalOpcode(address) orelse
        state.patchOriginalOpcode(address) orelse
        state.hookOriginalOpcode(address);
}

/// Convenience aliases that keep the external naming close to the Rust crate.
pub const patchBytes = patch_bytes;
pub const inlineHookJump = inline_hook_jump;
pub const originalOpcode = original_opcode;

/// APIs for trap points that were patched offline before process startup.
pub const prepatched = struct {
    /// Registers an already-trapped instruction and replays the original
    /// instruction through a trampoline.
    pub fn instrument(address: u64, callback: InstrumentCallback) HookError!u32 {
        return instrumentInternal(address, callback, true, false, .prepatched);
    }

    /// Registers an already-trapped instruction and skips the original
    /// instruction by default.
    pub fn instrument_no_original(address: u64, callback: InstrumentCallback) HookError!u32 {
        return instrumentInternal(address, callback, false, false, .prepatched);
    }

    /// Registers an already-trapped function entry hook.
    pub fn inline_hook(address: u64, callback: InstrumentCallback) HookError!u32 {
        return instrumentInternal(address, callback, false, true, .prepatched);
    }

    /// Stores the original instruction word for a prepatched trap point.
    ///
    /// This is required when using `prepatched.instrument(...)`, because the
    /// executable page already contains `brk`, not the original instruction.
    pub fn cache_original_opcode(address: u64, opcode: u32) HookError!void {
        if (address == 0 or (address & 0b11) != 0) return error.InvalidAddress;
        state.cacheOriginalOpcode(address, opcode);
    }
};

/// Ensures that a `prepatched::*` registration really points at a trap site.
fn ensurePrepatchedTrap(address: u64) HookError!void {
    const opcode = try memory.readU32(address);
    if (!memory.isBrk(opcode)) return error.InvalidAddress;
}

fn instrumentInternal(
    address: u64,
    callback: InstrumentCallback,
    execute_original: bool,
    return_to_caller: bool,
    install_mode: InstallMode,
) HookError!u32 {
    if (state.slotByAddress(address)) |slot| {
        // Re-registering the same address updates callback policy in-place.
        try state.registerHook(
            address,
            slot.original_bytes[0..slot.original_len],
            slot.step_len,
            callback,
            execute_original,
            return_to_caller,
            install_mode == .runtime_patch,
        );

        return state.cachedOriginalOpcode(address) orelse
            state.hookOriginalOpcode(address) orelse
            error.InvalidAddress;
    }

    try signal.ensureHandlersInstalled();

    const step_len = try memory.instructionWidth(address);

    var original_bytes_storage: [4]u8 = undefined;
    var saved_opcode: u32 = undefined;
    var runtime_patch_installed = false;

    switch (install_mode) {
        .runtime_patch => {
            // Replace the target instruction with `brk` immediately and keep
            // the original opcode for replay or later restoration.
            saved_opcode = try memory.patchU32(address, constants.brk_opcode);
            original_bytes_storage = std.mem.toBytes(std.mem.nativeToLittle(u32, saved_opcode));
            runtime_patch_installed = true;
        },
        .prepatched => {
            // The binary already contains `brk`, so registration is bookkeeping
            // only. For execute-original mode the caller must have cached the
            // displaced instruction ahead of time.
            try ensurePrepatchedTrap(address);

            if (execute_original) {
                saved_opcode = state.cachedOriginalOpcode(address) orelse return error.UnsupportedOperation;
                original_bytes_storage = std.mem.toBytes(std.mem.nativeToLittle(u32, saved_opcode));
            } else {
                saved_opcode = try memory.readU32(address);
                original_bytes_storage = std.mem.toBytes(std.mem.nativeToLittle(u32, saved_opcode));
            }
        },
    }

    state.registerHook(
        address,
        original_bytes_storage[0..],
        step_len,
        callback,
        execute_original,
        return_to_caller,
        runtime_patch_installed,
    ) catch |err| {
        if (runtime_patch_installed) {
            _ = memory.patchU32(address, saved_opcode) catch {};
        }
        return err;
    };

    if (runtime_patch_installed) {
        state.cacheOriginalOpcode(address, saved_opcode);
    }
    return saved_opcode;
}

extern fn demo_add_target(a: i32, b: i32) callconv(.c) i32;
extern fn demo_mul_replacement(a: i32, b: i32) callconv(.c) i32;
extern var demo_add_patchpoint: u8;

fn signalReturn42(_: u64, ctx: *HookContext) callconv(.c) void {
    ctx.regs.named.x0 = 42;
}

fn signalReturn99(_: u64, ctx: *HookContext) callconv(.c) void {
    ctx.regs.named.x0 = 99;
}

fn signalPrepare42(_: u64, ctx: *HookContext) callconv(.c) void {
    ctx.regs.named.x0 = 40;
    ctx.regs.named.x1 = 2;
}

test "patchcode detours and unhook restores" {
    const target_addr: u64 = @intFromPtr(&demo_add_target);
    const replacement_addr: u64 = @intFromPtr(&demo_mul_replacement);
    const branch_opcode = try aarch64.encodeBranch(target_addr, replacement_addr);

    try std.testing.expectEqual(@as(i32, 5), demo_add_target(2, 3));

    var restored = false;
    defer if (!restored) unhook(target_addr) catch {};

    const original = try patchcode(target_addr, branch_opcode);
    try std.testing.expectEqual(original, original_opcode(target_addr).?);
    try std.testing.expectEqual(@as(i32, 6), demo_add_target(2, 3));

    try unhook(target_addr);
    restored = true;

    try std.testing.expectEqual(@as(i32, 5), demo_add_target(2, 3));
    try std.testing.expectEqual(@as(?u32, null), original_opcode(target_addr));
}

test "patch_bytes writes a raw branch patch" {
    const target_addr: u64 = @intFromPtr(&demo_add_target);
    const replacement_addr: u64 = @intFromPtr(&demo_mul_replacement);
    const branch_opcode = try aarch64.encodeBranch(target_addr, replacement_addr);
    const patch = std.mem.toBytes(std.mem.nativeToLittle(u32, branch_opcode));

    try std.testing.expectEqual(@as(i32, 11), demo_add_target(5, 6));

    var restored = false;
    defer if (!restored) unhook(target_addr) catch {};

    const original = try patch_bytes(std.testing.allocator, target_addr, patch[0..]);
    defer std.testing.allocator.free(original);

    try std.testing.expectEqual(@as(usize, 4), original.len);
    try std.testing.expectEqual(std.mem.readInt(u32, original[0..4], .little), original_opcode(target_addr).?);
    try std.testing.expectEqual(@as(i32, 30), demo_add_target(5, 6));

    try unhook(target_addr);
    restored = true;

    try std.testing.expectEqual(@as(i32, 11), demo_add_target(5, 6));
}

test "inline_hook_jump detours and restores" {
    const target_addr: u64 = @intFromPtr(&demo_add_target);
    const replacement_addr: u64 = @intFromPtr(&demo_mul_replacement);

    try std.testing.expectEqual(@as(i32, 15), demo_add_target(7, 8));

    var restored = false;
    defer if (!restored) unhook(target_addr) catch {};

    const original = try inline_hook_jump(target_addr, replacement_addr);
    try std.testing.expectEqual(original, original_opcode(target_addr).?);
    try std.testing.expectEqual(@as(i32, 56), demo_add_target(7, 8));

    try unhook(target_addr);
    restored = true;

    try std.testing.expectEqual(@as(i32, 15), demo_add_target(7, 8));
}

test "inline_hook returns directly from the callback" {
    const target_addr: u64 = @intFromPtr(&demo_add_target);

    try std.testing.expectEqual(@as(i32, 7), demo_add_target(3, 4));

    var restored = false;
    defer if (!restored) unhook(target_addr) catch {};

    _ = try inline_hook(target_addr, signalReturn42);
    try std.testing.expectEqual(@as(i32, 42), demo_add_target(3, 4));

    try unhook(target_addr);
    restored = true;

    try std.testing.expectEqual(@as(i32, 7), demo_add_target(3, 4));
}

test "instrument executes the original instruction via trampoline" {
    const patchpoint_addr: u64 = @intFromPtr(&demo_add_patchpoint);

    try std.testing.expectEqual(@as(i32, 7), demo_add_target(3, 4));

    var restored = false;
    defer if (!restored) unhook(patchpoint_addr) catch {};

    _ = try instrument(patchpoint_addr, signalPrepare42);
    try std.testing.expectEqual(@as(i32, 42), demo_add_target(3, 4));

    try unhook(patchpoint_addr);
    restored = true;

    try std.testing.expectEqual(@as(i32, 7), demo_add_target(3, 4));
}

test "instrument_no_original skips the trapped instruction" {
    const patchpoint_addr: u64 = @intFromPtr(&demo_add_patchpoint);

    try std.testing.expectEqual(@as(i32, 7), demo_add_target(3, 4));

    var restored = false;
    defer if (!restored) unhook(patchpoint_addr) catch {};

    _ = try instrument_no_original(patchpoint_addr, signalReturn99);
    try std.testing.expectEqual(@as(i32, 99), demo_add_target(3, 4));

    try unhook(patchpoint_addr);
    restored = true;

    try std.testing.expectEqual(@as(i32, 7), demo_add_target(3, 4));
}

test "prepatched inline_hook unregisters runtime state without restoring text" {
    const patchpoint_addr: u64 = @intFromPtr(&demo_add_patchpoint);
    const original = try patchcode(patchpoint_addr, constants.brk_opcode);
    defer {
        // First remove runtime state if still present, then restore the original
        // instruction patch if the direct patch record still exists.
        unhook(patchpoint_addr) catch {};
        unhook(patchpoint_addr) catch {};
    }

    try prepatched.cache_original_opcode(patchpoint_addr, original);
    _ = try prepatched.inline_hook(patchpoint_addr, signalReturn42);
    try std.testing.expectEqual(@as(i32, 42), demo_add_target(3, 4));

    try unhook(patchpoint_addr);
    try std.testing.expectEqual(@as(u32, original), original_opcode(patchpoint_addr).?);
}
