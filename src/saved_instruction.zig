//! Shared byte-oriented representation of a displaced machine instruction.
//!
//! Fixed-width ISAs can interpret the full byte payload as an opcode word.
//! Variable-length ISAs use the same container to preserve exact instruction
//! bytes and lengths without forcing a `u32` abstraction onto every backend.

const std = @import("std");

const constants = @import("constants.zig");
const HookError = @import("error.zig").HookError;

pub const SavedInstruction = struct {
    bytes: [constants.max_saved_bytes]u8 = [_]u8{0} ** constants.max_saved_bytes,
    len: u8 = 0,

    pub fn fromSlice(bytes: []const u8) HookError!SavedInstruction {
        if (bytes.len == 0 or bytes.len > constants.max_saved_bytes) {
            return error.InvalidAddress;
        }

        var saved = SavedInstruction{ .len = @intCast(bytes.len) };
        @memcpy(saved.bytes[0..bytes.len], bytes);
        return saved;
    }

    pub fn slice(self: *const SavedInstruction) []const u8 {
        return self.bytes[0..self.len];
    }

    pub fn exactU32(self: *const SavedInstruction) ?u32 {
        if (self.len != 4) return null;
        return std.mem.readInt(u32, self.bytes[0..4], .little);
    }

    pub fn prefixU32(self: *const SavedInstruction) u32 {
        var prefix = [_]u8{0} ** 4;
        const copy_len = @min(@as(usize, self.len), prefix.len);
        @memcpy(prefix[0..copy_len], self.bytes[0..copy_len]);
        return std.mem.readInt(u32, prefix[0..], .little);
    }
};
