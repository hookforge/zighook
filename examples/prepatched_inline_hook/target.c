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
ASM_GLOBAL(target_prepatched)
ASM_LABEL(target_prepatched)
".inst 0xD4200000\n"
"ret\n"
);
#elif defined(__x86_64__)
__asm__(
".text\n"
".p2align 4\n"
ASM_GLOBAL(target_prepatched)
ASM_LABEL(target_prepatched)
"int3\n"
"ret\n"
);
#else
#error "prepatched_inline_hook target only supports AArch64 and x86_64"
#endif

extern int target_prepatched(void);

int main(void) {
    printf("result=%d\n", target_prepatched());
    return 0;
}
