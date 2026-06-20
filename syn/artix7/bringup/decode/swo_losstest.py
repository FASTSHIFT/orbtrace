#!/usr/bin/env python3
"""swo_losstest — quantify packet-loss damage on the live orbuculum path (r19 Q3).

r19 Q3: in a live UDP stream a dropped 1 KB packet is gone (not re-readable like
the idempotent paged readout), and at high baud TPIU sync is sparse, so a drop
could de-sync orbuculum for a long stretch. The offline re-lock walk's
robustness must NOT be assumed for the lossy live stream.

Method (zero FPGA): take a known-good TPIU byte stream, DELETE 1 KB chunks at a
given loss rate (simulating dropped UDP packets), feed it through orbuculum
(-s -T -N -t 2) over TCP, read the TPIU-stripped tag-2 output from :3443, and
measure flash anchors recovered vs the loss-free baseline. Run several loss
rates to see how gracefully (or not) orbuculum degrades.

Usage: swo_losstest.py [raw.bin]
"""
import os
import random
import socket
import subprocess
import sys
import time
import collections

sys.path.insert(0, "decode")
sys.path.insert(0, ".")
import etm35lib as L

RAW = sys.argv[1] if len(sys.argv) > 1 else "/tmp/raw.bin"
ORB = os.path.abspath("../../../../orbuculum/build/orbuculum")
CHUNK = 1024


def hole(data, loss_rate, chunk=CHUNK):
    """Delete `chunk`-byte blocks at `loss_rate` probability (simulate dropped
    UDP packets — the bytes are GONE, stream just concatenates around them)."""
    out = bytearray()
    i = 0
    n = len(data)
    rng = random.Random(1234)
    while i < n:
        if rng.random() < loss_rate:
            i += chunk           # drop this chunk
        else:
            out += data[i:i + chunk]
            i += chunk
    return bytes(out)


def run_once(stream_bytes, port=5560):
    """Feed stream_bytes (looped a few times) to orbuculum -s over TCP, read its
    :port+? legacy tag-2 output, return flash anchors via etm35lib."""
    legacy_port = 3443
    # 1) start orbuculum
    orb = subprocess.Popen([ORB, "-s", f"localhost:{port}", "-T", "-N", "-t", "2"],
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    time.sleep(0.4)
    # 2) start a TCP feeder server that orbuculum connects to
    srv = socket.socket()
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("127.0.0.1", port))
    srv.listen(1)
    srv.settimeout(5)
    # orbuculum is the client (-s connects out); accept it
    try:
        conn, _ = srv.accept()
    except socket.timeout:
        orb.terminate(); srv.close(); return None
    # 3) reader thread-ish: connect to orbuculum legacy :3443 first
    rdr = socket.socket(); rdr.settimeout(6)
    try:
        rdr.connect(("127.0.0.1", legacy_port))
    except OSError:
        orb.terminate(); conn.close(); srv.close(); return None
    # 4) pump the (holed) stream looped, while reading legacy output
    buf = bytearray()
    t0 = time.time()
    sent = 0
    try:
        while time.time() - t0 < 4.0:
            try:
                conn.sendall(stream_bytes)
                sent += len(stream_bytes)
            except OSError:
                break
            try:
                rdr.setblocking(False)
                while True:
                    d = rdr.recv(65536)
                    if not d:
                        break
                    buf += d
            except (BlockingIOError, OSError):
                pass
            time.sleep(0.05)
    finally:
        pass
    time.sleep(0.3)
    try:
        rdr.setblocking(False)
        while True:
            d = rdr.recv(65536)
            if not d:
                break
            buf += d
    except (BlockingIOError, OSError):
        pass
    rdr.close(); conn.close(); srv.close()
    orb.terminate()
    try:
        orb.wait(timeout=2)
    except subprocess.TimeoutExpired:
        orb.kill()
    fl = [x for x in L.find_isyncs(bytes(buf)) if L.is_flash(x.addr)]
    h = collections.Counter(x.addr for x in fl)
    return len(buf), len(fl), len(h)


def main():
    data = open(RAW, "rb").read()
    print(f"baseline raw {len(data)} B, full-sync={data.count(bytes([0xff,0xff,0xff,0x7f]))}")
    print(f"{'loss%':>6} {'fed_KB':>8} {'orbuculum_out_KB':>16} {'flash_anchors':>13} {'distinctPC':>10}")
    for loss in (0.0, 0.01, 0.05, 0.10, 0.20):
        holed = hole(data, loss)
        res = run_once(holed)
        if res is None:
            print(f"{loss*100:5.0f}%   (orbuculum link failed)")
            continue
        outb, anch, pcs = res
        print(f"{loss*100:5.0f}% {len(holed)/1024:8.1f} {outb/1024:16.1f} {anch:13d} {pcs:10d}")
        time.sleep(0.3)


if __name__ == "__main__":
    main()
