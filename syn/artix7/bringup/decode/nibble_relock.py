"""Prototype: nibble-level re-lock. The bad captures' dirty windows are an
ODD nibble insert/delete that flips the rising/falling pairing parity mid-
stream (doc 15 §16): most of the stream decodes clean at one (parity,order),
but ~1KB windows want the OPPOSITE parity -> a single odd nibble slipped.

Strategy: walk the time-ordered nibble stream in blocks; for each block pick
the (parity,order) that decodes cleanest; when the winning parity flips vs the
previous block, a nibble slipped at the boundary -> drop/insert one nibble to
re-align so the WHOLE stream can be assembled+deframed at one consistent
parity. Emit the re-aligned nibble stream, then assemble+deframe once.
"""
import sys
import dsl_parse as D
import etm35lib as L


def time_nibbles(raw):
    nb = bytearray()
    for b in raw:
        nb.append((b >> 4) & 0xF)   # falling (b) first in time
        nb.append(b & 0xF)          # rising (a)
    return nb


def block_quality(nibs, parity, order):
    """unknown-fraction of deframing this nibble block at given parity/order."""
    data = D.assemble(nibs, parity, order)
    if not L.has_tpiu_sync(data):
        # no frames -> score by raw classifiable fraction
        unk = sum(1 for c in data if L._classify(c) == "unknown")
        return unk / max(1, len(data))
    ph, _ = L.find_tpiu_phase(data)
    pl = L.tpiu_deframe_hsync(data, ph)
    unk = sum(1 for c in pl if L._classify(c) == "unknown")
    return unk / max(1, len(pl))


def relock_nibbles(nibs, blk=2000):
    """Re-align odd nibble slips: scan in blocks, keep a running 'shift'
    (0 or 1 nibble) chosen so each block decodes cleanest, splicing a
    drop/insert at slip points. Returns the re-aligned nibble stream."""
    out = bytearray()
    # baseline parity/order from the whole stream
    base = None
    for p in (0, 1):
        for o in (0, 1):
            q = block_quality(nibs, p, o)
            if base is None or q < base[0]:
                base = (q, p, o)
    _, P, O = base
    i = 0
    shift = 0
    n = len(nibs)
    while i < n:
        seg = nibs[i:i + blk]
        if len(seg) < 64:
            out += seg
            break
        # is this block clean at the established parity (with current shift)?
        q_keep = block_quality(seg, P, O)
        if q_keep < 0.02:
            out += seg
            i += blk
            continue
        # block is dirty: try dropping 1 nibble or inserting 1 nibble at the
        # block start to re-align parity, pick whichever cleans the block.
        q_drop = block_quality(nibs[i + 1:i + 1 + blk], P, O)
        q_ins = block_quality(bytes([0]) + seg, P, O)
        cand = [(q_keep, 0), (q_drop, 1), (q_ins, -1)]
        cand.sort()
        _, action = cand[0]
        if action == 1:        # drop one nibble (skip it)
            i += 1
            continue
        elif action == -1:     # insert a filler nibble
            out.append(0)
            continue
        else:
            out += seg
            i += blk
    return out


def main():
    raw = open(sys.argv[1], "rb").read()
    nibs = time_nibbles(raw)
    # baseline: best single (parity,order) global
    best = None
    for p in (0, 1):
        for o in (0, 1):
            q = block_quality(nibs, p, o)
            if best is None or q < best[0]:
                best = (q, p, o)
    print(f"GLOBAL best (p={best[1]},o={best[2]}): unk={100*best[0]:.2f}%")
    re = relock_nibbles(nibs)
    rq = min(block_quality(re, p, o) for p in (0, 1) for o in (0, 1))
    # full decode of relocked
    bb = None
    for p in (0, 1):
        for o in (0, 1):
            data = D.assemble(re, p, o)
            if L.has_tpiu_sync(data):
                ph, _ = L.find_tpiu_phase(data)
                pl = L.tpiu_deframe_hsync(data, ph)
                u = sum(1 for c in pl if L._classify(c) == "unknown") / max(1, len(pl))
                fl = sum(1 for s in L.find_isyncs(pl) if L.is_flash(s.addr))
                if bb is None or u < bb[0]:
                    bb = (u, fl, len(pl))
    print(f"RELOCK: unk={100*bb[0]:.2f}% flash={bb[1]} bytes={bb[2]}")


if __name__ == "__main__":
    main()
