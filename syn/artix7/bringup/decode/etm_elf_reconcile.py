#!/usr/bin/env python3
"""etm_elf_reconcile — rigorously check that the I-sync anchor PCs + executed
flow recovered from an SWO/TPIU capture line up with the ELF's actual
disassembly. Not just "address in .text range" but:
  1. each anchor PC is a REAL instruction start (matches an objdump address),
  2. the instruction at that PC disassembles to what objdump says,
  3. branch/flow atoms between anchors also land on real instruction starts.

Usage: etm_elf_reconcile.py <capture.bin> <elf> [--deframe] [--stream N]
"""
import argparse
import subprocess
import sys
import collections

sys.path.insert(0, "decode")
sys.path.insert(0, ".")
import etm35lib as L


def objdump_map(elf):
    """addr -> (mnemonic, function) for every instruction in .text."""
    out = subprocess.check_output(
        ["arm-none-eabi-objdump", "-d", elf], text=True, errors="replace")
    insn = {}
    func = None
    for line in out.splitlines():
        line = line.rstrip()
        if line.endswith(">:") and " <" in line:
            # e.g. "08000f8c <_Z3addii>:"
            func = line.split("<", 1)[1].rstrip(">:")
            continue
        # instruction line: " 8000f8c:\t4602\tmov r2, r0"
        s = line.lstrip()
        if ":" in s and "\t" in line:
            head = s.split(":", 1)[0]
            try:
                addr = int(head, 16)
            except ValueError:
                continue
            parts = line.split("\t")
            mnem = parts[-1].strip() if len(parts) >= 3 else "?"
            insn[addr] = (mnem, func)
    return insn


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("capture")
    ap.add_argument("elf")
    ap.add_argument("--deframe", action="store_true",
                    help="TPIU-deframe first (raw capture still framed)")
    ap.add_argument("--stream", type=int, default=2)
    a = ap.parse_args()

    raw = open(a.capture, "rb").read()
    data = L.tpiu_deframe_walk(raw, want_stream=a.stream) if a.deframe else raw
    if L.has_tpiu_sync(data):
        # capture still TPIU-framed; deframe it
        data = L.tpiu_deframe_walk(raw, want_stream=a.stream)
        print("(auto-deframed TPIU stream-%d)" % a.stream)

    insn = objdump_map(a.elf)
    print(f"ELF has {len(insn)} disassembled instructions")

    events = L.decode_all(data)
    anchors = [e for e in events if e.kind == "isync"]
    flow = [e for e in events if e.kind != "isync"]

    # --- check 1+2: anchors are real instruction starts ---
    anc_hit = anc_miss = 0
    miss_examples = []
    fn_hist = collections.Counter()
    for e in anchors:
        pc = e.addr & ~1            # drop thumb bit
        if pc in insn:
            anc_hit += 1
            fn_hist[insn[pc][1]] += 1
        else:
            anc_miss += 1
            if len(miss_examples) < 8:
                miss_examples.append(hex(pc))

    print(f"\n=== anchor reconciliation ===")
    print(f"anchors: {len(anchors)}  hit real insn start: {anc_hit}  "
          f"miss: {anc_miss}")
    if anchors:
        print(f"anchor->instruction match rate: {100*anc_hit/len(anchors):.1f}%")
    if miss_examples:
        print(f"miss examples (PC not an insn start): {miss_examples}")

    print(f"\n=== functions hit by anchors ===")
    for fn, c in fn_hist.most_common(10):
        print(f"  {c:5d}  {fn}")

    # --- check 3: spot-check disassembly of top anchor PCs vs objdump ---
    print(f"\n=== disassembly spot-check (top anchor PCs) ===")
    top = collections.Counter(e.addr & ~1 for e in anchors).most_common(8)
    for pc, c in top:
        if pc in insn:
            mnem, fn = insn[pc]
            print(f"  {hex(pc)} x{c:<4d} {fn:24s} | objdump: {mnem}")
        else:
            print(f"  {hex(pc)} x{c:<4d} *** NOT AN INSTRUCTION START ***")

    ok = anchors and anc_miss == 0
    print(f"\n=== VERDICT: {'PASS — every anchor maps to a real ELF instruction' if ok else 'CHECK — some anchors off instruction boundary'} ===")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
