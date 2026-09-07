#!/usr/bin/env python3
"""RIGOL MSO8304A control via pyvisa (pyvisa-py USB backend).

WHY pyvisa and NOT raw /dev/usbtmc: a hand-rolled read on the usbtmc char
device omits the USBTMC bulk-IN request / bTag handshake. It "works" for the
first query then desyncs and wedges the instrument's TMC processor (only a
power-cycle recovers it). pyvisa-py implements the handshake correctly. Always
go through this module.

Setup (once):
    pip3 install pyvisa pyvisa-py pyusb
    # udev rule for no-sudo access (see 60-rigol-usbtmc.rules in this dir):
    sudo cp 60-rigol-usbtmc.rules /etc/udev/rules.d/ && sudo udevadm control --reload
    # user must be in the 'plugdev' group

The kernel usbtmc driver and pyusb both bind the device; pyvisa-py/pyusb claims
the interface fine in practice. If a read ever times out (VI_ERROR_TMO) on the
FIRST transaction, power-cycle the scope -- the remote interface is wedged.
"""
import sys
import pyvisa

RIGOL_VID = 6833  # 0x1ab1


def find_resource(rm):
    for r in rm.list_resources():
        if r.startswith("USB") and f"::{RIGOL_VID}::" in r:
            return r
    raise RuntimeError("no RIGOL USB instrument found (is it powered / connected?)")


class Scope:
    def __init__(self, timeout_ms=5000):
        self.rm = pyvisa.ResourceManager("@py")
        self.rid = find_resource(self.rm)
        self.inst = self.rm.open_resource(self.rid)
        self.inst.timeout = timeout_ms
        self.inst.write_termination = "\n"
        self.inst.read_termination = "\n"
        # CRITICAL: if a previous session ended mid-query (Ctrl-C, timeout,
        # crash), the USB TMC bulk-IN buffer on the scope side still holds the
        # tail of the last binary block. The next Scope() opens fine but the
        # FIRST query returns those stale bytes ("#9001000000..." block header
        # from a `:WAVeform:DATA?`), which fails to parse. USBTMC has an
        # explicit clear op for exactly this — flush both directions.
        try:
            self.inst.clear()
        except Exception:
            pass
        # Also send *CLS to reset the error queue and any pending event
        # register bits — cheap belt+braces after a bad prior session.
        try:
            self.inst.write("*CLS")
        except Exception:
            pass

    def q(self, cmd, timeout_ms=None):
        if timeout_ms is not None:
            self.inst.timeout = timeout_ms
        return self.inst.query(cmd).strip()

    def w(self, cmd):
        self.inst.write(cmd)

    def read_block(self, cmd, timeout_ms=15000):
        """Query an IEEE-488.2 definite-length binary block (waveform data)."""
        self.inst.timeout = timeout_ms
        return self.inst.query_binary_values(
            cmd, datatype="B", container=bytes, header_fmt="ieee")

    def close(self):
        try:
            self.inst.close()
        except Exception:
            pass


if __name__ == "__main__":
    args = sys.argv[1:] or ["*IDN?"]
    s = Scope()
    try:
        for c in args:
            if c.endswith("?"):
                try:
                    print(f"{c} -> {s.q(c)}")
                except Exception as e:
                    print(f"{c} -> ERR {e!r}")
            else:
                s.w(c)
                print(f"{c} [sent]")
    finally:
        s.close()
