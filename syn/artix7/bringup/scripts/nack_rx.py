#!/usr/bin/env python3
"""nack_rx — reliable-transport receiver for doc 19 L3 NACK retransmit.

Two parts:

  * ReliableReceiver — transport-agnostic reassembly + gap detection + NACK
    scheduling logic. No sockets: you feed it packets and it tells you which
    NACKs to send and yields in-order payload. This is what the offline
    loopback validator (nack_loopback_test.py) drives to prove seq-gap=0 after
    retransmit WITHOUT hardware.

  * main() — the live UDP front-end: recvfrom :5555, feed the receiver, send
    coalesced NACKs to the FPGA :5002, write the gap-free byte stream to a file.
    (For production throughput swap recvfrom for the recvmmsg C path; the
    reassembly logic is identical.)

Design (doc 19 §5):
  - Maintain expected_seq (next in-order packet to deliver downstream).
  - Buffer out-of-order packets in a dict keyed by seq.
  - When seq > expected_seq arrives, seqs (expected_seq .. seq-1) are MISSING.
    Register them, but wait a short DEBOUNCE (reorder tolerance) before NACKing
    (doc 19 §5.2: "攒一小段避免抖动误报").
  - Periodically flush: coalesce still-missing seqs into NACK runs, emit them,
    and deliver any now-contiguous prefix.
  - A seq that stays missing past MAX_RETRIES * timeout is declared a permanent
    coverage gap (DDR window exceeded / NACK-fail) and delivered as a hole so
    the decoder sees a clean trace break, not corruption.
"""
import argparse
import socket
import sys
import time

import nack_protocol as proto


class ReliableReceiver:
    def __init__(self, debounce_pkts=8, max_retries=5, retry_after=0.02,
                 nack_max_span=64):
        self.expected = None          # next seq to deliver (None until 1st pkt)
        self.buf = {}                 # seq -> payload (out-of-order hold)
        self.missing = {}             # seq -> [first_seen_t, retries]
        self.debounce_pkts = debounce_pkts
        self.max_retries = max_retries
        self.retry_after = retry_after
        self.nack_max_span = nack_max_span
        self.highest_seen = None
        # stats
        self.delivered = 0
        self.retransmitted = 0
        self.perm_gaps = 0
        self.nacks_sent = 0

    def on_packet(self, seq, is_rtx, payload):
        """Ingest one received data packet."""
        if self.expected is None:
            self.expected = seq       # first packet defines the baseline
        if self.highest_seen is None or _seq_gt(seq, self.highest_seen):
            self.highest_seen = seq
        # a packet we already delivered past? drop (duplicate / late rtx)
        if _seq_lt(seq, self.expected):
            return
        if seq in self.missing:
            del self.missing[seq]     # a hole just got filled
            if is_rtx:
                self.retransmitted += 1
        self.buf[seq] = payload
        # any seqs between expected and this one that we haven't seen are holes
        if _seq_gt(seq, self.expected):
            s = self.expected
            while _seq_lt(s, seq):
                if s not in self.buf and s not in self.missing:
                    self.missing[s] = [time.monotonic(), 0]
                s = (s + 1) & 0xFFFFFFFF

    def deliver(self):
        """Yield contiguous in-order payloads, advancing expected. Stops at the
        first hole (missing seq) or permanent gap sentinel."""
        out = []
        while self.expected is not None:
            e = self.expected
            if e in self.buf:
                out.append((e, self.buf.pop(e)))
                self.delivered += 1
                self.expected = (e + 1) & 0xFFFFFFFF
            elif e in self.missing and self.missing[e][1] >= self.max_retries:
                # permanent coverage gap: emit a hole marker, skip past it
                out.append((e, None))
                self.perm_gaps += 1
                del self.missing[e]
                self.expected = (e + 1) & 0xFFFFFFFF
            else:
                break                 # a hole we still hope to fill via NACK
        return out

    def due_nacks(self):
        """Return coalesced (start_seq, count) NACK runs for holes whose
        debounce elapsed and which are due for a (re)try. Bumps retry counters."""
        now = time.monotonic()
        # debounce: only NACK a hole once enough newer packets arrived (proving
        # it's a real loss not reorder) OR enough time passed.
        due = []
        for s, (first_t, retries) in list(self.missing.items()):
            newer = _seq_diff(self.highest_seen, s) if self.highest_seen is not None else 0
            debounced = newer >= self.debounce_pkts or (now - first_t) >= self.retry_after
            retry_due = (now - first_t) >= self.retry_after * (retries + 1)
            if debounced and retry_due and retries < self.max_retries:
                due.append(s)
                self.missing[s][1] = retries + 1
        runs = proto.coalesce_gaps(due, max_span=self.nack_max_span)
        self.nacks_sent += len(runs)
        return runs


def _seq_gt(a, b):   # a > b in mod-2^32 forward sense
    return ((a - b) & 0xFFFFFFFF) < 0x80000000 and a != b


def _seq_lt(a, b):
    return _seq_gt(b, a)


def _seq_diff(a, b):  # forward distance a-b mod 2^32
    return (a - b) & 0xFFFFFFFF


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--ip", default="192.168.10.42")
    ap.add_argument("--iface", default=None)
    ap.add_argument("--seconds", type=float, default=30.0)
    ap.add_argument("--out", default="/tmp/nack_stream.bin")
    a = ap.parse_args()

    rx = ReliableReceiver()
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 256 * 1024 * 1024)
    if a.iface:
        try:
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_BINDTODEVICE,
                            (a.iface + "\0").encode())
        except PermissionError:
            pass
    sock.bind(("192.168.10.245", proto.DATA_PORT))
    sock.settimeout(0.1)
    ctrl = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    if a.iface:
        try:
            ctrl.setsockopt(socket.SOL_SOCKET, socket.SO_BINDTODEVICE,
                            (a.iface + "\0").encode())
        except PermissionError:
            pass

    holes = 0
    t_end = time.monotonic() + a.seconds
    with open(a.out, "wb") as f:
        while time.monotonic() < t_end:
            try:
                buf, _ = sock.recvfrom(proto.PKT_BYTES + proto.HDR_LEN)
            except socket.timeout:
                buf = None
            if buf:
                p = proto.parse_data_packet(buf)
                if p:
                    rx.on_packet(*p)
            for seq, payload in rx.deliver():
                if payload is None:
                    holes += 1               # permanent coverage gap
                else:
                    f.write(payload)
            for start, count in rx.due_nacks():
                ctrl.sendto(proto.build_nack(start, count), (a.ip, proto.CTRL_PORT))

    print(f"delivered={rx.delivered} retransmitted={rx.retransmitted} "
          f"nacks={rx.nacks_sent} perm_gaps={rx.perm_gaps} holes_written={holes}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
