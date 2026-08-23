#!/usr/bin/env python3
"""nack_protocol — wire format + reassembly for doc 19 L3 NACK retransmit.

Shared definitions for the reliable-transport receiver (`nack_rx.py`) and its
offline loopback validator (`nack_loopback_test.py`). Keeping the packet layout
in one place so the FPGA-side RTL (la_ddr_ring_streamer) and PC-side agree.

Data packet (FPGA -> PC, :5555 self-TX), unchanged from the raw stream except
the header byte now carries a retransmit flag:

    offset  size  field
    0       4     seq        big-endian uint32, monotonic packet index
                             (= DDR ring word_index / PKT_WORDS)
    4       1     flags      bit0 = retransmit (1 = this is a resent packet)
    5       3     reserved   (0)
    8       N     payload    trace bytes (N = PKT_BYTES, default 1024)

NACK request (PC -> FPGA, :5002 CTRL): a distinct opcode so the existing
{addr,value} CSR path is untouched. The FPGA CTRL parser dispatches on byte 0:

    offset  size  field
    0       1     opcode     0xNA = 0xNK marker (0x4E 'N') for NACK
    1       1     op2        0x4B ('K')  -> together "NK" magic, unambiguous vs
                            the 1-byte CSR writes (which never start 0x4E,0x4B)
    2       2     reserved
    4       4     start_seq  big-endian uint32, first missing packet
    8       2     count      big-endian uint16, packets to retransmit
    10      2     reserved

NACK-fail reply (FPGA -> PC, :5002 or piggybacked): the requested seq fell out
of the DDR history window (permanently lost). Marked in the data stream by the
FPGA never delivering it; the PC times out and records a coverage gap.
"""
import struct

# ---- data packet ----
HDR_LEN     = 8
PKT_BYTES   = 1024                 # payload bytes per packet (= PKT_WORDS*16)
PKT_WORDS   = PKT_BYTES // 16       # 128-bit words per packet (matches RTL)
FLAG_RETRANSMIT = 0x01

# ---- NACK request ----
NACK_MAGIC  = b"NK"                 # bytes 0..1 distinguish from CSR writes
NACK_LEN    = 12
CTRL_PORT   = 5002
DATA_PORT   = 5555


def parse_data_packet(buf):
    """Return (seq, is_retransmit, payload) or None if too short."""
    if len(buf) < HDR_LEN:
        return None
    seq = struct.unpack_from(">I", buf, 0)[0]
    flags = buf[4]
    payload = buf[HDR_LEN:]
    return seq, bool(flags & FLAG_RETRANSMIT), payload


def build_data_packet(seq, payload, retransmit=False):
    """Build a data packet (used by the loopback fake-FPGA)."""
    flags = FLAG_RETRANSMIT if retransmit else 0
    return struct.pack(">IB3x", seq, flags) + payload


def build_nack(start_seq, count):
    """Build a NACK request (PC -> FPGA)."""
    return NACK_MAGIC + b"\x00\x00" + struct.pack(">IH2x", start_seq, count)


def parse_nack(buf):
    """Return (start_seq, count) if buf is a NACK, else None."""
    if len(buf) < NACK_LEN or buf[0:2] != NACK_MAGIC:
        return None
    start_seq = struct.unpack_from(">I", buf, 4)[0]
    count = struct.unpack_from(">H", buf, 8)[0]
    return start_seq, count


def coalesce_gaps(missing_seqs, max_span=64):
    """Coalesce a set/list of missing seq numbers into (start, count) runs,
    splitting runs longer than max_span (one NACK's count field is uint16 but
    the FPGA services at most max_span packets per request to bound a single
    retransmit burst). doc 19 §5.2 NACK aggregation."""
    if not missing_seqs:
        return []
    s = sorted(set(missing_seqs))
    runs = []
    start = prev = s[0]
    for x in s[1:]:
        if x == prev + 1 and (prev - start + 1) < max_span:
            prev = x
        else:
            runs.append((start, prev - start + 1))
            start = prev = x
    runs.append((start, prev - start + 1))
    return runs
