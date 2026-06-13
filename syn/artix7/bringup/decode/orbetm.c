/* orbetm — non-interactive ETM3.5 instruction-flow reconstruction, reusing
 * orbuculum's battle-tested decoder + symbol/disassembly engine.
 *
 * This REPLACES our hand-rolled etm_reconstruct.py decode core (which kept
 * mis-stepping on call/return). It is a faithful, stripped-down port of
 * orbmortem's _traceCB flow loop (Src/orbmortem.c) with the ncurses TUI and
 * post-mortem buffering removed: it pumps a raw bare-ETM byte stream through
 * liborb's TRACEDecoder, and for every atom walks the disassembled image
 * (capstone via loadelf.c), printing each executed instruction with its
 * function + source line. Call/return is tracked with the same return-address
 * stack and disposition logic orbmortem uses.
 *
 * Input must be a BARE ETM3.5 stream (TPIU sync fillers already stripped —
 * see dsl_parse.py / etm35lib.strip_tpiu_sync).
 *
 * Build: see build_orbetm.sh (compiles against the orbuculum checkout).
 *
 * Usage:
 *   orbetm <elf> <bare-etm-file> [--alt-addr]
 */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <stdbool.h>
#include <string.h>

#include "traceDecoder.h"
#include "loadelf.h"

#define MAX_CALL_STACK (32)

struct RT {
    struct TRACEDecoder i;
    struct symbol *s;
    uint32_t workingAddr;
    symbolMemaddr callStack[MAX_CALL_STACK];
    unsigned int stackDepth;
    bool stackDelPending;
    bool inRun;                 /* have we anchored on a first address yet */
    uint64_t insExec;           /* executed-instruction counter */
    uint64_t insSkipped;        /* instructions dropped (PC left known code) */
    uint32_t curFileIdx;
    struct symbolFunctionStore *curFunc;
    uint32_t curLine;
    uint32_t flashLo, flashHi;  /* code-range guard to suppress runaway */
};

static void addRet(struct RT *r, symbolMemaddr p)
{
    if (r->stackDepth == MAX_CALL_STACK) {
        memmove(&r->callStack[0], &r->callStack[1],
                sizeof(symbolMemaddr) * (MAX_CALL_STACK - 1));
        r->stackDepth--;
    }
    r->callStack[r->stackDepth++] = p;
}

static void emit(struct RT *r, symbolMemaddr addr, const char *asmline)
{
    struct symbolLineStore *l = symbolLineAt(r->s, addr);
    if (l && l->function &&
        (l->function->filename != r->curFileIdx || l->function != r->curFunc)) {
        printf("%s::%s\n", symbolGetFilename(r->s, l->function->filename),
               l->function->funcname);
        r->curFileIdx = l->function->filename;
        r->curFunc = l->function;
        r->curLine = 0;
    }
    printf("  0x%08x  %s\n", (unsigned)addr, asmline ? asmline : "?");
}

