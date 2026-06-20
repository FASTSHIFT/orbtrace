#!/usr/bin/env python3
"""drive_orbmortem_live — drive ncurses orbmortem against a LIVE orbuculum
server (-s) via a pty, let it decode the live stream for a few seconds, save a
.report, and dump the tail of the screen so we can confirm real-time ETM
decode end-to-end (no TUI interaction needed).

Usage: drive_orbmortem_live.py <orbmortem> <elf> <server:port> <savename> [secs]
"""
import os
import pty
import sys
import time
import select

def main():
    binp, elf, server, savename = sys.argv[1:5]
    secs = float(sys.argv[5]) if len(sys.argv) > 5 else 8.0
    argv = [binp, "-s", server, "-e", elf, "-P", "ETM3.5", "-t", "2"]
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
                    d = os.read(fd, 4096)
                except OSError:
                    break
                if not d:
                    break
                buf += d
        return buf

    out = drain(secs)                 # let it connect + decode live
    os.write(fd, b"H"); time.sleep(0.5)   # Hold (stop scrolling)
    os.write(fd, b"S"); time.sleep(0.8)   # Save
    os.write(fd, savename.encode()); time.sleep(0.8)
    os.write(fd, b"\r"); time.sleep(2.0)
    out += drain(1.5)
    # strip ANSI for readability
    import re
    clean = re.sub(rb"\x1b\[[0-9;?]*[a-zA-Z]", b"", out)
    clean = re.sub(rb"[^\x09\x0a\x20-\x7e]", b"", clean)
    sys.stderr.write(clean.decode("utf-8", "replace")[-2000:] + "\n")
    os.write(fd, b"Q"); time.sleep(0.5)
    try:
        os.close(fd)
    except OSError:
        pass
    print("done")

if __name__ == "__main__":
    main()
