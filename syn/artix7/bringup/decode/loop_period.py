#!/usr/bin/env python3
"""loop_period — find the repeating loop structure in a deframed ETM capture.

func_test runs a deterministic main_loop with no data-dependent control flow,
so the ETM instruction-flow stream is periodic. We locate that period from the
I-sync anchor PCs: the main_loop body re-enters at the same PC every iteration,
so the gap (in ETM-byte offset) between successive occurrences of that PC is the
loop period. This is the prerequisite for cross-iteration majority voting
(period_vote.py): without an LA we use the program's own determinism as the
ground truth.

Usage: loop_period.py <fpga_raw.bin>
"""
import sys, collections
import etm35lib as L
import dsl_parse as D


def deframe_raw(raw):
    nibs = bytearray()
    for byte in raw:
        nibs.append((byte >> 4) & 0xF)
        nibs.append(byte & 0xF)
    best = None
    for parity in (0, 1):
        for order in (0, 1):
            data = D.assemble(nibs, parity, order)
            fl = sum(1 for s in L.find_isyncs(data) if L.is_flash(s.addr))
            if best is None or fl > best[0]:
                best = (fl, data)
    data = best[1]
    if L.has_tpiu_sync(data):
        ph, _ = L.find_tpiu_phase(data)
        data = L.tpiu_deframe_walk(data)
    return data


def main():
    raw = open(sys.argv[1], "rb").read()
    etm = deframe_raw(raw)
    syncs = L.find_isyncs(etm)
    flash = [s for s in syncs if L.is_flash(s.addr)]
    print(f"deframed={len(etm)}B  isyncs={len(syncs)} flash={len(flash)}")

    # PC frequency among anchors
    pc_count = collections.Counter(s.addr for s in flash)
    print("\ntop anchor PCs (addr : count):")
    for a, c in pc_count.most_common(12):
        print(f"  0x{a:08x} : {c}")

    # for the most common PC, look at offset gaps between consecutive anchors
    if pc_count:
        common_pc = pc_count.most_common(1)[0][0]
        offs = [s.offset for s in flash if s.addr == common_pc]
        gaps = [offs[i+1]-offs[i] for i in range(len(offs)-1)]
        gh = collections.Counter(gaps)
        print(f"\nmost-common PC 0x{common_pc:08x}: {len(offs)} occurrences")
        print("offset-gap histogram (gap_bytes : count):")
        for g, c in sorted(gh.items(), key=lambda x:-x[1])[:15]:
            print(f"  {g:7d} : {c}")


if __name__ == "__main__":
    main()
