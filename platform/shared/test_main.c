// Minimal C host for the Goose core test program: goose_init runs the Goose
// main(), which runs every test module and exits non-zero on failure.
#include <stdio.h>
#include <stdint.h>
void goose_init(int argc, char **argv);
void goose_exit(void);
int main(int argc, char **argv) {
    goose_init(argc, argv);
    goose_exit();
    printf("c-host: goose_exit returned 0\n");
    return 0;
}