static void traceCB(void *d)
{
    struct RT *r = (struct RT *)d;
    struct TRACECPUState *cpu = TRACECPUState(&r->i);
    uint32_t incAddr = 0;
    uint32_t disposition = 0;
    enum instructionClass ic;
    symbolMemaddr newaddr;

    /* Exception entry: note it, push the preferred return (ETM3.5 gives addr) */
    if (TRACEStateChanged(&r->i, EV_CH_EX_ENTRY)) {
        printf("========== Exception Entry (%d at 0x%08x) ==========\n",
               cpu->exception, (unsigned)cpu->addr);
    }

    /* Address change: explicit set of the working address (I-sync / branch). */
    if (TRACEStateChanged(&r->i, EV_CH_ADDRESS)) {
        r->stackDelPending = false;
        r->workingAddr = cpu->addr;
        r->inRun = true;
    } else {
        if (r->stackDelPending && r->stackDepth) {
            r->stackDepth--;
        }
        r->stackDelPending = false;
    }

    if (TRACEStateChanged(&r->i, EV_CH_ENATOMS)) {
        incAddr = cpu->eatoms + cpu->natoms;
        disposition = cpu->disposition;
    }

    if (!r->inRun)
        return;                 /* not yet anchored: wait for first address */

    /* Walk the executed instructions (orbmortem _traceCB flow loop). A code-
     * range guard suppresses the runaway that happens when an indirect branch
     * has no stack candidate: the PC then walks off into the vector table /
     * non-code. We require the working address to be in the ELF code range
     * AND to disassemble; otherwise we drop the run and wait for the next
     * I-sync/branch address to re-anchor. (Confirmed against orbuculum's own
     * decoder: ~73% of decoded addresses on this branch-broadcast-off sparse
     * stream are out-of-range — an inherent data limitation, not a decoder
     * bug, so we gate rather than print garbage.) */
    while (incAddr) {
        bool inWindow = (r->workingAddr >= r->flashLo &&
                         r->workingAddr < r->flashHi);
        char *a = inWindow ?
            symbolDisassembleLine(r->s, &ic, r->workingAddr, &newaddr) : NULL;
        if (!a) {
            /* PC left the flash image: stop this run, wait to re-anchor on the
             * next I-sync/branch address. */
            r->insSkipped += incAddr;
            r->inRun = false;
            return;
        }

        bool insExecuted = (disposition & 1);
        if (insExecuted) {
            emit(r, r->workingAddr, a);
            r->insExec++;
        }
        disposition >>= 1;
        incAddr--;

        if (ic & LE_IC_CALL) {
            if (insExecuted) {
                addRet(r, r->workingAddr + ((ic & LE_IC_4BYTE) ? 4 : 2));
                r->workingAddr = newaddr;
            } else {
                r->workingAddr += (ic & LE_IC_4BYTE) ? 4 : 2;
            }
        } else if (ic & LE_IC_JUMP) {
            if (insExecuted) {
                if (ic & LE_IC_IMMEDIATE) {
                    r->workingAddr = newaddr;
                } else {
                    /* indirect: use a stacked return candidate if we have one */
                    if (r->stackDepth)
                        r->workingAddr = r->callStack[r->stackDepth - 1];
                    r->stackDelPending = true;
                }
            } else {
                r->workingAddr += (ic & LE_IC_4BYTE) ? 4 : 2;
            }
        } else {
            r->workingAddr += (ic & LE_IC_4BYTE) ? 4 : 2;
        }
    }
}

int main(int argc, char *argv[])
{
    if (argc < 3) {
        fprintf(stderr, "usage: %s <elf> <bare-etm-file> [--alt-addr]\n",
                argv[0]);
        return 1;
    }
    char *elf = argv[1];
    char *trace = argv[2];
    bool altAddr = (argc > 3 && strcmp(argv[3], "--alt-addr") == 0);

    struct RT r;
    memset(&r, 0, sizeof(r));
    /* Cortex-M flash code window. Skip the first 0x200 bytes: that region is
     * the exception vector table (data) which disassembles to junk and is
     * where a runaway PC tends to land after an unresolved indirect branch on
     * sparse trace. Real code starts above it (e.g. __main at 0x080001ac). */
    r.flashLo = 0x08000200;
    r.flashHi = 0x08060000;

    r.s = symbolAcquire(elf, true, true);
    if (!r.s || !symbolSetValid(r.s)) {
        fprintf(stderr, "ERROR: could not load symbols from %s\n", elf);
        return 1;
    }

    TRACEDecoderInit(&r.i, TRACE_PROT_ETM35, altAddr, NULL);

    FILE *f = fopen(trace, "rb");
    if (!f) { perror("open"); return 1; }

    uint8_t buf[4096];
    size_t n;
    uint64_t total = 0;
    while ((n = fread(buf, 1, sizeof(buf), f)) > 0) {
        TRACEDecoderPump(&r.i, buf, n, traceCB, &r);
        total += n;
    }
    fclose(f);

    struct TRACEDecoderStats *st = TRACEDecoderGetStats(&r.i);
    fprintf(stderr,
            "orbetm: %llu bytes; sync=%u lostSync=%u; "
            "executed=%llu dropped(off-code)=%llu\n",
            (unsigned long long)total, st->syncCount, st->lostSyncCount,
            (unsigned long long)r.insExec,
            (unsigned long long)r.insSkipped);
    symbolDelete(r.s);
    return 0;
}
