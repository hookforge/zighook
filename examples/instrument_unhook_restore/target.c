#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>

#if defined(__APPLE__)
#define ASM_GLOBAL(name) ".globl _" #name "\n"
#define ASM_LABEL(name) "_" #name ":\n"
#else
#define ASM_GLOBAL(name) ".globl " #name "\n"
#define ASM_LABEL(name) #name ":\n"
#endif

__asm__(
".text\n"
".p2align 2\n"
ASM_GLOBAL(target_add)
ASM_GLOBAL(target_add_patchpoint)
ASM_LABEL(target_add)
ASM_LABEL(target_add_patchpoint)
"add w0, w0, w1\n"
"ret\n"
);

extern int target_add(int a, int b);

typedef void (*unhook_fn_t)(void);

int main(void) {
    unhook_fn_t unhook_fn = (unhook_fn_t)dlsym(RTLD_DEFAULT, "zighook_example_unhook");
    if (unhook_fn == NULL) {
        fprintf(stderr, "missing unhook helper\n");
        return 1;
    }

    printf("hooked=%d\n", target_add(2, 3));
    unhook_fn();
    printf("restored=%d\n", target_add(2, 3));
    return 0;
}
