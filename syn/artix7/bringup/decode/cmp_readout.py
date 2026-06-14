"""Compare plain vs drop-first-byte readout on the SAME live buffer, to check
whether the RTL ext_pos fix actually removed the per-page duplicate for REAL
trace data (it tested clean on the SELFTEST ramp)."""
import socket
import struct
import sys
import etm35lib as L
import dsl_parse as D

IP = sys.argv[1] if len(sys.argv) > 1 else "192.168.10.42"
PORT = 5001
DEPTH = 61440
CHUNK = 1000

s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
s.settimeout(2.0)


def req(base, n):
    s.sendto(struct.pack("<H", base) + bytes(n), (IP, PORT))
    d, _ = s.recvfrom(2048)
    return d[2:2 + n]


def measure(raw):
    nibs = bytearray()
    for b in raw:
        nibs.append((b >> 4) & 0xF)
        nibs.append(b & 0xF)
    best = None
    for p in (0, 1):
        for o in (0, 1):
            data = D.assemble(nibs, p, o)
            fl = sum(1 for x in L.find_isyncs(data) if L.is_flash(x.addr))
            if best is None or fl > best[0]:
                best = (fl, data)
    data = best[1]
    if L.has_tpiu_sync(data):
        ph, _ = L.find_tpiu_phase(data)
        data = L.tpiu_deframe_hsync(data, ph)
    unk = sum(1 for c in data if L._classify(c) == "unknown")
    return 100 * unk / max(1, len(data))


def read_plain():
    out = bytearray()
    base = 0
    while base < DEPTH:
        n = min(CHUNK, DEPTH - base)
        out.extend(req(base, n))
        base += n
    return bytes(out)


def read_drop():
    out = bytearray()
    base = 0
    while base < DEPTH:
        n = min(CHUNK, DEPTH - base)
        r = req(base, n + 1)
        out.extend(r[1:1 + n])
        base += n
    return bytes(out)


plain = read_plain()
drop = read_drop()
print("plain read  unknown%%: %.3f" % measure(plain))
print("n+1-drop    unknown%%: %.3f" % measure(drop))
# show a page seam
print("plain @[998:1006]:", plain[998:1006].hex())
print("drop  @[998:1006]:", drop[998:1006].hex())
