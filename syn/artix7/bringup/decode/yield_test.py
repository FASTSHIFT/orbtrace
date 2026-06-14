"""yield_test — repeatedly soft-rearm + gen-confirmed dump + measure, printing
each capture's unknown% and a good/bad summary. Quantifies the intermittent
corruption rate at the current frequency/EYE without averaging it away."""
import os
import sys
import subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
SCR = os.path.join(os.path.dirname(HERE), "scripts")
sys.path.insert(0, HERE)
import etm35lib as L
import dsl_parse as D

IP = sys.argv[1] if len(sys.argv) > 1 else "192.168.10.42"
N = int(sys.argv[2]) if len(sys.argv) > 2 else 30
SKIP = int(sys.argv[3]) if len(sys.argv) > 3 else 0
DEPTH = 61440


def status_gen():
    r = subprocess.run(["python3", os.path.join(SCR, "trace_dump.py"),
                        "--ip", IP, "--depth", str(DEPTH), "--status-only"],
                       capture_output=True, text=True)
    for t in r.stdout.split():
        if t.startswith("gen="):
            return int(t.split("=")[1])
    return 0


def rearm():
    subprocess.run(["python3", os.path.join(SCR, "trace_ctrl.py"),
                    "--ip", IP, "rearm"], capture_output=True, text=True)


def dump(out, pg):
    subprocess.run(["python3", os.path.join(SCR, "trace_dump.py"),
                    "--ip", IP, "--depth", str(DEPTH), "-o", out,
                    "--prev-gen", str(pg), "--skip", str(SKIP)],
                   capture_output=True, text=True)


def measure(path):
    raw = open(path, "rb").read()
    nibs = bytearray()
    for b in raw:
        nibs.append((b >> 4) & 0xF)
        nibs.append(b & 0xF)
    best = None
    for parity in (0, 1):
        for order in (0, 1):
            data = D.assemble(nibs, parity, order)
            fl = sum(1 for s in L.find_isyncs(data) if L.is_flash(s.addr))
            if best is None or fl > best[0]:
                best = (fl, data)
    data = best[1]
    if L.has_tpiu_sync(data):
        data = L.tpiu_deframe_local(data)   # per-window local phase (doc 15 §17)
    unk = sum(1 for c in data if L._classify(c) == "unknown")
    return 100 * unk / max(1, len(data))


vals = []
good = 0
for i in range(N):
    pg = status_gen()
    rearm()
    out = f"/tmp/yt{i}.bin"
    dump(out, pg)
    try:
        u = measure(out)
    except Exception:
        u = float("nan")
    vals.append(u)
    if u < 0.1:
        good += 1
    print(f"  cap{i:2d}: {u:7.3f}%")

print(f"\n{N} captures: GOOD(<0.1%)={good} ({100*good/N:.0f}%)  "
      f"BAD={N-good} ({100*(N-good)/N:.0f}%)")
print(f"median={sorted(vals)[len(vals)//2]:.3f}%  max={max(vals):.3f}%")
