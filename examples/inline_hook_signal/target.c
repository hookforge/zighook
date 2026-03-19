#include <stdio.h>

#if defined(__APPLE__)
#define ASM_GLOBAL(name) ".globl _" #name "\n"
#define ASM_LABEL(name) "_" #name ":\n"
#else
#define ASM_GLOBAL(name) ".globl " #name "\n"
#define ASM_LABEL(name) #name ":\n"
#endif

#if defined(__aarch64__)
__asm__(
".text\n"
".p2align 2\n"
ASM_GLOBAL(target_add)
ASM_LABEL(target_add)
"add w0, w0, w1\n"
"ret\n"
);
#elif defined(__x86_64__)
__asm__(
".text\n"
".p2align 4\n"
ASM_GLOBAL(target_add)
ASM_LABEL(target_add)
"leal (%rdi,%rsi), %eax\n"
"ret\n"
);
#else
#error "inline_hook_signal target only supports AArch64 and x86_64"
#endif

extern int target_add(int a, int b);

int main(void) {
    printf("result=%d\n", target_add(2, 3));
    return 0;
}
