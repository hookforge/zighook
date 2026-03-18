# prepatched_inline_hook

This example demonstrates `zighook.prepatched.inline_hook(...)`.

The C target already contains a `brk #0` instruction at the function entry, so
the hook library only needs to register runtime state for that address. The
callback returns a synthetic value directly to the caller.

## Build

```bash
cc -arch arm64 -O3 -DNDEBUG -Wl,-export_dynamic -o target target.c
```

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
result=77
```
