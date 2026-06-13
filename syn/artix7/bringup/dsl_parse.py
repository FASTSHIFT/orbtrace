#!/usr/bin/env python3
"""Parse a DSView .dsl logic capture of the STM32 4-bit ETM trace and recover
the byte stream, for ground-truth cross-check against the FPGA/decoder.

.dsl layout (zip): header (ini), per-channel bit-packed sample blocks named
L-<ch>/<blk>; each byte holds 8 consecutive samples, LSB = earliest sample.
Channels here: 0=TRACECLK 1=TRACED0 2=TRACED1 3=TRACED2 4=TRACED3.

We sample the 4 data lines on BOTH TRACECLK edges (DDR) and assemble nibbles
into bytes, trying both edge-orderings, then look for ETM structure.
"""
import sys
import zipfile
import io
import configparser


def load_channels(path):
    z = zipfile.ZipFile(path)
    names = z.namelist()
    hdr = z.read("header").decode("utf-8", "replace")
    cp = configparser.ConfigParser()
    cp.read_string(hdr)
    nprobes = int(cp["header"]["total probes"])
    srate = cp["header"]["samplerate"]
    # gather per-channel blocks in order
    chans = {}
    for ch in range(nprobes):
        blocks = sorted([n for n in names if n.startswith(f"L-{ch}/")],
                        key=lambda s: int(s.split("/")[1]))
        raw = b"".join(z.read(b) for b in blocks)
        chans[ch] = raw
    return chans, srate, nprobes


def unpack_bits(raw, nsamples):
    """Return a bytes-like array of 0/1 per sample (LSB-first within each byte)."""
    out = bytearray(nsamples)
    for i in range(nsamples):
        out[i] = (raw[i >> 3] >> (i & 7)) & 1
    return out


def main():
    path = sys.argv[1]
    chans, srate, nprobes = load_channels(path)
    # number of samples = min over channels of bits available
    nsamp = min(len(v) for v in chans.values()) * 8
    # cap for speed during exploration
    cap = int(sys.argv[2]) if len(sys.argv) > 2 else 2_000_000
    nsamp = min(nsamp, cap)
    print(f"samplerate={srate} probes={nprobes} samples(used)={nsamp}")

    clk = unpack_bits(chans[0], nsamp)
    d = [unpack_bits(chans[ch], nsamp) for ch in range(1, 5)]

    # find clock edges
    rising, falling = [], []
    for i in range(1, nsamp):
        if clk[i] and not clk[i - 1]:
            rising.append(i)
        elif not clk[i] and clk[i - 1]:
            falling.append(i)
    print(f"TRACECLK rising edges={len(rising)} falling={len(falling)}")
    if len(rising) > 2:
        period = (rising[-1] - rising[0]) / (len(rising) - 1)
        print(f"  mean TRACECLK period = {period:.1f} samples "
              f"= {period*20:.0f} ns  -> ~{50e6/period/1e3:.0f} kHz")

    def nib(edge_idx):
        return (d[0][edge_idx] | (d[1][edge_idx] << 1)
                | (d[2][edge_idx] << 2) | (d[3][edge_idx] << 3))

    # sample data at each edge; DDR: one nibble per edge. Interleave rise/fall
    # in time order.
    edges = sorted(rising + falling)
    nibs = bytes(nib(e) for e in edges)
    print(f"total DDR nibbles sampled = {len(nibs)}")
    # show first 32 nibbles
    print("first 40 nibbles:", " ".join(f"{n:x}" for n in nibs[:40]))

    # assemble bytes two ways: (rise=low nibble) vs (rise=high nibble)
    import collections
    for order, lbl in ((0, "rise=low,fall=high"), (1, "rise=high,fall=low")):
        b = bytearray()
        for k in range(0, len(nibs) - 1, 2):
            n0, n1 = nibs[k], nibs[k + 1]
            if order == 0:
                b.append((n1 << 4) | n0)
            else:
                b.append((n0 << 4) | n1)
        bb = bytes(b)
        c = collections.Counter(bb)
        asy = bb.count(bytes.fromhex("000000000080"))
        print(f"\n[{lbl}] bytes={len(bb)} A-sync={asy} "
              f"top={[(hex(x),n) for x,n in c.most_common(6)]}")
        with open(f"/tmp/dsl_bytes_{order}.bin", "wb") as f:
            f.write(bb)
    print("\nwrote /tmp/dsl_bytes_0.bin (rise=low) and /tmp/dsl_bytes_1.bin (rise=high)")


if __name__ == "__main__":
    main()
