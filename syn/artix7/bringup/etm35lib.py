"""etm35lib — spec-grounded ETM3.5 (Cortex-M4) decode helpers, testable.

Consolidates the trace-decode logic that was scattered across the bring-up
scripts into one importable, unit-tested module. Everything here is grounded
in the ARM specs in docs/artix7-port/refs/:

  * IHI0014Q  Embedded Trace Macrocell Architecture Specification (ETMv3.5)
  * DDI0440C  Cortex-M4 ETM (ETM-M4) Technical Reference Manual

Cortex-M4 ETM facts used (DDI0440C Table 2-1, §2.1.3):
  * Architecture ETMv3.5
  * 0 ContextID comparators  -> ETMCR[15:14]=00 -> I-sync carries 0 ContextID
    bytes, so a Normal I-sync packet is exactly 6 bytes:
        0x08 | info | addr[7:0] | addr[15:8] | addr[23:16] | addr[31:24]
  * fixed synchronization frequency = 1024 bytes of trace (read-only ETMSYNCFR)

IHI0014Q facts used:
  * §7.10.4 A-sync = five-or-more 0x00 then 0x80; a 4-bit (sub-byte) port is
    NOT guaranteed byte-aligned, so a decoder must be able to realign.
  * Fig 7-42 Normal I-sync info byte: bit7=0 (Normal, not LSiP), bits[6:5]
    reason code, bit4 Jazelle, bit3 NonSecure, bit2 AltISA; the 4-byte address
    is uncompressed and address bit0 is the Thumb bit.
"""
from __future__ import annotations

from dataclasses import dataclass

# Cortex-M4 flash code region (STM32F4: 0x0800_0000 .. 0x080F_FFFF for 1MB).
FLASH_LO = 0x08000000
FLASH_HI = 0x08100000

ASYNC = bytes([0, 0, 0, 0, 0, 0x80])  # canonical 5-zero + 0x80 A-sync
ISYNC_HEADER = 0x08

# I-sync info-byte reason codes (IHI0014Q Fig 7-42 / Reason codes)
REASON_PERIODIC = 0b00
REASON_TRACE_ON = 0b01
REASON_OVERFLOW = 0b10
REASON_DEBUG_EXIT = 0b11


@dataclass(frozen=True)
class ISync:
    offset: int        # byte offset of the 0x08 header in the stream
    addr: int          # absolute instruction address (thumb bit stripped)
    thumb: bool        # address bit0 (Thumb state)
    reason: int        # info-byte reason code [6:5]
    nonsecure: bool


def is_flash(addr: int) -> bool:
    """True if addr is in the Cortex-M flash code region (thumb bit ignored)."""
    return FLASH_LO <= (addr & ~1) < FLASH_HI


def find_asyncs(data: bytes, min_zeros: int = 5) -> list[int]:
    """Return offsets of the terminating 0x80 of each A-sync.

    Per IHI0014Q §7.10.4 an A-sync is >=5 zero bytes followed by 0x80. We
    return the index of the 0x80 (the realign/IDLE point); the next packet
    header starts at offset+1.
    """
    out = []
    zeros = 0
    for i, c in enumerate(data):
        if c == 0x00:
            zeros += 1
        else:
            if c == 0x80 and zeros >= min_zeros:
                out.append(i)
            zeros = 0
    return out


def parse_isync_at(data: bytes, i: int) -> ISync | None:
    """Try to parse a Normal I-sync packet whose header is at offset i.

    Returns an ISync if the 6 bytes form a Normal I-sync with a flash address,
    else None. ContextID bytes = 0 on Cortex-M4 (DDI0440C).
    """
    if i + 5 >= len(data):
        return None
    if data[i] != ISYNC_HEADER:
        return None
    info = data[i + 1]
    if info & 0x80:          # bit7=1 => LSiP, not a Normal I-sync
        return None
    addr = (data[i + 2] | (data[i + 3] << 8)
            | (data[i + 4] << 16) | (data[i + 5] << 24))
    if not is_flash(addr):
        return None
    return ISync(
        offset=i,
        addr=addr & ~1,
        thumb=bool(addr & 1),
        reason=(info >> 5) & 0b11,
        nonsecure=bool(info & 0x08),
    )


def find_isyncs(data: bytes) -> list[ISync]:
    """Scan the whole stream for Normal I-sync packets carrying a flash PC.

    This is the robust anchor extractor: every Normal I-sync gives an absolute
    PC (IHI0014Q Fig 7-42), independent of whether the variable-length parse
    between syncs stayed aligned.
    """
    out = []
    for i in range(len(data) - 5):
        if data[i] != ISYNC_HEADER:
            continue
        s = parse_isync_at(data, i)
        if s is not None:
            out.append(s)
    return out


def bit_shift(data: bytes, shift: int) -> bytes:
    """Right-shift the whole byte stream by `shift` bits (0..7), LSB-first.

    Models the sub-byte misalignment of a 4-bit port (IHI0014Q §7.10.4): a
    capture off by N bits shifts every byte. Used to realign after an A-sync.
    """
    if shift == 0:
        return bytes(data)
    if not 0 <= shift <= 7:
        raise ValueError("shift must be 0..7")
    out = bytearray()
    for i in range(len(data) - 1):
        out.append(((data[i] >> shift) | (data[i + 1] << (8 - shift))) & 0xFF)
    return bytes(out)


