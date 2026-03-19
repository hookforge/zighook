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
const SavedInstruction = @import("saved_instruction.zig").SavedInstruction;
const arch = @import("arch/root.zig");

/// Instrumentation slot used by trap-based APIs.
pub const HookSlot = struct {
    /// Whether this slot currently contains live runtime state.
    used: bool = false,
    /// Address of the patched or prepatched trap point.
    address: u64 = 0,
    /// Bytes that must be written back when a runtime-installed trap is removed.
    original_bytes: [constants.max_saved_bytes]u8 = [_]u8{0} ** constants.max_saved_bytes,
    /// Number of bytes in `original_bytes` that must be restored.
    original_len: u8 = 0,
    /// Width of the displaced original instruction in bytes.
    step_len: u8 = 0,
    /// User callback invoked when the trap fires.
    callback: ?arch.InstrumentCallback = null,
    /// Whether execution should replay the original instruction.
    execute_original: bool = false,
    /// Whether the callback should return directly to the caller when it leaves
    /// `ctx.pc` untouched.
    return_to_caller: bool = false,
    /// Whether zighook itself installed the `brk` patch into the text page.
    runtime_patch_installed: bool = false,
    /// Precomputed execute-original strategy for the displaced instruction.
    replay_plan: arch.ReplayPlan = .{ .skip = {} },
    /// Address of the replay trampoline, if one was allocated.
    trampoline_pc: u64 = 0,
};

const OriginalInstructionSlot = struct {
    used: bool = false,
    address: u64 = 0,
    instruction: SavedInstruction = .{},
};

var hook_slots: [constants.max_hooks]HookSlot = [_]HookSlot{.{}} ** constants.max_hooks;
var original_instruction_slots: [constants.max_hooks]OriginalInstructionSlot = [_]OriginalInstructionSlot{.{}} ** constants.max_hooks;
var original_instruction_replace_index: usize = 0;

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

fn findOriginalInstructionIndex(address: u64) ?usize {
    for (original_instruction_slots, 0..) |slot, index| {
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
    callback: arch.InstrumentCallback,
    execute_original: bool,
    return_to_caller: bool,
    runtime_patch_installed: bool,
    replay_plan: arch.ReplayPlan,
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
            slot.trampoline_pc = try arch.createOriginalTrampoline(
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
        try arch.createOriginalTrampoline(address, original_bytes, step_len)
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

/// Returns the restore bytes cached by a hook slot.
pub fn hookOriginalInstruction(address: u64) ?SavedInstruction {
    const slot = slotByAddress(address) orelse return null;
    return SavedInstruction.fromSlice(slot.original_bytes[0..slot.original_len]) catch null;
}

/// Stores original instruction bytes independently from the live hook slot registry.
///
/// This is required by the `prepatched::*` APIs, where the executable page
/// already contains a trap instruction at install time.
pub fn cacheOriginalInstruction(address: u64, instruction: SavedInstruction) void {
    if (findOriginalInstructionIndex(address)) |index| {
        original_instruction_slots[index].instruction = instruction;
        return;
    }

    for (original_instruction_slots, 0..) |slot, index| {
        if (!slot.used) {
            original_instruction_slots[index] = .{
                .used = true,
                .address = address,
                .instruction = instruction,
            };
            return;
        }
    }

    // If every slot is full, overwrite in round-robin order. This keeps the
    // storage fixed-size like the Rust crate and avoids heap allocation in
    // public registration paths.
    const replace_index = original_instruction_replace_index % constants.max_hooks;
    original_instruction_slots[replace_index] = .{
        .used = true,
        .address = address,
        .instruction = instruction,
    };
    original_instruction_replace_index = (replace_index + 1) % constants.max_hooks;
}

/// Returns cached original instruction bytes recorded independently from the hook slot.
pub fn cachedOriginalInstruction(address: u64) ?SavedInstruction {
    const index = findOriginalInstructionIndex(address) orelse return null;
    return original_instruction_slots[index].instruction;
}

/// Removes cached original instruction metadata if present.
pub fn removeCachedOriginalInstruction(address: u64) bool {
    const index = findOriginalInstructionIndex(address) orelse return false;
    original_instruction_slots[index] = .{};
    return true;
}
