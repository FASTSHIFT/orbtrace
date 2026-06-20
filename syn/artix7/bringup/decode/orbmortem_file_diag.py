#!/usr/bin/env python3
"""orbmortem_file_diag — drive orbmortem in offline file mode (-f) via pty,
let it decode, Hold, dump the screen. Isolates orbmortem's ETM3.5 decoder from
the live OFLOW path. Extracts the PC addresses it shows so we can compare to
the ELF / our etm35lib ground truth.

Usage: orbmortem_file_diag.py <orbmortem> <elf> <tracefile> [extra args...]
The tracefile should be a TPIU-framed ETM stream (orbmortem -f expects legacy
TPIU; pass a reframed file). Add -A etc. as extra args.
"""
import os
import pty
import re
import sys
import time
import select
import collections

def main():
    binp, elf, tf = sys.argv[1:4]
    extra = sys.argv[4:]
    argv = [binp, "-f", tf, "-e", elf, "-P", "ETM3.5", "-t", "2"] + extra
    pid, fd = pty.fork()
    if pid == 0:
        os.execv(binp, argv)
        os._exit(127)

    def drain(secs):
        end = time.time() + secs
        buf = b""
        while time.time() < end:
            r, _, _ = select.select([fd], [], [], 0.2)
            if fd in r:
                try:
                    d = os.read(fd, 8192)
                except OSError:
                    break
                if not d:
                    break
                buf += d
        return buf

    out = drain(6.0)
    os.write(fd, b"H"); time.sleep(0.5)
    out += drain(1.0)
    os.write(fd, b"Q"); time.sleep(0.3)
    try:
        os.close(fd)
    except OSError:
        pass

    clean = re.sub(rb"\x1b\[[0-9;?]*[a-zA-Z]", b"", out)
    clean = re.sub(rb"\x1b[()][AB0]", b"", clean)
    clean = re.sub(rb"[^\x09\x0a\x20-\x7e]", b"", clean)
    txt = clean.decode("utf-8", "replace")
    # extract 8-hex addresses that look like PCs (0800xxxx or others)
    addrs = re.findall(r"\b0?8[0-9a-fA-F]{6}\b", txt)
    hist = collections.Counter(a.lower().lstrip("0").rjust(8, "0") for a in addrs)
    print("status:", "Capturing" if "Capturing" in txt else
          ("Waiting" if "Waiting" in txt else "?"))
    print("KIps:", re.findall(r"\d+ KIps", txt)[:2])
    print("ASSEMBLY NOT FOUND count:", txt.count("ASSEMBLY NOT FOUND"))
    print("distinct PC-like addrs:", len(hist))
    print("top addrs:", [(a, c) for a, c in hist.most_common(10)])
    print("done")

if __name__ == "__main__":
    main()
