#!/usr/bin/env python3
"""eye_sweep — sweep the OVERSAMPLE mid-eye sample point (CSR 0x01) at a fixed
trace frequency and report the ETM byte-corruption rate for each eye value.

The capture front-end (trace_capture_a7, CAP_METHOD=OVERSAMPLE) detects each
TRACECLK edge on the 200 MHz reference and latches the 4 data lanes EYE_DELAY
ref-cycles (5 ns each) later. The correct EYE_DELAY is ~half a trace half-bit;
it is frequency-dependent, which is why a fixed compile-time default is wrong
across a frequency sweep. This tool finds the best eye at the CURRENT frequency
without reflashing anything.

For each eye value it:
  1. writes CSR 0x01 = eye, re-arms (0x02)
  2. captures ~1 s with stream_grab into a temp file
  3. runs recover_assemble + diagnose_bitflip and prints reserved%%.

Run from the scripts/ dir (needs stream_grab here and the decode/ package on
sys.path).
"""
import os
import subprocess
import sys
import socket
import time

HERE = os.path.dirname(os.path.abspath(__file__))
DECODE = os.path.abspath(os.path.join(HERE, "..", "decode"))
sys.path.insert(0, DECODE)

FPGA_IP = "192.168.10.42"
IFACE = "enxc8a36266dcae"
CTRL_PORT = 5002
ELF = os.path.abspath(os.path.join(
    HERE, "..", "..", "..", "..",
    "stm32h743-etm-trace-firmware", "build", "H743_Blink.elf"))


def csr(addr, val):
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        s.setsockopt(socket.SOL_SOCKET, socket.SO_BINDTODEVICE,
                     (IFACE + "\0").encode())
    except PermissionError:
        pass
    s.sendto(bytes([addr & 0xFF, val & 0xFF, 0, 0]), (FPGA_IP, CTRL_PORT))
    s.close()


def grab(path, secs, sudo_pw):
    p = subprocess.run(
        ["sudo", "-S", os.path.join(HERE, "stream_grab"),
         IFACE, str(secs), path, "128", "256"],
        input=(sudo_pw + "\n").encode(),
        capture_output=True)
    return p.returncode == 0 or os.path.exists(path)


def measure(path, nbytes=2097152):
    import opencsd_etm4_run as R
    raw = open(path, "rb").read()[:nbytes]
    _, parity, order, data, _, _, fsync = R.recover_assemble(raw, stream=2)
    etm, _ = R.T.deframe(data, want_stream=2)
    a, tr = R.count_v4_syncs(etm)
    bf = R.diagnose_bitflip(etm)
    return dict(reserved_pct=bf["reserved_pct"], asyncs=a, ti_after=tr,
                after_atom=bf["after_atom"], etm=len(etm))


def main():
    pw = os.environ.get("SUDO_PW", "asdjkl")
    eyes = [int(x) for x in (sys.argv[1].split(",") if len(sys.argv) > 1
                             else ["1", "2", "3", "4", "5", "6", "7", "8"])]
    secs = float(sys.argv[2]) if len(sys.argv) > 2 else 1.5
    tmp = "/media/vifextech/huge/hwtrace/captures/_eye_tmp.bin"
    print(f"{'eye':>4}  {'reserved%':>9}  {'A-sync':>7}  {'ti-after':>8}  {'ETM':>9}")
    results = []
    for eye in eyes:
        csr(0x01, eye)
        csr(0x02, 1)          # re-arm
        time.sleep(0.2)
        grab(tmp, secs, pw)
        m = measure(tmp)
        results.append((eye, m))
        print(f"{eye:>4}  {m['reserved_pct']:>9.2f}  {m['asyncs']:>7}  "
              f"{m['ti_after']:>8}  {m['etm']:>9}")
    best = min(results, key=lambda r: r[1]["reserved_pct"])
    print(f"\nbest eye = {best[0]}  (reserved% = {best[1]['reserved_pct']:.2f})")
    try:
        os.remove(tmp)
    except OSError:
        pass


if __name__ == "__main__":
    main()
