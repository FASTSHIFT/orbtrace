#!/usr/bin/env python3
"""Reconstruct the half-bit (nibble) stream from MMCM capture and search the
re-pairing offset + nibble bit order for a decodable ETM stream.

cap_byte = {trace_b(2nd half-bit nibble), trace_a(1st half-bit nibble)}. If the
IDDR edge pairing straddles a TRACECLK period (SAME_EDGE_PIPELINED can pair
rising-of-N with falling-of-N-1), the byte boundary is off by one half-bit.
Rebuild the nibble sequence, then re-pair at offsets 0/1 with both nibble
orders, both lane bit orders, and check ETM I-sync anchors in tight .text.
"""
import os, sys, subprocess, re
import etm35lib as L

raw = open(sys.argv[1], "rb").read()
ELF = os.environ.get("ELF", "/home/vifex/workpath/orbcode/proj_add.axf")
READELF = "arm-none-eabi-readelf"

def text_range(elf):
    p = subprocess.run([READELF, "-S", "-W", elf], capture_output=True, text=True)
    lo = hi = None
    for line in p.stdout.splitlines():
        m = re.search(r"\]\s+\S+\s+\w+\s+([0-9a-fA-F]{8,16})\s+[0-9a-fA-F]+\s+"
                      r"([0-9a-fA-F]+)\s+\S+\s+([A-Zp]*)", line)
        if not m: continue
        addr=int(m.group(1),16); size=int(m.group(2),16); flg=m.group(3)
        if "X" in flg and addr>=L.FLASH_LO:
            lo=addr if lo is None else min(lo,addr)
            hi=addr+size if hi is None else max(hi,addr+size)
    return (lo or L.FLASH_LO, hi or L.FLASH_HI)

LO, HI = text_range(ELF)

def bitrev4(n):
    return ((n&1)<<3)|((n&2)<<1)|((n&4)>>1)|((n&8)>>3)
BR4=[bitrev4(i) for i in range(16)]

# nibble stream: byte b -> [a=lo nibble, b=hi nibble] in time order (a first)
nibs=[]
for byte in raw:
    nibs.append(byte & 0xF)        # trace_a = first half-bit
    nibs.append((byte>>4)&0xF)     # trace_b = second half-bit

def build(nibs, offset, rev_nib, hi_first):
    out=bytearray()
    i=offset
    while i+1 < len(nibs):
        n0=nibs[i]; n1=nibs[i+1]
        if rev_nib: n0,n1=BR4[n0],BR4[n1]
        out.append((n1<<4)|n0 if hi_first else (n0<<4)|n1)
        i+=2
    return bytes(out)

def score(data):
    try:
        ev=L.decode_all(data)
        anchors=sorted({e.addr for e in ev if e.kind=="isync" and LO<=e.addr<HI})
    except Exception:
        return -1, []
    return len(anchors), anchors

results=[]
for off in (0,1):
    for rn in (0,1):
        for hf in (0,1):
            d=build(nibs,off,rn,hf)
            n,anchors=score(d)
            results.append((n,off,rn,hf,anchors,d))
            print(f"offset={off} rev_nib={rn} hi_first={hf}: anchors_in_text={n} {[hex(a) for a in anchors[:6]]}")

results.sort(key=lambda r:r[0], reverse=True)
n,off,rn,hf,anchors,d=results[0]
print(f"\nBEST offset={off} rev_nib={rn} hi_first={hf} anchors={n}")
if n>0:
    open("/tmp/mmcm_best.bin","wb").write(d)
    print("wrote /tmp/mmcm_best.bin")
