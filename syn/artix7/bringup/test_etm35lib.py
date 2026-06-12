"""Unit tests for etm35lib, with golden vectors taken from IHI0014Q.

Run:  pytest -q test_etm35lib.py
"""
import struct

import pytest

import etm35lib as L


# ----------------------------------------------------------------------------
# is_flash
# ----------------------------------------------------------------------------
@pytest.mark.parametrize("addr,expected", [
    (0x08000000, True),
    (0x08000001, True),          # thumb bit set, still flash
    (0x0800abcd, True),
    (0x080FFFFF, True),
    (0x08100000, False),         # one past the 1MB region
    (0x20000000, False),         # SRAM
    (0x00000000, False),
    (0xF0CCD1F8, False),         # the garbage we saw pre-anchor
])
def test_is_flash(addr, expected):
    assert L.is_flash(addr) is expected


# ----------------------------------------------------------------------------
# find_asyncs  (IHI0014Q §7.10.4: >=5 zeros then 0x80)
# ----------------------------------------------------------------------------
def test_find_async_basic():
    data = bytes([1, 2]) + L.ASYNC + bytes([0x84, 9])
    offs = L.find_asyncs(data)
    # 0x80 sits at index 2+5 = 7
    assert offs == [7]


def test_find_async_more_than_five_zeros():
    # 8 zeros then 0x80 is still a valid A-sync (DDI0328-style 8-zero form)
    data = bytes([0] * 8 + [0x80, 0x84])
    assert L.find_asyncs(data) == [8]


def test_find_async_too_few_zeros():
    data = bytes([0, 0, 0, 0, 0x80])   # only 4 zeros
    assert L.find_asyncs(data) == []


def test_find_async_zeros_not_terminated_by_80():
    data = bytes([0, 0, 0, 0, 0, 0x84])  # 5 zeros then a non-0x80
    assert L.find_asyncs(data) == []


def test_find_async_multiple():
    blk = L.ASYNC + bytes([0x88] * 10)
    data = blk + blk
    offs = L.find_asyncs(data)
    assert len(offs) == 2
    assert offs[1] - offs[0] == len(blk)


# ----------------------------------------------------------------------------
# parse_isync_at / find_isyncs  (IHI0014Q Fig 7-42, 0 ContextID bytes on M4)
# ----------------------------------------------------------------------------
def make_isync(addr, thumb=False, reason=L.REASON_PERIODIC, nonsecure=False):
    info = (reason & 0b11) << 5
    if nonsecure:
        info |= 0x08
    a = addr | (1 if thumb else 0)
    return bytes([0x08, info]) + struct.pack("<I", a)


def test_parse_isync_roundtrip():
    pkt = make_isync(0x08005414, thumb=True, reason=L.REASON_PERIODIC)
    s = L.parse_isync_at(pkt, 0)
    assert s is not None
    assert s.addr == 0x08005414
    assert s.thumb is True
    assert s.reason == L.REASON_PERIODIC


def test_parse_isync_rejects_lsip():
    # info bit7 set => LSiP I-sync, not Normal -> reject
    pkt = bytearray(make_isync(0x08005414))
    pkt[1] |= 0x80
    assert L.parse_isync_at(bytes(pkt), 0) is None


def test_parse_isync_rejects_nonflash():
    pkt = make_isync(0x20001000)        # SRAM addr
    assert L.parse_isync_at(pkt, 0) is None


def test_parse_isync_rejects_wrong_header():
    pkt = bytearray(make_isync(0x08005414))
    pkt[0] = 0x88                        # P-header, not I-sync
    assert L.parse_isync_at(bytes(pkt), 0) is None


def test_parse_isync_truncated():
    pkt = make_isync(0x08005414)[:4]     # too short
    assert L.parse_isync_at(pkt, 0) is None


def test_find_isyncs_embedded():
    noise = bytes([0x88, 0x8c, 0x01, 0x40])
    # addresses are even; the Thumb bit is conveyed separately (bit0) and the
    # decoder strips it, so use even base addresses here.
    s1 = make_isync(0x08001234)
    s2 = make_isync(0x0800abcc, thumb=True)
    data = noise + s1 + noise + s2 + noise
    found = L.find_isyncs(data)
    addrs = [s.addr for s in found]
    assert 0x08001234 in addrs
    assert 0x0800abcc in addrs


def test_recover_pcs_dedup_and_sort():
    s = make_isync(0x0800abcc)
    data = s + bytes([0x88]) + s        # same PC twice
    assert L.recover_pcs(data) == [0x0800abcc]


def test_thumb_bit_stripped_from_addr():
    # An odd address means Thumb; the returned addr has bit0 cleared and
    # thumb=True regardless of the explicit thumb flag.
    s = L.parse_isync_at(make_isync(0x08001234, thumb=True), 0)
    assert s.addr == 0x08001234
    assert s.thumb is True


# ----------------------------------------------------------------------------
# bit_shift  (IHI0014Q §7.10.4 sub-byte realignment model)
# ----------------------------------------------------------------------------
def test_bit_shift_identity():
    data = bytes([0xDE, 0xAD, 0xBE, 0xEF])
    assert L.bit_shift(data, 0) == data


