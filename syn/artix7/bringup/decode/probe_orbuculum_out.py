#!/usr/bin/env python3
"""probe_orbuculum_out — connect to orbuculum's legacy per-stream TCP port and
verify the bytes it forwards (TPIU-stripped, tag 2 = ETM) decode to genuine
proj_add PCs via etm35lib. Ground-test for r19: proves orbuculum's network
source + TPIU strip path accepts our UART-decoded TPIU bytes.
"""
import socket
import sys
import time
import collections

sys.path.insert(0, "decode")
sys.path.insert(0, ".")
import etm35lib as L

port = int(sys.argv[1]) if len(sys.argv) > 1 else 3443
s = socket.socket()
s.settimeout(5)
s.connect(("127.0.0.1", port))
buf = bytearray()
t0 = time.time()
try:
    while time.time() - t0 < 4 and len(buf) < 300000:
        d = s.recv(65536)
        if not d:
            break
        buf += d
except socket.timeout:
    pass
s.close()
print(f"received {len(buf)} bytes from orbuculum :{port}")
fl = [x for x in L.find_isyncs(bytes(buf)) if L.is_flash(x.addr)]
h = collections.Counter(x.addr for x in fl)
print(f"etm35lib flash anchors from orbuculum output: {len(fl)}")
print("PCs:", [(hex(a), c) for a, c in h.most_common(8)])
