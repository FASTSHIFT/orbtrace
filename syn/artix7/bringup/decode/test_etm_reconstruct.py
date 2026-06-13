"""Tests for etm_reconstruct — step-① per-instruction reconstruction.

The image-walk tests are self-contained (a tiny hand-built instruction map),
so they run without an ELF/toolchain. The integration test against the
committed proj_add ground-truth fixture is skipped if arm-none-eabi-objdump or
the ELF is unavailable.
"""
import os
import shutil

import pytest

import etm35lib as L
import etm_reconstruct as R


HERE = os.path.dirname(__file__)
PROJ_ADD_FIXTURE = os.path.join(HERE, "captures", "proj_add_ground_truth.bin")
PROJ_ADD_ELF = "/tmp/axf/proj_add.axf"


# ----------------------------------------------------------------------------
# _classify_insn: direct vs indirect vs other
# ----------------------------------------------------------------------------
@pytest.mark.parametrize("mnem,ops,kind", [
    ("bl", "8000f8c <_Z3addii>", "direct"),
    ("b.n", "8000fba", "direct"),
    ("blt.n", "8000fae <_Z8loop_sumi+0xa>", "direct"),
    ("cbz", "r0, 8000fc0", "direct"),
    ("bx", "lr", "indirect"),
    ("blx", "r3", "indirect"),
    ("pop", "{r4, r5, pc}", "indirect"),
    ("ldr", "pc, [r3]", "indirect"),
    ("mov", "r2, r0", "other"),
    ("adds", "r0, r2, r1", "other"),
    ("nop", "", "other"),
])
def test_classify_insn(mnem, ops, kind):
    k, _ = R._classify_insn(mnem, ops)
    assert k == kind


def test_classify_direct_branch_target_extracted():
    k, tgt = R._classify_insn("bl", "8000f8c <_Z3addii>")
    assert k == "direct"
    assert tgt == 0x08000F8C


# ----------------------------------------------------------------------------
# reconstruct_region against a hand-built image (no toolchain needed).
# Image models add(): mov; adds; bx lr  at 0x1000.
# ----------------------------------------------------------------------------
def _mk(addr, size, mnem, ops):
    kind, tgt = R._classify_insn(mnem, ops)
    return R.Insn(addr, size, mnem, ops, kind, tgt)


def test_reconstruct_straight_line_then_indirect():
    base = 0x08001000
    img = {
        0x08001000: _mk(0x08001000, 2, "mov", "r2, r0"),
        0x08001002: _mk(0x08001002, 2, "adds", "r0, r2, r1"),
        0x08001004: _mk(0x08001004, 2, "bx", "lr"),
    }
    # P-header EEE (Format-1, 3 E) executes the three instructions; the bx lr
    # is indirect so it consumes a 1-byte branch packet pointing back to base.
    phdr = 0x80 | (3 << 2)                       # 0x8C: EEE
    br = 0x01 | (((base >> 1) & 0x3F) << 1)      # 1-byte branch to base low bits
    data = bytes([phdr, br])
    addrs, consumed, reason = R.reconstruct_region(data, 0, base, img)
    assert addrs[:3] == [0x08001000, 0x08001002, 0x08001004]
    # indirect bx consumed the branch byte
    assert consumed == 2


def test_reconstruct_direct_branch_taken_and_fallthrough():
    # 0x2000: cbz r0, 0x2006 ; 0x2002: movs ; 0x2004: b 0x2000 ; 0x2006: nop
    img = {
        0x08002000: _mk(0x08002000, 2, "cbz", "r0, 8002006"),
        0x08002002: _mk(0x08002002, 2, "movs", "r1, #0"),
        0x08002004: _mk(0x08002004, 2, "b.n", "8002000"),
        0x08002006: _mk(0x08002006, 2, "nop", ""),
    }
    # Format-2 NE: first atom N (cbz fails its cond -> fall through),
    # second atom E (movs executes). 0x8A = NE.
    data = bytes([0x8A])
    addrs, _, _ = R.reconstruct_region(data, 0, 0x08002000, img)
    assert addrs == [0x08002000, 0x08002002]

    # Now cbz taken: Format-1 single E -> cbz E jumps to 0x2006.
    data2 = bytes([0x84])                        # one E
    addrs2, _, _ = R.reconstruct_region(data2, 0, 0x08002000, img)
    assert addrs2 == [0x08002000]                # next PC would be 0x2006


def test_reconstruct_stops_outside_image():
    img = {0x08003000: _mk(0x08003000, 2, "movs", "r0, #0")}
    data = bytes([0x88])                         # EE: 2 instructions
    addrs, _, reason = R.reconstruct_region(data, 0, 0x08003000, img)
    assert addrs == [0x08003000]                 # first ok, second PC missing
    assert "not in image" in reason


