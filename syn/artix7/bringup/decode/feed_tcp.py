#!/usr/bin/env python3
"""feed_tcp — minimal TCP server that streams a raw SWO/TPIU byte file to the
first client, looping the file for a continuous flow. Used to ground-test
`orbuculum -s <host>:<port>` against a KNOWN-GOOD byte stream (r19 step 1):
verify orbuculum's network source accepts our UART-decoded TPIU bytes before
building any FPGA streaming.

Usage: feed_tcp.py [raw.bin] [port] [loops]
"""
import socket
import sys
import time

path = sys.argv[1] if len(sys.argv) > 1 else "/tmp/raw.bin"
port = int(sys.argv[2]) if len(sys.argv) > 2 else 5555
loops = int(sys.argv[3]) if len(sys.argv) > 3 else 50

data = open(path, "rb").read()
s = socket.socket()
s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
s.bind(("127.0.0.1", port))
s.listen(1)
print(f"listening :{port}, {len(data)} B, waiting for client...", flush=True)
c, a = s.accept()
print(f"client {a} connected, streaming (looped x{loops})...", flush=True)
try:
    for _ in range(loops):
        c.sendall(data)
        time.sleep(0.05)
except (BrokenPipeError, ConnectionResetError):
    print("client disconnected")
c.close()
s.close()
print("done")
