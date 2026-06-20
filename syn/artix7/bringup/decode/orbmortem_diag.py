#!/usr/bin/env python3
"""orbmortem_diag — run orbmortem against a live orbuculum server under a pty
with -v 3, capture the verbose stderr diagnostics (RXED packets, sync, decode
counts) to confirm it is actually receiving + decoding the live OFLOW tag-2
ETM stream. Prints the captured diagnostic lines.

Usage: orbmortem_diag.py <orbmortem> <elf> <server:port> [secs]
"""
import os
import pty
import re
import sys
import time
import select

def main():
    binp, elf, server = sys.argv[1:4]
    secs = float(sys.argv[4]) if len(sys.argv) > 4 else 10.0
    argv = [binp, "-s", server, "-e", elf, "-P", "ETM3.5", "-t", "2", "-v", "3"]
    pid, fd = pty.fork()
    if pid == 0:
        os.execv(binp, argv)
        os._exit(127)

    end = time.time() + secs
    buf = b""
    while time.time() < end:
        r, _, _ = select.select([fd], [], [], 0.3)
        if fd in r:
            try:
                d = os.read(fd, 8192)
            except OSError:
                break
            if not d:
                break
            buf += d
    os.write(fd, b"Q")
    time.sleep(0.3)
    try:
        os.close(fd)
    except OSError:
        pass

    clean = re.sub(rb"\x1b\[[0-9;?]*[a-zA-Z]", b"", buf)
    clean = re.sub(rb"\x1b[()][AB0]", b"", clean)
    clean = re.sub(rb"[^\x09\x0a\x20-\x7e]", b"", clean)
    txt = clean.decode("utf-8", "replace")
    # surface the diagnostic-looking lines
    keys = ("RXED", "ync", "Decod", "Server", "Protocol", "Elf", "packet",
            "ETM", "tag", "Tag", "OFLOW", "error", "Error")
    for line in txt.splitlines():
        if any(k in line for k in keys) and line.strip():
            print("DIAG:", line.strip())
    print("done")

if __name__ == "__main__":
    main()