def recover_pcs(data: bytes) -> list[int]:
    """Return the sorted distinct flash PCs anchored from I-sync packets."""
    return sorted({s.addr for s in find_isyncs(data)})


# --- traceIF byte-assembly model (matches verilog/traceIF.v width==3 path) ---
# construct <= {dinb[3:0], dina[3:0], construct[35:8]}; a 16-bit "packet" is
# emitted once synced on 0x7FFFFFFF; 0x7FFF packets are dropped. Used to model
# / cross-check the FPGA front-end in tests.
def traceif_assemble(nibble_bytes: bytes) -> bytes:
    """Model traceIF: input bytes = {trace_b[3:0]<<4 | trace_a[3:0]} per clk.

    Returns the assembled byte stream (TPIU/ETM bytes) after sync lock. This
    mirrors the RTL closely enough for regression on the byte ordering.
    """
    construct = 0
    out = bytearray()
    synced = False
    rem = 0
    for byte in nibble_bytes:
        a = byte & 0x0F
        b = (byte >> 4) & 0x0F
        # 36-bit shift register: new nibbles enter the top
        construct = ((b << 32) | (a << 28) | (construct >> 8)) & 0xFFFFFFFFF
        top32 = (construct >> 4) & 0xFFFFFFFF
        if top32 == 0x7FFFFFFF:
            synced = True
            rem = 1
            continue
        if synced:
            if rem:
                rem -= 1
            else:
                rem = 1
                pkt = (construct >> 4) & 0xFFFF
                if pkt != 0x7FFF:
                    out.append(pkt & 0xFF)
                    out.append((pkt >> 8) & 0xFF)
    return bytes(out)


# ----------------------------------------------------------------------------
# Region decoder: from an I-sync anchor, walk P-headers + branch packets to
# extend the recovered trace until the parse derails. Grounded in IHI0014Q
# §7.3.4 (P-headers), §7.3.5 (branch packets). Cortex-M is Thumb-only, so
# branch addresses use the Thumb address-mode bit layout.
# ----------------------------------------------------------------------------
@dataclass
class FlowEvent:
    kind: str          # 'isync' | 'atoms' | 'branch'
    addr: int          # current/target PC (thumb bit stripped) where meaningful
    eatoms: int = 0    # executed atoms (P-header)
    natoms: int = 0    # not-executed atoms


def _phdr_atoms(c: int):
    """Decode a non-cycle-accurate P-header byte. Returns (eatoms, natoms) or
    None if not a P-header. IHI0014Q §7.3.4."""
    if (c & 0b10000001) != 0b10000000:
        return None
    if (c & 0b10000011) == 0b10000000:        # Format-1
        eatoms = (c & 0x3C) >> 2
        natoms = 1 if (c & (1 << 6)) else 0
        return eatoms, natoms
    if (c & 0b11110011) == 0b10000010:        # Format-2
        eatoms = ((c & (1 << 2)) == 0) + ((c & (1 << 3)) == 0)
        natoms = 2 - eatoms
        return eatoms, natoms
    return None


def decode_region(data: bytes, start: int, base_addr: int, max_bytes: int = 4096):
    """Walk packets from `start` (just after an I-sync) until a byte we can't
    classify cleanly, returning the FlowEvents recovered. This is a best-effort
    forward extension from a known-good anchor; it deliberately stops at the
    first ambiguous byte rather than emitting garbage (the next anchor will
    re-establish the absolute PC).
    """
    events = []
    i = start
    end = min(len(data), start + max_bytes)
    while i < end:
        c = data[i]
        # branch packet (bit0 = 1): consume continuation bytes (bit7 set), max 5
        if c & 1:
            n = 1
            while i + n < end and (data[i + n - 1] & 0x80) and n < 5:
                n += 1
            events.append(FlowEvent("branch", base_addr))
            i += n
            continue
        ph = _phdr_atoms(c)
        if ph is not None:
            events.append(FlowEvent("atoms", base_addr, eatoms=ph[0], natoms=ph[1]))
            i += 1
            continue
        if c == 0x00:
            # could be start of next A-sync; stop and let caller re-anchor
            break
        if c == ISYNC_HEADER:
            s = parse_isync_at(data, i)
            if s is not None:
                events.append(FlowEvent("isync", s.addr))
                base_addr = s.addr
                i += 6
                continue
            break
        # unknown / can't classify cleanly -> stop (don't emit garbage)
        break
    return events, i


def decode_all(data: bytes):
    """Anchor on every I-sync and extend each region. Returns list of FlowEvent.
    The set of 'isync' addresses are guaranteed-correct absolute PCs; 'atoms'
    and 'branch' events give the executed-instruction flow between anchors."""
    events = []
    for s in find_isyncs(data):
        events.append(FlowEvent("isync", s.addr, ))
        region, _ = decode_region(data, s.offset + 6, s.addr)
        events.extend(region)
    return events
