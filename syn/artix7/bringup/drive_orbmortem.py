#!/usr/bin/env python3
"""Drive ncurses orbmortem non-interactively via a pty, reading a trace file
directly (-f). Let it decode, hold, save .report, quit.

Usage: python3 drive_orbmortem.py <orbmortem> <elf> <tracefile> <savename> [proto]
"""
import os, pty, sys, time, select

def main():
    binp, elf, tracefile, savename = sys.argv[1:5]
    proto = sys.argv[5] if len(sys.argv) > 5 else "ETM3.5"
    argv = [binp, "-f", tracefile, "-e", elf, "-P", proto]
    pid, fd = pty.fork()
    if pid == 0:
        os.execv(binp, argv)
        os._exit(127)

    def drain(secs):
        end = time.time() + secs; buf = b""
        while time.time() < end:
            r,_,_ = select.select([fd],[],[],0.2)
            if fd in r:
                try: d = os.read(fd,4096)
                except OSError: break
                if not d: break
                buf += d
        return buf

    drain(5.0)                      # connect + decode the file (longer)
    # ensure we're at top level: send Enter/escape-ish, then Save directly
    os.write(fd, b"S"); time.sleep(0.8)
    os.write(fd, savename.encode()); time.sleep(0.8)
    os.write(fd, b"\r"); time.sleep(2.0)
    out = drain(1.5)
    sys.stderr.write(out.decode("utf-8","replace")[-1500:]+"\n")
    os.write(fd, b"Q"); time.sleep(0.8)
    try: os.close(fd)
    except OSError: pass
    print("done")

if __name__ == "__main__":
    main()
