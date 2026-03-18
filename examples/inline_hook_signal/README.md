# inline_hook_signal

This example installs a function-entry hook with `zighook.inline_hook(...)`.

The target program exports an AArch64 function called `target_add`. The hook
library is injected with `DYLD_INSERT_LIBRARIES`, resolves `target_add` with
`dlsym`, and replaces the call result by writing `x0 = 42` inside the callback.

## Build

Build the C target in release mode:

```bash
cc -arch arm64 -O3 -DNDEBUG -Wl,-export_dynamic -o target target.c
```

Build the Zig hook library in release mode:

```bash
zig build-lib -dynamic -OReleaseFast -femit-bin=hook.dylib \
  --dep zighook \
  -Mroot=hook.zig \
  -Mzighook=../../src/root.zig \
  -lc
```

## Run

```bash
DYLD_INSERT_LIBRARIES=$PWD/hook.dylib ./target
```

## Expected Output

```text
result=42
```
