#ifdef __APPLE__
#define SYM(x) _##x
#else
#define SYM(x) x
#endif

.text
.p2align 2

// Simple demo function used by tests and examples:
//   int add(int a, int b) { return a + b; }
//
// `_demo_add_patchpoint` intentionally points at the `add` instruction itself
// so instruction-level signal hooks can trap exactly one instruction.
.globl SYM(demo_add_target)
.globl SYM(demo_add_patchpoint)
SYM(demo_add_target):
SYM(demo_add_patchpoint):
    add w0, w0, w1
    ret

// Simple prepatched entry hook target. The instruction is already `brk #0`, so
// tests can exercise `prepatched.inline_hook(...)` without runtime text patching.
.globl SYM(demo_prepatched_target)
SYM(demo_prepatched_target):
    brk #0
    ret
