# instrument_no_original

This example traps one instruction and replaces its result in the callback with
`zighook.instrument_no_original(...)`.

The C target exposes a symbol named `target_add_patchpoint` that points at the
single `add w0, w0, w1` instruction. The hook library resolves that symbol and
forces the result to `99` without replaying the original instruction.

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
result=99
```