# ----------------------------------------------------------------------------
# Integration: proj_add committed fixture (skipped without toolchain/ELF).
# ----------------------------------------------------------------------------
@pytest.mark.skipif(not os.path.exists(PROJ_ADD_FIXTURE),
                    reason="proj_add fixture absent")
@pytest.mark.skipif(shutil.which(R.OBJDUMP) is None
                    or not os.path.exists(PROJ_ADD_ELF),
                    reason="arm-none-eabi-objdump or proj_add.axf absent")
def test_proj_add_reconstruction_matches_source():
    data = open(PROJ_ADD_FIXTURE, "rb").read()
    img = R.load_image(PROJ_ADD_ELF)
    regions = R.reconstruct_all(data, img)

    flat = [a for _, addrs, _ in regions for a in addrs]
    # add()'s exact instruction triplet must appear in order somewhere.
    ADD = [0x08000F8C, 0x08000F8E, 0x08000F90]   # mov; adds; bx lr
    joined = flat
    found_triplet = any(joined[k:k + 3] == ADD
                        for k in range(len(joined) - 2))
    assert found_triplet, "add() instruction triplet not reconstructed"

    # The reconstructed add() entry address must resolve into the add function.
    assert 0x08000F8C in flat
    # loop_sum's bl-add and blt back-edge must both be present.
    assert 0x08000FB2 in flat      # bl add
    assert 0x08000FBC in flat      # blt.n loop back-edge


# ----------------------------------------------------------------------------
# Indirect branch consumes a Branch Address packet from the stream.
# ----------------------------------------------------------------------------
def test_reconstruct_indirect_uses_branch_packet_target():
    # add(): mov; adds; bx lr.  bx lr is indirect -> its target is read from
    # the following branch-address packet (a return to the call site).
    img = {
        0x08000F8C: _mk(0x08000F8C, 2, "mov", "r2, r0"),
        0x08000F8E: _mk(0x08000F8E, 2, "adds", "r0, r2, r1"),
        0x08000F90: _mk(0x08000F90, 2, "bx", "lr"),
        # return site:
        0x08000FB6: _mk(0x08000FB6, 2, "add", "r5, r0"),
    }
    ret = 0x08000FB6
    phdr = 0x80 | (3 << 2)                        # EEE: 3 instructions
    # 2-byte branch packet encoding ret (low 14 bits suffice from prev 0x8000f8c)
    b1 = 0x80 | 0x01 | (((ret >> 1) & 0x3F) << 1)
    b2 = (ret >> 7) & 0x7F
    data = bytes([phdr, b1, b2])
    addrs, consumed, reason = R.reconstruct_region(data, 0, 0x08000F8C, img)
    assert addrs == [0x08000F8C, 0x08000F8E, 0x08000F90]
    assert consumed == 3                          # phdr + 2 branch bytes
    assert reason == "ok"


def test_reconstruct_indirect_without_branch_packet_stops():
    img = {0x08001000: _mk(0x08001000, 2, "bx", "lr")}
    data = bytes([0x84])                          # one E -> execute bx lr
    addrs, _, reason = R.reconstruct_region(data, 0, 0x08001000, img)
    assert addrs == [0x08001000]
    assert "w/o branch pkt" in reason


def test_reconstruct_standalone_branch_packet_realigns_pc():
    # A bare branch-address packet (not preceded by a P-header) repositions PC.
    # A 1-byte packet only carries Address[6:1], so the target must share its
    # high bits with prev_branch; pick a target near the anchor.
    base = 0x08002000
    target = 0x08002010                           # differs only in low bits
    img = {target: _mk(target, 2, "nop", "")}
    b = 0x01 | (((target >> 1) & 0x3F) << 1)       # 1-byte branch to target
    # follow with a single-E phdr to execute one nop at the new PC
    data = bytes([b, 0x84])
    addrs, _, _ = R.reconstruct_region(data, 0, base, img)
    assert addrs == [target]


def test_reconstruct_isync_reanchor_midstream():
    img = {0x08003000: _mk(0x08003000, 2, "nop", "")}
    # I-sync packet anchoring 0x08003000, then EE executes the nop.
    isync = bytes([0x08, 0x00]) + (0x08003000 | 1).to_bytes(4, "little")
    data = isync + bytes([0x84])
    addrs, _, _ = R.reconstruct_region(data, 0, 0x08000000, img)
    assert 0x08003000 in addrs


def test_next_branch_skips_interleaved_packets():
    # _next_branch tolerates trigger/ignore packets before the address byte.
    prev = 0x08000000
    target = 0x08000040
    b = 0x01 | (((target >> 1) & 0x3F) << 1)
    data = bytes([0x0C, 0x66, b])                 # trigger, ignore, then branch
    res = R._next_branch(data, 0, len(data), prev)
    assert res is not None
    tgt, adv = res
    assert tgt == target
    assert adv == 3                               # skipped 2 + 1 branch byte
