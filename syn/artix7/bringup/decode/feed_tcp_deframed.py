#!/usr/bin/env python3
"""feed_tcp_deframed — TCP server that streams a raw SWO/TPIU file to orbuculum
AFTER deframing it to pure ETM stream-2 bytes via etm35lib's adaptive-relock
TPIU deframer.

Rationale: orbuculum's built-in TPIU decoder can't lock our sparse-sync,
capture-stitched SWO stream (frame boundary drifts -> "No handler for tag N").
Our etm35lib tpiu_deframe_walk already solves that robustly. So we deframe on
the PC side and feed orbuculum the pure ETM3.5 stream, letting it focus on ETM
decode + distribution to orbtop/orbmortem.

Usage: feed_tcp_deframed.py [raw.bin] [port] [loops] [want_stream]
"""
import socket
import sys
import time

sys.path.insert(0, "decode")
sys.path.insert(0, ".")
import etm35lib as L

path = sys.argv[1] if len(sys.argv) > 1 else "/tmp/raw.bin"
port = int(sys.argv[2]) if len(sys.argv) > 2 else 5555
loops = int(sys.argv[3]) if len(sys.argv) > 3 else 200
want = int(sys.argv[4]) if len(sys.argv) > 4 else 2

raw = open(path, "rb").read()
etm = L.tpiu_deframe_walk(raw, want_stream=want)
print(f"deframed {len(raw)} -> {len(etm)} ETM stream-{want} bytes", flush=True)

s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", port))
s.listen(1)
print(f"listening :{port}, waiting for client...", flush=True)
c, a = s.accept()
print(f"client {a} connected, streaming deframed ETM (x{loops})...", flush=True)
try:
    for _ in range(loops):
        c.sendall(etm)
        time.sleep(0.05)
except (BrokenPipeError, ConnectionResetError):
    print("client disconnected")
c.close()
s.close()
print("done")
