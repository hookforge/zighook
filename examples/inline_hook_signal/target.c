#include <stdio.h>

__asm__(
".text\n"
".p2align 2\n"
".globl _target_add\n"
"_target_add:\n"
"add w0, w0, w1\n"
"ret\n"
);

extern int target_add(int a, int b);

int main(void) {
    printf("result=%d\n", target_add(2, 3));
    return 0;
}
