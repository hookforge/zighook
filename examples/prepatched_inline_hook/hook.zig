const zighook = @import("zighook");
const c = @cImport({
    @cInclude("dlfcn.h");
});

fn onHit(_: u64, ctx: *zighook.HookContext) callconv(.c) void {
    ctx.regs.named.x0 = 77;
}

fn install() callconv(.c) void {
    const symbol = c.dlsym(c.RTLD_DEFAULT, "target_prepatched");
    if (symbol == null) return;
    _ = zighook.prepatched.inline_hook(@intFromPtr(symbol.?), onHit) catch {};
}

const InitFn = *const fn () callconv(.c) void;
pub export const example_init: InitFn linksection("__DATA,__mod_init_func") = &install;
