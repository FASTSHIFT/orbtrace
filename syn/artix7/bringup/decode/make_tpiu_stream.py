"""make_tpiu_stream — emit the RAW (pre-deframe) TPIU formatter byte stream
from a .dsl or an FPGA raw capture, for feeding orbetto (which runs its own
TPIU deformatter via -t and routes stream-id 2 -> ETM/Mortrall -> Perfetto).

We only do nibble assembly (best parity/order by flash-anchor count) and emit
the assembled TPIU bytes; orbetto does the 16-byte deframe itself.

Usage:
  python3 make_tpiu_stream.py <capture.dsl|raw.bin> <out.tpiu>
"""
import sys
import etm35lib as L
import dsl_parse as D


def from_dsl(path):
    chans, sr, n = D.load_channels(path)
    nsamp = min(min(len(v) for v in chans.values()) * 8, 50_000_000)
    clk = D.unpack_bits(chans[0], nsamp)
    d = [D.unpack_bits(chans[ch], nsamp) for ch in range(1, 5)]
    edges, half = D.find_edges(clk, nsamp)
    eye = max(1, int(half * D.DEFAULT_EYE_FRACTION))
    return D.sample_nibbles(d, edges, eye)


def from_raw(path):
    raw = open(path, "rb").read()
    nibs = bytearray()
    for b in raw:
        nibs.append((b >> 4) & 0xF)
        nibs.append(b & 0xF)
    return nibs


def main():
    src, out = sys.argv[1], sys.argv[2]
    nibs = from_dsl(src) if src.endswith(".dsl") else from_raw(src)
    best = None
    for parity in (0, 1):
        for order in (0, 1):
            data = D.assemble(nibs, parity, order)
            fl = sum(1 for s in L.find_isyncs(data) if L.is_flash(s.addr))
            if best is None or fl > best[0]:
                best = (fl, parity, order, data)
    fl, p, o, data = best
    with open(out, "wb") as f:
        f.write(data)
    sync = data.count(b"\xff\xff\xff\x7f")
    hs = sum(1 for i in range(len(data) - 1)
             if data[i] == 0xFF and data[i + 1] == 0x7F)
    print(f"assembled parity={p} order={o} flash_anchors={fl}")
    print(f"wrote {out}: {len(data)} TPIU bytes (FSYNC={sync} HSYNC={hs})")


if __name__ == "__main__":
    main()
