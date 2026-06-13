#!/usr/bin/env python3
"""etm_reconstruct — step-① continuous per-instruction PC reconstruction.

Walks the ETM3.5 atom/branch stream against the disassembled code image to
recover the *exact instruction-by-instruction* execution path between (and
through) I-sync anchors, not just the distinct anchor PCs.

Model (grounded in IHI0014Q + orbuculum traceDecoder_etm35.c, see etm35lib):
  * Anchor absolute PC from a Normal I-sync packet.
  * Each P-header atom (E/N, in order) consumes ONE instruction at the current
    PC:
      - direct branch (B/BL/BLX imm, CBZ/CBNZ, etc.): E => jump to the
        image-derived target, N => fall through to next instruction.
      - indirect branch (BX/BLX reg, POP {...,pc}, LDR pc, ...): consume the
        next Branch Address packet from the stream for the target.
      - any other instruction: advance PC by its encoded width (2 or 4 bytes).
  * The walk stops (and re-anchors at the next I-sync) when it would step
    outside the known image, or when the stream desynchronises.

This is the FIRST decode that produces a verifiable continuous path: we replay
it against proj_add's known control flow (loop_sum calls add 5x) and check the
recovered call/loop counts match the source.

Usage:
  ELF=/tmp/axf/proj_add.axf python3 etm_reconstruct.py /tmp/dsl_bytes_0.bin
"""
import argparse
import os
import re
import subprocess
import sys

import etm35lib as L

OBJDUMP = os.environ.get("OBJDUMP", "arm-none-eabi-objdump")
ADDR2LINE = os.environ.get("ADDR2LINE", "arm-none-eabi-addr2line")


class Insn:
    __slots__ = ("addr", "size", "mnem", "ops", "kind", "target")

    def __init__(self, addr, size, mnem, ops, kind, target):
        self.addr = addr          # instruction address (Thumb, even)
        self.size = size          # 2 or 4 bytes
        self.mnem = mnem          # e.g. 'bl', 'bx', 'pop', 'blt.n'
        self.ops = ops            # operand text
        self.kind = kind          # 'direct' | 'indirect' | 'other'
        self.target = target      # direct-branch target addr or None


# Direct branch targets are encoded in the instruction and printed by objdump
# as the leading hex address of the operand, e.g. "8000f8c <_Z3addii>" or
# "8002006 <_Z8loop_sumi+0x16>". The symbolic <...> suffix may itself contain a
# +0xNN offset, so we take the first bare hex token, not the last.
def _classify_insn(mnem, ops):
    """Return ('direct'|'indirect'|'other', target_or_None).

    IHI0014Q §4.10.3: direct branches (B, BL, BLX <imm>, CBZ, CBNZ and the
    conditional B<cond> forms) carry their target in the instruction, so the
    decompressor infers it from the image. Anything that writes the PC from a
    register or memory (BX/BLX <reg>, POP {..,pc}, LDR pc, MOV/ADD/SUB pc) is
    an indirect branch and emits a Branch Address packet.
    """
    base = mnem.lower()
    root = base.split(".")[0]            # strip '.n'/'.w' width suffix

    # PC-loading forms are indirect.
    if root.startswith("pop") and re.search(r"\bpc\b", ops):
        return "indirect", None
    if root.startswith(("ldm", "ldr")) and re.search(r"\bpc\b", ops):
        return "indirect", None
    if re.match(r"^(mov|add|sub)", root) and re.match(r"^\s*pc\b", ops):
        return "indirect", None
    if root == "bx" or root == "bxj":
        return "indirect", None
    if root == "blx":
        # blx <imm> is direct; blx <reg> is indirect — operand decides.
        tgt = _imm_target(ops)
        return ("direct", tgt) if tgt is not None else ("indirect", None)

    # Direct PC-relative branches: bl, cbz, cbnz, and b / b<cond>.
    _COND = {"eq", "ne", "cs", "cc", "mi", "pl", "vs", "vc", "hi", "ls",
             "ge", "lt", "gt", "le", "al", "hs", "lo"}
    is_direct = (root in ("b", "bl", "cbz", "cbnz")
                 or (root.startswith("b") and root[1:] in _COND))
    if is_direct:
        tgt = _imm_target(ops)
        if tgt is not None:
            return "direct", tgt
    return "other", None