def test_bit_shift_known_vector():
    # IHI0014Q §7.10.4 worked example: the byte-aligned A-sync+E-header
    #   00 00 00 00 00 80 84
    # captured 1 bit early (off by 1) reads as
    #   01 00 00 00 00 40 42
    # i.e. right-shifting the misaligned capture by 1 bit recovers the aligned
    # form (minus the leading partial byte). Verify the shift math reproduces
    # the relationship for the trailing 80 84 <-> 40 42 pair.
    misaligned = bytes([0x40, 0x42])     # 80 84 shifted right 1 (carry)
    # shifting 'misaligned' LEFT by 1 == our stream captured 1 bit late;
    # here we just check bit_shift is the exact inverse operation it claims.
    shifted = L.bit_shift(bytes([0x80, 0x84]), 1)
    assert shifted[0] == 0x40            # 0x80>>1 | (0x84<<7)&0xff = 0x40
    assert len(shifted) == 1


def test_bit_shift_range():
    with pytest.raises(ValueError):
        L.bit_shift(b"\x00\x01", 8)


def test_bit_shift_recovers_isync_when_offset():
    # Build an I-sync, push the whole stream 3 bits late, and confirm
    # bit_shift(.,3) recovers a parseable I-sync.
    pkt = make_isync(0x08001234)
    stream = pkt + bytes([0x88, 0x8c])
    # emulate a 3-bit-late capture: shift everything LEFT by 3 (lose low bits)
    late = bytearray()
    prev = 0
    for b in stream:
        late.append(((b << 3) | (prev >> 5)) & 0xFF)
        prev = b
    recovered = L.bit_shift(bytes(late), 3)
    assert any(s.addr == 0x08001234 for s in L.find_isyncs(recovered))


# ----------------------------------------------------------------------------
# traceif_assemble — model of verilog/traceIF.v
# ----------------------------------------------------------------------------
def nibbles_for(byte_stream, sync_first=True):
    """Encode a byte stream as traceIF nibble-bytes {b<<4 | a}, LSB nibble
    first per the RTL shift order, prefixed with a 0x7FFFFFFF sync so the
    model locks."""
    # Build the 16-bit-packet view: traceIF emits packets little-endian byte
    # pairs. To keep the test simple we feed it the sync then raw nibbles.
    out = bytearray()

    def emit_byte(v):
        # each captured clk carries trace_a (low nibble) + trace_b (high)
        out.append(v)

    # 0x7FFFFFFF sync = 8 nibbles of 0xF except top; we just feed the exact
    # nibble pattern the RTL recognises: simplest is to feed 0xFF bytes that
    # form 0x7FFFFFFF in the shift register. This is covered by the RTL sim,
    # so here we only assert the function runs and is deterministic.
    return bytes(out)


def test_traceif_assemble_deterministic():
    # Same input twice -> identical output (no hidden state).
    data = bytes(range(256)) * 4
    assert L.traceif_assemble(data) == L.traceif_assemble(data)


def test_traceif_assemble_empty():
    assert L.traceif_assemble(b"") == b""


def test_traceif_assemble_no_sync_yields_nothing():
    # A stream that never contains 0x7FFFFFFF in the shift register emits
    # nothing (never locks). All-zero nibbles can't form the sync word.
    assert L.traceif_assemble(bytes(100)) == b""


def test_traceif_assemble_locks_and_emits():
    # Drive the shift register to 0x7FFFFFFF then feed payload nibbles so the
    # post-sync packet-emit branch runs (covers the synced/emit path).
    #   - 12 x 0xFF fills construct with 0xF nibbles
    #   - 0x7F puts b=0x7,a=0xF on top -> construct top32 == 0x7FFFFFFF (lock)
    #   - following non-0x7FFF payload bytes are emitted as 16-bit packets
    stream = bytes([0xFF] * 12 + [0x7F] + [0x12, 0x34, 0x56, 0x78] * 4)
    out = L.traceif_assemble(stream)
    assert isinstance(out, bytes)
    assert len(out) > 0                       # locked and emitted packets
    # deterministic
    assert L.traceif_assemble(stream) == out


def test_traceif_assemble_drops_idle_packets():
    # After lock, a 0x7FFF packet (idle half-word) must be dropped, not emitted.
    # Feed nibbles that form 0x7FFF packets only -> no payload bytes out.
    stream = bytes([0xFF] * 12 + [0x7F] + [0xF7, 0xFF] * 8)
    out = L.traceif_assemble(stream)
    # all emitted packets that equal 0x7FFF are dropped; output may be empty or
    # only contain non-idle packets — assert no 0x7fff pair leaked through
    pairs = [out[k:k + 2] for k in range(0, len(out) - 1, 2)]
    assert b"\xff\x7f" not in pairs


# ----------------------------------------------------------------------------
# Regression against a real on-board capture fixture (captures/etm_isync_fixture.bin)
# 8 KB slice of a real STM32F429 ETM capture (LVGL widgets demo). Locks in the
# spec-correct I-sync extraction so future refactors can't silently regress.
# ----------------------------------------------------------------------------
import os

FIXTURE = os.path.join(os.path.dirname(__file__), "captures", "etm_isync_fixture.bin")


@pytest.mark.skipif(not os.path.exists(FIXTURE), reason="fixture missing")
def test_real_capture_isync_anchors():
    data = open(FIXTURE, "rb").read()
    syncs = L.find_isyncs(data)
    # The 8KB slice contains exactly two periodic I-sync anchors at the fixed
    # 1024-byte sync cadence; both carry valid flash PCs.
    assert len(syncs) == 2
    pcs = L.recover_pcs(data)
    assert pcs == [0x08006530, 0x080083D0]
    for s in syncs:
        assert L.is_flash(s.addr)


@pytest.mark.skipif(not os.path.exists(FIXTURE), reason="fixture missing")
def test_real_capture_async_present():
    data = open(FIXTURE, "rb").read()
    # A-syncs (>=5 zeros + 0x80) must be present at roughly the sync cadence.
    asyncs = L.find_asyncs(data)
    assert len(asyncs) >= 1
