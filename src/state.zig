//! Fixed-size runtime registries.
//!
//! The implementation intentionally mirrors the Rust crate's design:
//! - fixed upper bound
//! - linear scans
//! - no hash maps
//! - no locking in the hot signal path
//!
//! This is not intended as a forever design, but it keeps the first rewrite
//! deterministic and close to the original crate's behavior.

const std = @import("std");

const HookError = @import("error.zig").HookError;
const constants = @import("constants.zig");
const aarch64 = @import("arch/aarch64.zig");

/// Instrumentation slot used by trap-based APIs.
pub const HookSlot = struct {
    /// Whether this slot currently contains live runtime state.
    used: bool = false,
    /// Address of the patched or prepatched trap point.
    address: u64 = 0,
    /// Cached original bytes that were replaced by the trap or need replay.
    original_bytes: [constants.max_saved_bytes]u8 = [_]u8{0} ** constants.max_saved_bytes,
    /// Number of valid bytes stored in `original_bytes`.
    original_len: u8 = 0,
    /// Width of the trapped instruction in bytes.
    step_len: u8 = 0,
    /// User callback invoked when the trap fires.
    callback: ?aarch64.InstrumentCallback = null,
    /// Whether execution should replay the original instruction.
    execute_original: bool = false,
    /// Whether the callback should return directly to the caller when it leaves
    /// `ctx.pc` untouched.
    return_to_caller: bool = false,
    /// Whether zighook itself installed the `brk` patch into the text page.
    runtime_patch_installed: bool = false,
    /// Precomputed execute-original strategy for the displaced instruction.
    replay_plan: aarch64.ReplayPlan = .{ .skip = {} },
    /// Address of the replay trampoline, if one was allocated.
    trampoline_pc: u64 = 0,
};

const OriginalOpcodeSlot = struct {
    used: bool = false,
    address: u64 = 0,
    opcode: u32 = 0,
};

var hook_slots: [constants.max_hooks]HookSlot = [_]HookSlot{.{}} ** constants.max_hooks;
var original_opcode_slots: [constants.max_hooks]OriginalOpcodeSlot = [_]OriginalOpcodeSlot{.{}} ** constants.max_hooks;
var original_opcode_replace_index: usize = 0;

fn findHookIndex(address: u64) ?usize {
    for (hook_slots, 0..) |slot, index| {
        if (slot.used and slot.address == address) return index;
    }
    return null;
}

fn findFreeHookIndex() ?usize {
    for (hook_slots, 0..) |slot, index| {
        if (!slot.used) return index;
    }
    return null;
}

fn findOriginalOpcodeIndex(address: u64) ?usize {
    for (original_opcode_slots, 0..) |slot, index| {
        if (slot.used and slot.address == address) return index;
    }
    return null;
}

/// Registers or updates a trap-based hook slot.
///
/// Re-registering the same address is allowed. As in the Rust crate, the most
/// recent registration replaces the callback policy for that address while
/// preserving the already captured original bytes and any previously allocated
/// trampoline.
pub fn registerHook(
    address: u64,
    original_bytes: []const u8,
    step_len: u8,
    callback: aarch64.InstrumentCallback,
    execute_original: bool,
    return_to_caller: bool,
    runtime_patch_installed: bool,
    replay_plan: aarch64.ReplayPlan,
) HookError!void {
    if (address == 0 or original_bytes.len == 0 or original_bytes.len > constants.max_saved_bytes or step_len == 0) {
        return error.InvalidAddress;
    }

    var stored_bytes: [constants.max_saved_bytes]u8 = [_]u8{0} ** constants.max_saved_bytes;
    @memcpy(stored_bytes[0..original_bytes.len], original_bytes);

    if (findHookIndex(address)) |index| {
        var slot = hook_slots[index];
        slot.callback = callback;
        slot.execute_original = execute_original;
        slot.return_to_caller = return_to_caller;
        slot.runtime_patch_installed = slot.runtime_patch_installed or runtime_patch_installed;
        slot.replay_plan = replay_plan;

        if (slot.original_len == 0) {
            slot.original_len = @intCast(original_bytes.len);
            slot.original_bytes = stored_bytes;
            slot.step_len = step_len;
        }

        if (execute_original and replay_plan.requiresTrampoline() and slot.trampoline_pc == 0) {
            // Trampolines are allocated lazily so `inline_hook(...)` and
            // `instrument_no_original(...)` do not pay RX memory overhead.
            slot.trampoline_pc = try aarch64.createOriginalTrampoline(
                address,
                slot.original_bytes[0..slot.original_len],
                slot.step_len,
            );
        }

        hook_slots[index] = slot;
        return;
    }

    const free_index = findFreeHookIndex() orelse return error.HookSlotsFull;
    const trampoline_pc = if (execute_original and replay_plan.requiresTrampoline())
        try aarch64.createOriginalTrampoline(address, original_bytes, step_len)
    else
        0;

    hook_slots[free_index] = .{
        .used = true,
        .address = address,
        .original_bytes = stored_bytes,
        .original_len = @intCast(original_bytes.len),
        .step_len = step_len,
        .callback = callback,
        .execute_original = execute_original,
        .return_to_caller = return_to_caller,
        .runtime_patch_installed = runtime_patch_installed,
        .replay_plan = replay_plan,
        .trampoline_pc = trampoline_pc,
    };
}

/// Looks up a hook slot by address.
pub fn slotByAddress(address: u64) ?HookSlot {
    const index = findHookIndex(address) orelse return null;
    return hook_slots[index];
}

/// Removes a hook slot and returns the owned record.
pub fn removeHook(address: u64) ?HookSlot {
    const index = findHookIndex(address) orelse return null;
    const slot = hook_slots[index];
    hook_slots[index] = .{};
    return slot;
}

/// Returns the original 32-bit instruction cached by a hook slot.
pub fn hookOriginalOpcode(address: u64) ?u32 {
    const slot = slotByAddress(address) orelse return null;
    if (slot.original_len < 4) return null;
    return std.mem.readInt(u32, slot.original_bytes[0..4], .little);
}

/// Stores an original opcode independently from the live hook slot registry.
///
/// This is required by the `prepatched::*` APIs, where the executable page
/// already contains a trap instruction at install time.
pub fn cacheOriginalOpcode(address: u64, opcode: u32) void {
    if (findOriginalOpcodeIndex(address)) |index| {
        original_opcode_slots[index].opcode = opcode;
        return;
    }

    for (original_opcode_slots, 0..) |slot, index| {
        if (!slot.used) {
            original_opcode_slots[index] = .{
                .used = true,
                .address = address,
                .opcode = opcode,
            };
            return;
        }
    }

    // If every slot is full, overwrite in round-robin order. This keeps the
    // storage fixed-size like the Rust crate and avoids heap allocation in
    // public registration paths.
    const replace_index = original_opcode_replace_index % constants.max_hooks;
    original_opcode_slots[replace_index] = .{
        .used = true,
        .address = address,
        .opcode = opcode,
    };
    original_opcode_replace_index = (replace_index + 1) % constants.max_hooks;
}

/// Returns a cached original opcode recorded independently from the hook slot.
pub fn cachedOriginalOpcode(address: u64) ?u32 {
    const index = findOriginalOpcodeIndex(address) orelse return null;
    return original_opcode_slots[index].opcode;
}

/// Removes a cached original opcode if present.
pub fn removeCachedOriginalOpcode(address: u64) bool {
    const index = findOriginalOpcodeIndex(address) orelse return false;
    original_opcode_slots[index] = .{};
    return true;
}
