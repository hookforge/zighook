.text
.p2align 2

// Simple demo function used by tests and examples:
//   int add(int a, int b) { return a + b; }
//
// `_demo_add_patchpoint` intentionally points at the `add` instruction itself
// so instruction-level signal hooks can trap exactly one instruction.
.globl _demo_add_target
.globl _demo_add_patchpoint
_demo_add_target:
_demo_add_patchpoint:
    add w0, w0, w1
    ret

// Simple prepatched entry hook target. The instruction is already `brk #0`, so
// tests can exercise `prepatched.inline_hook(...)` without runtime text patching.
.globl _demo_prepatched_target
_demo_prepatched_target:
    brk #0
    ret
