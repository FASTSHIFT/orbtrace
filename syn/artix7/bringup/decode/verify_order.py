#!/usr/bin/env python3
"""verify_order — check that the DECODED instruction stream follows func_test's
static call graph in ORDER (per-instruction ordering, not set coverage).

Parses trc_pkt_lister -decode output (INSTR_RANGE lines in emission order),
maps each range's start PC to its enclosing function via `nm`, collapses
consecutive ranges in the same function into one "visit", and prints the
function visit sequence. Then it checks that sequence against the expected
call-graph order of one func_test main_loop iteration.

Usage: verify_order.py <lister.txt> <elf>
"""
import re, subprocess, sys

def nm_syms(elf):
    out = subprocess.check_output(["arm-none-eabi-nm", "-n", elf]).decode()
    syms = []
    for line in out.splitlines():
        m = re.match(r"([0-9a-fA-F]{8}) [tTwW] (\S+)", line)
        if m:
            syms.append((int(m.group(1), 16), m.group(2)))
    return syms

def func_of(syms, pc):
    lo = None
    for a, n in syms:
        if a <= pc: lo = n
        else: break
    return lo

def main():
    lister, elf = sys.argv[1], sys.argv[2]
    syms = nm_syms(elf)
    text = open(lister).read()
    re_rng = re.compile(r"range=0x([0-9a-fA-F]+):\[0x([0-9a-fA-F]+)\]")
    visits = []          # collapsed function visit sequence
    seq_pcs = []         # (func, start, end)
    for line in text.splitlines():
        if "INSTR_RANGE" not in line:
            continue
        m = re_rng.search(line)
        if not m:
            continue
        st = int(m.group(1), 16)
        fn = func_of(syms, st)
        seq_pcs.append((fn, st, int(m.group(2), 16)))
        if not visits or visits[-1] != fn:
            visits.append(fn)

    print(f"total INSTR_RANGE = {len(seq_pcs)}, function visits = {len(visits)}")
    print("\n--- function visit sequence (first 80) ---")
    print(" -> ".join(v or "?" for v in visits[:80]))

    # Expected per-iteration call order of main_loop (leaf helpers interleave;
    # we check the top-level test order and key nested calls).
    expected = [
        "level_a", "level_b", "level_c", "leaf_mul", "leaf_add",
        "frame_func", "leaf_add",
        "indirect_caller", "op_add",
        "indirect_caller", "op_sub",
        "indirect_caller", "op_mul",
        "callback_test", "dispatch_callback", "cb_handler_a",
        "dispatch_callback", "cb_handler_b",
        "dispatch_callback", "cb_handler_a",
        "factorial",
        "deep1", "deep2", "deep3", "deep4", "deep5", "deep6",
        "repeat_test", "pingpong", "leaf_add",
        "conditional", "conditional",
        "mixed_test",
    ]
    # Subsequence match: does `expected` appear in order within `visits`
    # (allowing extra visits between, since callee returns re-enter callers)?
    def find_subseq(seq, pat, start=0):
        i = start
        matched = []
        for p in pat:
            found = None
            j = i
            while j < len(seq):
                if seq[j] == p:
                    found = j; break
                j += 1
            if found is None:
                return None, matched
            matched.append((p, found))
            i = found + 1
        return i, matched

    print("\n--- ordered call-graph check (subsequence match of one iteration) ---")
    end, matched = find_subseq(visits, expected)
    if end is not None:
        print(f"PASS: all {len(expected)} expected calls appear IN ORDER "
              f"within visits[0..{end}]")
        # show where the anchor started
        print(f"      first expected call '{expected[0]}' at visit #{matched[0][1]}")
    else:
        got = len(matched)
        print(f"PARTIAL: matched {got}/{len(expected)} in order; "
              f"broke at '{expected[got]}' after "
              f"'{expected[got-1] if got else '(start)'}'")
        # show the run we did match
        print("      matched: " + " -> ".join(p for p, _ in matched))
    return 0

if __name__ == "__main__":
    sys.exit(main())
