const zighook = @import("zighook");
const c = @cImport({
    @cInclude("dlfcn.h");
});

var patchpoint_addr: u64 = 0;

fn onHit(_: u64, ctx: *zighook.HookContext) callconv(.c) void {
    ctx.regs.named.x0 = 123;
}

fn install() callconv(.c) void {
    const symbol = c.dlsym(c.RTLD_DEFAULT, "target_add_patchpoint");
    if (symbol == null) return;

    patchpoint_addr = @intFromPtr(symbol.?);
    _ = zighook.instrument_no_original(patchpoint_addr, onHit) catch {};
}

pub export fn zighook_example_unhook() callconv(.c) void {
    if (patchpoint_addr == 0) return;
    zighook.unhook(patchpoint_addr) catch {};
}

const InitFn = *const fn () callconv(.c) void;
pub export const example_init: InitFn linksection("__DATA,__mod_init_func") = &install;
