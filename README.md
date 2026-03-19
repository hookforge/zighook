# zighook

`zighook` is a Zig rewrite of the sibling Rust `sighook` project.

Current scope:

- macOS
- iOS
- Linux
- Android
- AArch64 / ARM64
- x86_64 (macOS / Linux first slice)

Implemented APIs:

- `instrument(address, callback)`
- `instrument_no_original(address, callback)`
- `inline_hook(address, callback)`
- `unhook(address)`
- `patch_bytes(address, bytes)`
- `original_instruction(address)`
- `cache_original_instruction(address, bytes)`
- `original_opcode(address)`
- `prepatched.instrument*`
- `prepatched.inline_hook`
- `prepatched.cache_original_instruction`
- `prepatched.cache_original_opcode`

The current backends support:

- trap-based instrumentation via `brk` (AArch64) or `int3` (x86_64)
- signal-based entry hooks on AArch64 and x86_64
- strict execute-original replay for common AArch64 PC-relative instructions
- public callback access to AArch64 FP/SIMD state (`fpregs.v[i]`, `fpregs.named.v0..v31`, `fpsr`, `fpcr`)
- public callback access to x86_64 XMM state (`fpregs.xmm[i]`, `fpregs.named.xmm0..xmm15`, `mxcsr`)
- constructor-based payloads for both Mach-O (`__mod_init_func`) and ELF (`.init_array`)

## Status

Implemented AArch64 platform backends:

- `aarch64-macos`
- `aarch64-ios`
- `aarch64-linux`
- `aarch64-linux-android` at the code/backend level via the Linux-family signal path

Implemented x86_64 platform backends:

- `x86_64-macos`
- `x86_64-linux`

Verification status:

- macOS AArch64: runtime-tested locally and in CI
- Linux AArch64: runtime-tested in CI
- iOS AArch64: cross-compiled core dylib and Mach-O payload locally
- Android AArch64: compiled core/payload objects against a local NDK sysroot
- Linux x86_64: runtime-tested in CI
- macOS x86_64: core library and example payload cross-compiled

x86_64 backend scope in this first slice:

- `inline_hook(...)`: supported
- `prepatched.inline_hook(...)`: supported
- `instrument_no_original(...)`: supported when the caller first provides
  original instruction bytes with `cache_original_instruction(...)`
- `instrument(...)`: not implemented yet and currently returns
  `error.ReplayUnsupported`

Deployment model by platform:

- macOS: runtime patching or prepatched trap sites, usually with `DYLD_INSERT_LIBRARIES`
- Linux: runtime patching or prepatched trap sites, usually with `LD_PRELOAD` or `patchelf`
- iOS: recommended prepatched trap sites plus inserted dylib + re-sign
- Android: Linux-family backend plus sidecar `.so`, typically loaded via patched ELF metadata / app packaging

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

For Linux, iOS, and Android deployment flows, see:

- `docs/platform-workflows.md`

Available examples:

- `inline_hook_signal`: function-entry trap hook, expected output `result=42`
- `instrument_with_original`: trap one instruction and replay it, expected output `result=42`
- `instrument_no_original`: trap one instruction and replace it, expected output `result=99`
- `instrument_unhook_restore`: install, unhook, and verify restoration, expected output `hooked=123` then `restored=5`
- `prepatched_inline_hook`: register a trap point that already contains `brk`, expected output `result=77`

CI runs these exact per-directory build commands and compares exact stdout.
The current x86_64 Linux CI smoke runs the `inline_hook_signal` and
`prepatched_inline_hook` examples.

See:

- `docs/platform-workflows.md`
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
