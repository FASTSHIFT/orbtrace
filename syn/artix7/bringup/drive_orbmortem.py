#!/usr/bin/env python3
"""Drive ncurses orbmortem non-interactively: connect to orbuculum (which
reads /tmp/tracefifo), then feed the corrected TPIU data into the fifo so it
arrives while orbmortem is connected; hold, save report, quit.

Usage: python3 drive_orbmortem.py <orbmortem-bin> <server:port> <elf> <savename> <datafile>
"""
import os, pty, sys, time, select, threading

def main():
    binp, server, elf, savename, datafile = sys.argv[1:6]
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
                try: d = os.read(fd, 4096)
                except OSError: break
                if not d: break
                buf += d
        return buf

    # let orbmortem connect to orbuculum first
    drain(1.5)

    # now feed data into the fifo (blocks until orbuculum reads it)
    data = open(datafile, "rb").read()
    def feed():
        with open("/tmp/tracefifo", "wb") as f:
            for _ in range(60):
                try:
                    f.write(data); f.flush()
                except BrokenPipeError:
                    break
    t = threading.Thread(target=feed, daemon=True); t.start()

    out = drain(4.0)
    sys.stderr.write(out.decode("utf-8","replace")[-1500:] + "\n----\n")
    os.write(fd, b"H"); time.sleep(0.5)        # hold
    os.write(fd, b"S"); time.sleep(0.3)        # save filename mode
    os.write(fd, savename.encode()); time.sleep(0.3)
    os.write(fd, b"\n"); time.sleep(1.0)       # commit
    drain(1.0)
    os.write(fd, b"Q"); time.sleep(0.5)
    try: os.close(fd)
    except OSError: pass
    print("done")

if __name__ == "__main__":
    main()
