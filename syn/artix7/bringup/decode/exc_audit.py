#!/usr/bin/env python3
"""exc_audit — per-PID breakdown of an orbetto .perf: how many B/E events, and
which function names show up in each exception track. Lets us confirm that the
bogus exception PIDs (id != 15) are stuffed with mainline functions = decode
noise, while the real SysTick (id 15) holds only the ISR.
"""
import sys, collections, subprocess

path = sys.argv[1]
data = open(path, "rb").read()

def rv(b, i):
    s = r = 0
    while True:
        x = b[i]; i += 1; r |= (x & 0x7f) << s
        if not x & 0x80: break
        s += 7
    return r, i

def parse(b):
    o = []; i = 0; n = len(b)
    while i < n:
        try: key, i = rv(b, i)
        except: break
        fn = key >> 3; wt = key & 7
        if wt == 0: v, i = rv(b, i); o.append((fn, wt, v))
        elif wt == 2:
            ln, i = rv(b, i); o.append((fn, wt, b[i:i+ln])); i += ln
        elif wt == 5: o.append((fn, wt, b[i:i+4])); i += 4
        elif wt == 1: o.append((fn, wt, b[i:i+8])); i += 8
        else: break
    return o

events = []
for fn, wt, v in parse(data):
    if fn != 1 or wt != 2: continue
    for pfn, pwt, pv in parse(v):
        if pfn == 1 and pwt == 2:
            for bfn, bwt, bv in parse(pv):
                if bfn == 2 and bwt == 2:
                    ev = parse(bv)
                    ts = pid = None; buf = None
                    for efn, ewt, evv in ev:
                        if efn == 1 and ewt == 0: ts = evv
                        elif ewt == 0 and pid is None and efn in (2,3,4): pid = evv
                        elif ewt == 2 and isinstance(evv,(bytes,bytearray)):
                            for sfn, swt, sv in parse(evv):
                                if swt == 2 and isinstance(sv,(bytes,bytearray)):
                                    s = bytes(sv)
                                    if s[:2] in (b"B|", b"E|", b"I|"): buf = s
                    if buf is not None and ts is not None:
                        events.append((ts, pid, buf.decode("latin1","replace")))

per_pid = collections.Counter()
per_pid_funcs = collections.defaultdict(collections.Counter)
for ts, pid, buf in events:
    per_pid[pid]+=1
    if buf.startswith("B|"):
        parts = buf.split("|",2)
        if len(parts)==3: per_pid_funcs[pid][parts[2]]+=1

def demangle(names):
    names=[n for n in names if n]
    if not names: return {}
    try:
        out = subprocess.run(["arm-none-eabi-c++filt"], input="\n".join(names),
                             capture_output=True, text=True).stdout.splitlines()
        return dict(zip(names,out))
    except Exception: return {}
allnames=set()
for c in per_pid_funcs.values(): allnames|=set(c)
dm=demangle(allnames)

print(f"total events: {len(events)}   distinct PIDs: {len(per_pid)}")
print(f"{'PID':>8} {'kind':>22} {'events':>8}")
for pid,cnt in sorted(per_pid.items(), key=lambda x:-x[1]):
    if pid is None: kind="?"
    elif pid==400000: kind="MAIN callstack"
    elif pid==401000: kind="BOOTLOADER"
    elif 500000<=pid<600000: kind=f"EXC id={pid-500000}"
    elif pid>=600000: kind="PC"
    else: kind=f"callstack+{pid-400000}"
    print(f"{pid!s:>8} {kind:>22} {cnt:>8}")
    top=per_pid_funcs[pid].most_common(6)
    if top:
        s="  ".join(f"{dm.get(n,n)}×{c}" for n,c in top)
        print(f"          funcs: {s}")
