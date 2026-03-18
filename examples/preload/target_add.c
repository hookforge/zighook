#include <stdio.h>
#include <stdlib.h>

__attribute__((visibility("default")))
__attribute__((noinline))
int target_add(int a, int b) {
    return a + b;
}

int main(void) {
    const char *expected_env = getenv("TARGET_EXPECT");
    const int expected = expected_env != NULL ? atoi(expected_env) : 5;
    const int result = target_add(2, 3);

    printf("target_add(2, 3) = %d\n", result);

    if (result != expected) {
        fprintf(stderr, "expected %d but got %d\n", expected, result);
        return 1;
    }

    return 0;
}
