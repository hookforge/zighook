# zighook

`zighook` is a Zig rewrite of the sibling Rust `sighook` project.

Current scope:

- macOS
- Apple Silicon / AArch64

Implemented APIs:

- `instrument(address, callback)`
- `instrument_no_original(address, callback)`
- `inline_hook(address, callback)`
- `unhook(address)`
- `original_opcode(address)`
- `prepatched.instrument*`
- `prepatched.inline_hook`
- `prepatched.cache_original_opcode`

The current backend supports:

- trap-based instrumentation via `brk`
- signal-based entry hooks
- strict execute-original replay for common AArch64 PC-relative instructions
- public callback access to AArch64 FP/SIMD state (`fpregs.v[i]`, `fpregs.named.v0..v31`, `fpsr`, `fpcr`)
- constructor-based dylib payloads for `DYLD_INSERT_LIBRARIES` / later Mach-O insertion workflows

## Status

This repository currently targets the first backend slice only:

- `aarch64-apple-darwin`

It is usable for local experiments on Apple Silicon macOS, but it is not yet at full feature/platform parity with the Rust crate.

Current execute-original replay whitelist for PC-relative AArch64 instructions:

- `adr`
- `adrp`
- `ldr (literal)` into `wN`
- `ldr (literal)` into `xN`
- `ldr (literal)` into `sN`
- `ldr (literal)` into `dN`
- `ldr (literal)` into `qN`
- `ldrsw (literal)`
- `prfm (literal)`
- `b`
- `bl`
- `b.cond`
- `cbz` / `cbnz`
- `tbz` / `tbnz`

Unsupported execute-original cases fail at hook-install time instead of silently
falling back to unsafe trampoline replay.

## Build

```bash
zig build
zig build test
```

`build.zig` intentionally builds only the library and the test suite.
Examples are not wired into the root build because each example directory is
treated as a standalone mini-project with its own:

- `README.md`
- `target.c`
- `hook.zig`

As a library package, the repository also intentionally has no `src/main.zig`.

## Examples

Every example is built directly from inside its own directory with plain shell
commands. This keeps the example layout easy to read, keeps the injected hook
library self-contained, and avoids hiding the real build steps behind root
`build.zig` glue.

Common pattern:

```bash
cd examples/inline_hook_signal

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
- `instrument_with_original`: trap one instruction and replay it, expected output `result=42`
- `instrument_no_original`: trap one instruction and replace it, expected output `result=99`
- `instrument_unhook_restore`: install, unhook, and verify restoration, expected output `hooked=123` then `restored=5`
- `prepatched_inline_hook`: register a trap point that already contains `brk`, expected output `result=77`

CI runs these exact per-directory build commands and compares exact stdout.

See:

- `examples/README.md`
- each `examples/*/README.md`

## Public API Docs

The public integration guide lives directly in `src/root.zig`. Each exported
function is documented with behavior, installation rules, resume semantics, and
small code examples so callers can integrate the library without reading
internal backend code.

## License

This repository follows the same license file as the Rust `sighook` repository.
See `LICENSE`.