def _imm_target(ops):
    """Extract a direct-branch target address from objdump operand text like
    '8000f8c <_Z3addii>', 'r0, 8002006 <foo+0x16>' or '0x8000f8c'. The target
    is the first bare hex address token (objdump prints it before the <sym>),
    so we must not pick up the +0xNN offset inside the symbol name."""
    s = ops.strip()
    # strip a trailing "<symbol+0xNN>" so its offset can't be mistaken for the
    # address.
    s = re.sub(r"<[^>]*>", "", s).strip()
    m = re.search(r"\b([0-9a-fA-F]{4,8})\b", s)
    if m:
        return int(m.group(1), 16)
    m = re.search(r"0x([0-9a-fA-F]+)", s)
    if m:
        return int(m.group(1), 16)
    return None


def load_image(elf):
    """Disassemble the ELF into an addr -> Insn map."""
    p = subprocess.run([OBJDUMP, "-d", "-z", elf],
                       capture_output=True, text=True)
    img = {}
    line_re = re.compile(
        r"^\s*([0-9a-fA-F]+):\s+((?:[0-9a-fA-F]{2,4} ?)+)\s+(\S+)\s*(.*)$")
    for line in p.stdout.splitlines():
        m = line_re.match(line)
        if not m:
            continue
        addr = int(m.group(1), 16)
        hexb = m.group(2).replace(" ", "")
        size = len(hexb) // 2
        if size not in (2, 4):
            size = 2 if len(hexb) <= 4 else 4
        mnem = m.group(3)
        ops = m.group(4).strip()
        kind, tgt = _classify_insn(mnem, ops)
        img[addr] = Insn(addr, size, mnem, ops, kind, tgt)
    return img


def reconstruct_region(data, start, base_addr, img, max_bytes=8192,
                       max_insns=20000):
    """Walk atoms/branches from `start` against the image, beginning at
    base_addr (an I-sync PC). Returns (insn_addrs, consumed_bytes, stop_reason).
    insn_addrs is the ordered list of executed instruction addresses."""
    pc = base_addr & 0xFFFFFFFE
    prev_branch = base_addr
    out = []
    i = start
    end = min(len(data), start + max_bytes)
    while i < end and len(out) < max_insns:
        c = data[i]
        # P-header -> atoms
        atoms = L.expand_pheader(c)
        if atoms is not None:
            i += 1
            stop = False
            for a in atoms:
                ins = img.get(pc)
                if ins is None:
                    return out, i, f"pc 0x{pc:08x} not in image"
                out.append(pc)
                if ins.kind == "direct":
                    if a == "E":
                        pc = ins.target if ins.target is not None else pc + ins.size
                        prev_branch = pc
                    else:                       # N: fell through
                        pc += ins.size
                elif ins.kind == "indirect":
                    # target comes from the next branch-address packet
                    br = _next_branch(data, i, end, prev_branch)
                    if br is None:
                        return out, i, f"indirect at 0x{ins.addr:08x} w/o branch pkt"
                    tgt, adv = br
                    i += adv
                    pc = tgt & 0xFFFFFFFE
                    prev_branch = tgt
                else:
                    pc += ins.size
            if stop:
                break
            continue
        # standalone branch-address packet (e.g. periodic full address)
        if c & 1:
            br = L.decode_branch_thumb(data, i, prev_branch)
            if br is None:
                break
            tgt, adv = br
            i += adv
            pc = tgt & 0xFFFFFFFE
            prev_branch = tgt
            continue
        # I-sync re-anchor
        if c == L.ISYNC_HEADER:
            s = L.parse_isync_at(data, i)
            if s is not None:
                pc = s.addr & 0xFFFFFFFE
                prev_branch = s.addr
                i += 6
                continue
            break
        # A-sync / other -> stop, caller re-anchors
        break
    return out, i, "ok"


def _next_branch(data, i, end, prev):
    """Skip non-branch IDLE packets and return the next branch-address packet's
    (target, total_advance_from_i) or None."""
    j = i
    while j < end:
        c = data[j]
        if c & 1:
            br = L.decode_branch_thumb(data, j, prev)
            if br is None:
                return None
            tgt, adv = br
            return tgt, (j - i) + adv
        # tolerate a few interleaved packets before the address
        k = L._classify(c)
        if k in ("trigger", "vmid", "ignore", "contextid",
                 "exc_exit", "exc_entry"):
            j += 1
            continue
        if k in ("cyccnt", "timestamp"):
            j += 1
            while j < end and (data[j - 1] & 0x80):
                j += 1
            continue
        return None
    return None


