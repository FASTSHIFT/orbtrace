/* symprobe — load an ELF with orbuculum's loadelf and query symbolFunctionAt
 * for addresses given on argv, to see what orbetto's Mortrall would name them.
 * Build: see build_symprobe.sh */
#include <stdio.h>
#include <stdlib.h>
#include "loadelf.h"

int main(int argc, char *argv[])
{
    if (argc < 3) { fprintf(stderr, "usage: symprobe <elf> <hexaddr>...\n"); return 2; }
    struct symbol *s = symbolAcquire(argv[1], true, true);
    if (!s) { fprintf(stderr, "could not load %s\n", argv[1]); return 1; }
    for (int i = 2; i < argc; i++) {
        uint32_t a = (uint32_t)strtoul(argv[i], NULL, 0);
        struct symbolFunctionStore *f = symbolFunctionAt(s, a);
        struct symbolLineStore *l = symbolLineAt(s, a);
        printf("0x%08x -> func=%s line=%s\n", a,
               f ? f->funcname : "(NULL)",
               l ? "yes" : "(none)");
    }
    return 0;
}
