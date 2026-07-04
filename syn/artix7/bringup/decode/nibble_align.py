#!/usr/bin/env python3
"""nibble_align — shared nibble->byte alignment for FPGA-captured trace bytes.

The MMCM capture packs one byte per TRACECLK period as {trace_a, trace_b}
nibbles. The correct time-ordered pairing (phase + hi/lo order) is unknown up
front, so we pick the (phase, order) that maximises the count of TPIU HSYNC
(0xFF 0x7F) fillers — a known, high-frequency pattern in any real capture.

period_vote / si_probe / nibble_completeness all needed this identical search;
this is the single copy.

Public API:
  best_align(raw) -> (hsync_count, phase, order, aligned_bytes)
        raw: bytes captured from the FPGA ({b<<4|a} per byte).
        phase in (0,1); order in ("lohi","hilo"); aligned_bytes: bytes.
"""
from __future__ import annotations


def _expand_nibbles(raw):
    nibs = bytearray()
    for b in raw:
        nibs.append(b >> 4)
        nibs.append(b & 0xF)
    return nibs


def best_align(raw):
    """Return (hsync_count, phase, order, aligned_bytes) for the nibble pairing
    that maximises TPIU HSYNC (FF7F) occurrences."""
    nibs = _expand_nibbles(raw)
    best = None
    for ph in (0, 1):
        for order in ("lohi", "hilo"):
            out = bytearray()
            i = ph
            while i + 1 < len(nibs):
                if order == "lohi":
                    out.append((nibs[i + 1] << 4) | nibs[i])
                else:
                    out.append((nibs[i] << 4) | nibs[i + 1])
                i += 2
            h = bytes(out).count(b"\xff\x7f")
            if best is None or h > best[0]:
                best = (h, ph, order, bytes(out))
    return best
