#!/usr/bin/env python3
"""Profile a captured LVGL trace stream at the I-sync ANCHOR level (the
ground-truth metric): decode -> for every flash I-sync anchor resolve to a
function via addr2line -> write
  - lvgl_anchors.txt : ordered anchor list (PC + func + file:line)
  - lvgl_funcprof.txt: function frequency profile (how many anchors per func)
Anchors are the reliable signal (continuous per-instruction reconstruction
derails on LVGL's indirect calls; see doc 14 §10/§11). This gives a function
hot-spot view that IS trustworthy.
"""
import os, sys, subprocess, collections
import etm35lib as L
import dsl_parse as D

raw = open(sys.argv[1], "rb").read()
ELF = os.environ.get("ELF", "/home/vifex/workpath/orbcode/proj.axf")
OUT = sys.argv[2] if len(sys.argv) > 2 else "/tmp/lvgl"

# recover nibbles, pick parity, deframe (same as mmcm_decode)
nibs = bytearray()
for k in range(len(raw) - 1):
    nibs.append((raw[k] >> 4) & 0xF)
    nibs.append(raw[k + 1] & 0xF)
best = None
for parity in (0, 1):
    for order in (0, 1):
        data = D.assemble(nibs, parity, order)
        fl = sum(1 for s in L.find_isyncs(data) if L.is_flash(s.addr))
        if best is None or fl > best[0]:
            best = (fl, parity, order, data)
_, parity, order, data = best
etm = L.tpiu_deframe_walk(data) if L.has_tpiu_sync(data) else data

# ordered anchors
syncs = [s for s in L.find_isyncs(etm) if L.is_flash(s.addr)]
addrs = [s.addr for s in syncs]
distinct = sorted(set(addrs))

# resolve all distinct PCs once
p = subprocess.run(["arm-none-eabi-addr2line", "-f", "-e", ELF]
                   + [f"0x{a:08x}" for a in distinct],
                   capture_output=True, text=True)
lines = p.stdout.splitlines()
fn_of = {}
loc_of = {}
for i, a in enumerate(distinct):
    fn_of[a] = lines[2*i] if 2*i < len(lines) else "?"
    loc_of[a] = lines[2*i+1] if 2*i+1 < len(lines) else "?"

# ordered anchor list
with open(OUT + "_anchors.txt", "w") as f:
    f.write(f"# {len(syncs)} flash anchors, {len(distinct)} distinct PC "
            f"(parity={parity})\n")
    for a in addrs:
        f.write(f"0x{a:08x}  {fn_of[a]}\t{loc_of[a]}\n")

# function frequency profile (anchors per function)
byfn = collections.Counter(fn_of[a] for a in addrs)
with open(OUT + "_funcprof.txt", "w") as f:
    f.write(f"# anchor-frequency profile  ({len(syncs)} anchors total)\n")
    f.write(f"# count  pct   function\n")
    for fn, n in byfn.most_common():
        f.write(f"{n:6d}  {100*n/len(syncs):5.1f}%  {fn}\n")

print(f"anchors={len(syncs)} distinct={len(distinct)} functions={len(byfn)}")
print(f"wrote {OUT}_anchors.txt and {OUT}_funcprof.txt")
