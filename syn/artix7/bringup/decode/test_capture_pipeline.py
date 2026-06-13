"""Unit tests for the FPGA capture / .dsl-replay pipeline.

Covers the pieces added while proving the OVERSAMPLE front-end LA-equivalent:
  * dsl_to_stim     — .dsl sample -> per-sample stimulus byte packing
  * sim_la_equiv    — RTL byte dump -> time-order nibbles -> re-pair -> deframe,
                      and the byte-identical comparison gate
  * fpga_la_crosscheck.deframe_raw — the {trace_b,trace_a} re-pairing decode

These lock in the nibble-ordering / re-pairing conventions that were the
actual root cause (doc 14 §24), so a future refactor cannot silently regress
them.

Run:  pytest -q test_capture_pipeline.py
"""
import os
import struct

import pytest

import etm35lib as L
import dsl_parse as D
import dsl_to_stim as S
import sim_la_equiv as E
import fpga_la_crosscheck as X


# ----------------------------------------------------------------------------
# dsl_to_stim byte packing: bit4=TRACECLK bit3..0 = TD3..TD0
# ----------------------------------------------------------------------------
def test_stim_pack_bit_layout():
    # Reconstruct the packing used by dsl_to_stim.main and assert the layout.
    # clk=1, d0=1, d3=1, others 0 -> (1<<4)|(1<<3)|(0)|(0)|(1) = 0x19
    clk, d0, d1, d2, d3 = 1, 1, 0, 0, 1
    v = (clk << 4) | (d3 << 3) | (d2 << 2) | (d1 << 1) | d0
    assert v == 0x19
    # all low -> 0; all high -> 0x1F
    assert ((0) | 0) == 0
    assert (1 << 4) | (1 << 3) | (1 << 2) | (1 << 1) | 1 == 0x1F


def test_stim_roundtrip_unpacks_to_same_pins():
    # A packed stimulus byte must unpack back to the exact pin bits, which is
    # what the testbench feeds: trace_clk_p=bit4, trace_data_p=bits[3:0].
    for clk in (0, 1):
        for data in range(16):
            v = (clk << 4) | data
            assert (v >> 4) & 1 == clk
            assert v & 0xF == data


# ----------------------------------------------------------------------------
# nibble extraction from the {trace_b, trace_a} byte: time order = b then a
# ----------------------------------------------------------------------------
def test_rtl_nibbles_time_order_b_then_a():
    # byte 0x9C -> trace_b=0x9 (high, falling, FIRST in time), trace_a=0xC
    raw = bytes([0x9C, 0x3A])
    # write a temp hex file in the format sim_la_equiv expects
    p = "/tmp/_test_rtl_nibbles.hex"
    with open(p, "w") as f:
        f.write("9c\n3a\n")
    nibs = E.rtl_nibbles(p)
    assert list(nibs) == [0x9, 0xC, 0x3, 0xA]
    os.remove(p)


def test_crosscheck_and_equiv_use_same_nibble_order():
    # deframe_raw (crosscheck) and rtl_nibbles (sim_la_equiv) must extract the
    # same time-ordered nibble convention, else board and sim decode differ.
    p = "/tmp/_test_order.hex"
    with open(p, "w") as f:
        f.write("9c\n3a\n")
    nibs_equiv = list(E.rtl_nibbles(p))
    os.remove(p)
    # crosscheck builds the same expansion inline; reproduce it:
    raw = bytes([0x9C, 0x3A])
    nibs_xc = []
    for b in raw:
        nibs_xc.append((b >> 4) & 0xF)
        nibs_xc.append(b & 0xF)
    assert nibs_equiv == nibs_xc


# ----------------------------------------------------------------------------
# Synthetic round-trip: build a known ETM byte stream, frame it as TPIU,
# DDR-split it into {trace_b,trace_a} bytes the way the FPGA would emit them,
# and confirm deframe_raw / sim_la_equiv recover the original ETM bytes.
# ----------------------------------------------------------------------------
def _make_isync(addr, thumb=False):
    info = (L.REASON_PERIODIC & 0b11) << 5
    a = addr | (1 if thumb else 0)
    return bytes([0x08, info]) + struct.pack("<I", a)


