#!/usr/bin/env python3
"""sim_la_equiv — prove the RTL-sim recovered byte stream is BYTE-IDENTICAL to
the logic-analyser software path over the same .dsl sample window.

This is the strict gate for "100% correct in simulation": not just equal
anchor counts / unknown%, but the deframed ETM byte streams must match
byte-for-byte.

  RTL path: tb_dsl_replay dumped {trace_b,trace_a} bytes (hex) ->
            expand to time-order nibbles -> re-pair (parity/order search) ->
            TPIU deframe
  LA path:  dsl_parse sample_nibbles -> re-pair -> TPIU deframe

Usage:
  python3 sim_la_equiv.py <sim_raw.hex> <capture.dsl> <nsamples>
exit 0 if byte-identical, 1 otherwise.
"""
import sys
import etm35lib as L
import dsl_parse as D


def _align_and_deframe(nibs):
    """Re-pair a time-ordered nibble stream (parity/order search by flash
    anchors) and TPIU-deframe — the shared back half of both paths."""
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
        data = L.tpiu_deframe_hsync(data, ph)
    return data


def rtl_nibbles(hexfile):
    """Time-ordered nibbles from the RTL {trace_b,trace_a} byte dump."""
    raw = bytes(int(x, 16) for x in open(hexfile).read().split())
    nibs = bytearray()
    for b in raw:
        nibs.append((b >> 4) & 0xF)   # trace_b (falling) first in time
        nibs.append(b & 0xF)          # trace_a (rising)
    return nibs


def la_nibbles(dsl_path, nsamp):
    chans, sr, n = D.load_channels(dsl_path)
    clk = D.unpack_bits(chans[0], nsamp)
    d = [D.unpack_bits(chans[ch], nsamp) for ch in range(1, 5)]
    edges, half = D.find_edges(clk, nsamp)
    eye = max(1, int(half * D.DEFAULT_EYE_FRACTION))
    return D.sample_nibbles(d, edges, eye)


def rtl_decode(hexfile):
    return _align_and_deframe(rtl_nibbles(hexfile))


def la_decode(dsl_path, nsamp):
    return _align_and_deframe(la_nibbles(dsl_path, nsamp))


def compare(rtl, la):
    m = min(len(rtl), len(la))
    mism = sum(1 for i in range(m) if rtl[i] != la[i])
    same_len = len(rtl) == len(la)
    return mism, same_len, m


def main():
    sim_hex = sys.argv[1]
    dsl = sys.argv[2]
    nsamp = int(sys.argv[3])
    rtl = rtl_decode(sim_hex)
    la = la_decode(dsl, nsamp)
    mism, same_len, m = compare(rtl, la)
    print(f"RTL bytes={len(rtl)}  LA bytes={len(la)}  compared={m}  "
          f"mismatches={mism}")
    ok = (mism == 0 and same_len)
    print("==> " + ("BYTE-IDENTICAL (100%)" if ok
                    else "DIFFER"))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