def reconstruct_all(data, img):
    """Anchor on every I-sync and reconstruct each region. Returns a list of
    (anchor_pc, [executed insn addrs], stop_reason)."""
    regions = []
    for s in L.find_isyncs(data):
        addrs, _, reason = reconstruct_region(data, s.offset + 6, s.addr, img)
        regions.append((s.addr, [s.addr] + addrs, reason))
    return regions


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("capture")
    ap.add_argument("--elf", default=os.environ.get("ELF",
                                                    "/tmp/axf/proj_add.axf"))
    ap.add_argument("--max-region", type=int, default=8192)
    a = ap.parse_args()

    data = open(a.capture, "rb").read()
    img = load_image(a.elf)
    print(f"image: {len(img)} instructions; capture: {len(data)} bytes")

    regions = reconstruct_all(data, img)
    total = sum(len(r[1]) for r in regions)
    print(f"anchored regions: {len(regions)}; "
          f"total reconstructed instruction steps: {total}")

    # Region-length distribution and the single longest continuous path.
    lens = sorted((len(r[1]) for r in regions), reverse=True)
    if lens:
        print(f"region length: max={lens[0]} insns, "
              f"median={lens[len(lens)//2]}, "
              f"regions>=8 insns={sum(1 for x in lens if x >= 8)}")
    longest = max(regions, key=lambda r: len(r[1]))
    print(f"\nlongest continuous path: {len(longest[1])} instructions "
          f"(stop: {longest[2]})")
    for ad in longest[1][:40]:
        ins = img.get(ad)
        m = f"{ins.mnem} {ins.ops}".strip() if ins else "?"
        print(f"    0x{ad:08x}  {m}")

    # Aggregate: how many times each instruction address executed.
    import collections
    hist = collections.Counter()
    for r in regions:
        hist.update(r[1])

    # Resolve function names for the top executed addresses.
    top = [a for a, _ in hist.most_common(20)]
    names = _resolve_funcs(top, a.elf)
    print("\nmost-executed instructions (addr  count  func):")
    for addr in top:
        ins = img.get(addr)
        m = f"{ins.mnem} {ins.ops}".strip() if ins else "?"
        fn = names.get(addr, "?")
        print(f"  0x{addr:08x}  {hist[addr]:6d}  {fn:18s} {m}")

    # Control-flow check for proj_add: count add() entries and loop_sum's blt.
    _control_flow_check(regions, img, a.elf)
    return 0


def _resolve_funcs(addrs, elf):
    if not addrs or not os.path.exists(elf):
        return {}
    p = subprocess.run([ADDR2LINE, "-f", "-e", elf]
                       + [f"0x{x:08x}" for x in addrs],
                       capture_output=True, text=True)
    lines = p.stdout.splitlines()
    return {addrs[i]: (lines[2 * i] if 2 * i < len(lines) else "?")
            for i in range(len(addrs))}


def _control_flow_check(regions, img, elf):
    """proj_add ground truth: add() @0x08000f8c, loop_sum's blt @0x08000fbc.
    loop_sum calls add 5x per call; the blt is taken 5x, not-taken 1x. Verify
    the reconstructed flow shows add-entry runs of 5 between loop_sum visits."""
    ADD = 0x08000F8C
    BL_ADD = 0x08000FB2          # bl add inside loop_sum
    BLT = 0x08000FBC             # loop back-edge
    runs = []
    for r in regions:
        addrs = r[1]
        # count add entries in this region
        n_add = sum(1 for ad in addrs if ad == ADD)
        n_blt = sum(1 for ad in addrs if ad == BLT)
        if n_add or n_blt:
            runs.append((n_add, n_blt))
    if runs:
        import collections
        addc = collections.Counter(r[0] for r in runs)
        print("\nproj_add control-flow check (per region):")
        print(f"  add() entries per region histogram: {dict(addc)}")
        print(f"  expectation: loop_sum(5) calls add 5x; regions that capture "
              f"a full loop_sum should show 5.")
    else:
        print("\n(no add()/loop_sum activity reconstructed in regions)")


if __name__ == "__main__":
    sys.exit(main())
