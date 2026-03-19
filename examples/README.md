# zighook examples

These examples mirror the intent of the Rust `sighook` demos.

Current coverage:

- **AArch64 / ARM64:** macOS / iOS / Linux / Android
- **x86_64:** macOS / Linux first slice (`inline_hook_signal` and `prepatched_inline_hook`)

Each example directory is intentionally a standalone mini-project with exactly:

- `README.md`
- `target.c`
- `hook.zig`

The root `build.zig` does not build examples. That is deliberate: the example
directories are meant to show the real commands needed to compile a release C
target, compile a release Zig hook dylib, and inject that dylib with
platform-appropriate sidecar loading.

The example payloads now auto-select the constructor section:

- Mach-O (`macOS`, `iOS`): `__DATA,__mod_init_func`
- ELF (`Linux`, `Android`): `.init_array`

Common build pattern from inside an example directory:

```bash
cc -arch arm64 -O3 -DNDEBUG -Wl,-export_dynamic -o target target.c

zig build-lib -dynamic -OReleaseFast -femit-bin=hook.dylib \
  --dep zighook \
  -Mroot=hook.zig \
  -Mzighook=../../src/root.zig \
  -lc

DYLD_INSERT_LIBRARIES=$PWD/hook.dylib ./target
```

That exact command sequence is still the canonical **macOS runtime smoke** for
AArch64. On Linux, CI runs both AArch64 and x86_64 runtime smokes. For Linux /
iOS / Android deployment workflows, see:

- `../docs/platform-workflows.md`

Available examples:

- `inline_hook_signal`: function-entry trap hook, expected output `result=42`
- `instrument_with_original`: trap one instruction, edit registers, replay it, expected output `result=42` (AArch64 today)
- `instrument_no_original`: trap one instruction and replace it, expected output `result=99` (AArch64 today)
- `instrument_unhook_restore`: install a trap hook, call `unhook`, and confirm restoration, expected output `hooked=123` then `restored=5` (AArch64 today)
- `prepatched_inline_hook`: use `prepatched.inline_hook(...)` on a binary that already contains `brk`, expected output `result=77`

Each example README contains the exact commands and expected output. CI executes
the documented runtime smokes on both macOS and Linux and compares stdout
against those values.