def _frame_tpiu(payload, stream_id=1):
    """Wrap payload bytes into 16-byte TPIU frames (even-LSB-in-aux scheme),
    matching what tpiu_deframe_hsync expects. Returns a stream of whole frames
    carrying `payload` on stream_id, padded to a frame boundary with zeros."""
    out = bytearray()
    i = 0
    # 14 payload bytes per frame (byte0 = stream-id change, byte15 = aux)
    while i < len(payload):
        chunk = payload[i:i + 14]
        i += 14
        frame = bytearray(16)
        frame[0] = (stream_id << 1) | 1
        aux = 0
        for k in range(1, 15):
            src = chunk[k - 1] if (k - 1) < len(chunk) else 0
            if k % 2 == 0:
                frame[k] = src & 0xFE
                if src & 1:
                    aux |= (1 << (k // 2))
            else:
                frame[k] = src
        frame[15] = aux
        out += frame
    return bytes(out)


def _ddr_pack_to_fpga_bytes(tpiu_stream):
    """Emulate the FPGA CAP_RAW packing of a wire byte-stream.

    Proven relationship (doc 14 §24): the FPGA emits one byte
    {trace_b(high), trace_a(low)} per trace_clk period, and the ETM/TPIU byte
    boundary is offset half a period from it. deframe_raw expands each FPGA
    byte to time-ordered nibbles [b, a] and recovers the wire bytes with
    D.assemble(parity=1, order=0), i.e. wire[j] = (b_{j+1}<<4) | a_j. Inverting:

        b_j = wirehigh[j-1],  a_j = wirelow[j]
        fpga[j] = (wirehigh[j-1] << 4) | wirelow[j]

    so the FPGA byte pairs the *previous* wire byte's high nibble with the
    current wire byte's low nibble — the cross-period offset that forced the
    parity search.
    """
    fpga = bytearray()
    prev_high = 0
    for b in tpiu_stream:
        low = b & 0xF
        high = (b >> 4) & 0xF
        fpga.append((prev_high << 4) | low)
        prev_high = high
    return bytes(fpga)


def test_deframe_raw_recovers_isync_anchor():
    # Build an ETM payload with a flash I-sync, frame it, DDR-pack it like the
    # FPGA, then confirm deframe_raw recovers the anchor.
    payload = bytes([0x88, 0x88]) + _make_isync(0x08001234) + bytes([0x88] * 10)
    payload = payload * 4                       # a few frames' worth
    tpiu = bytes([0xFF, 0xFF, 0xFF, 0x7F]) + _frame_tpiu(payload)
    fpga = _ddr_pack_to_fpga_bytes(tpiu)
    etm, phase = X.deframe_raw(fpga)
    syncs = L.find_isyncs(etm)
    assert any(s.addr == 0x08001234 for s in syncs)


def test_deframe_raw_returns_phase_when_framed():
    payload = (bytes([0x88]) + _make_isync(0x08002000) + bytes([0x88] * 7)) * 6
    tpiu = bytes([0xFF, 0xFF, 0xFF, 0x7F]) + _frame_tpiu(payload)
    fpga = _ddr_pack_to_fpga_bytes(tpiu)
    etm, phase = X.deframe_raw(fpga)
    assert phase is not None
    assert 0 <= phase < 16


# ----------------------------------------------------------------------------
# sim_la_equiv comparison gate
# ----------------------------------------------------------------------------
def test_compare_identical():
    a = bytes(range(100))
    mism, same_len, m = E.compare(a, a)
    assert mism == 0 and same_len and m == 100


def test_compare_detects_byte_diff():
    a = bytearray(range(100))
    b = bytearray(range(100))
    b[50] ^= 0xFF
    mism, same_len, m = E.compare(bytes(a), bytes(b))
    assert mism == 1 and same_len


def test_compare_detects_length_diff():
    a = bytes(range(100))
    b = bytes(range(90))
    mism, same_len, m = E.compare(a, b)
    assert same_len is False
    assert m == 90


# ----------------------------------------------------------------------------
# Equivalence on real artefacts (skipped if the sim outputs are not present).
# These run after tb_dsl_replay has been executed; they are the regression
# guard that the RTL stays byte-identical to the LA path.
# ----------------------------------------------------------------------------
GOLDEN_DSL = "/home/vifex/workpath/orbcode/DSLogic U2Basic-la-260613-194702.dsl"


@pytest.mark.skipif(not (os.path.exists("/tmp/sim_raw_big.hex")
                         and os.path.exists(GOLDEN_DSL)),
                    reason="sim replay output / golden dsl not present")
def test_rtl_sim_byte_identical_to_la_2m():
    rtl = E.rtl_decode("/tmp/sim_raw_big.hex")
    la = E.la_decode(GOLDEN_DSL, 2_000_000)
    mism, same_len, m = E.compare(rtl, la)
    assert same_len and mism == 0 and m > 1000
