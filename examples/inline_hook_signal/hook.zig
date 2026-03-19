const builtin = @import("builtin");
const zighook = @import("zighook");

const init_section = switch (builtin.os.tag) {
    .macos, .ios => "__DATA,__mod_init_func",
    .linux => ".init_array",
    else => @compileError("example payload constructors are only implemented for Mach-O and ELF targets."),
};

extern fn dlsym(handle: ?*anyopaque, symbol: [*:0]const u8) ?*anyopaque;

fn rtldDefault() ?*anyopaque {
    return switch (builtin.os.tag) {
        .macos, .ios => @ptrFromInt(@as(usize, @bitCast(@as(isize, -2)))),
        .linux => null,
        else => @compileError("RTLD_DEFAULT is only implemented for Mach-O and ELF targets."),
    };
}

fn onHit(_: u64, ctx: *zighook.HookContext) callconv(.c) void {
    ctx.regs.named.x0 = 42;
}

fn install() callconv(.c) void {
    const symbol = dlsym(rtldDefault(), "target_add");
    if (symbol == null) return;
    _ = zighook.inline_hook(@intFromPtr(symbol.?), onHit) catch {};
}

const InitFn = *const fn () callconv(.c) void;
pub export const example_init: InitFn linksection(init_section) = &install;
