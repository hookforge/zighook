# zighook examples

These examples mirror the intent of the Rust `sighook` demos, but are currently
implemented only for the first completed backend slice:

- **OS:** macOS
- **Architecture:** Apple Silicon / AArch64

Each example directory is intentionally a standalone mini-project with exactly:

- `README.md`
- `target.c`
- `hook.zig`

The root `build.zig` does not build examples. That is deliberate: the example
directories are meant to show the real commands needed to compile a release C
target, compile a release Zig hook dylib, and inject that dylib with
`DYLD_INSERT_LIBRARIES`.

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

Available examples:

- `inline_hook_signal`: function-entry trap hook, expected output `result=42`
- `instrument_with_original`: trap one instruction, edit registers, replay it, expected output `result=42`
- `instrument_no_original`: trap one instruction and replace it, expected output `result=99`
- `instrument_unhook_restore`: install a trap hook, call `unhook`, and confirm restoration, expected output `hooked=123` then `restored=5`
- `prepatched_inline_hook`: use `prepatched.inline_hook(...)` on a binary that already contains `brk`, expected output `result=77`

Each example README contains the exact commands and expected output. CI executes
the same commands directly and compares stdout against those documented values.
