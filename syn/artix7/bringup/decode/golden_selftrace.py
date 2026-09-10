#!/usr/bin/env python3
"""golden_selftrace — derive the EXACT ETMv4 element sequence one det_iter()
call produces, straight from the disassembly. No hardware, no capture: this is
the independent golden reference to break the "FPGA says fine / decoder says
fine" deadlock.

Control flow (from build/H743_Blink.elf disassembly, -O0):

  det_iter(seed):                      # 0x8011474
     b.n   L_cond                      # skip to condition first (for-loop)
   L_body:                             # 0x8011486
     bl    node                        # 0x8011488  -> CALL node
   L_inc:  i++
   L_cond:                             # 0x8011494
     cmp   i,#7
     ble.n L_body                      # 0x8011498  -> COND branch (taken x8, not-taken x1)
     pop   {r7,pc}                     # 0x80114a2  -> RETURN

  node(x):                             # 0x8011452
     bl    leaf_add                    # 0x801145c  -> CALL
     bl    leaf_xor                    # 0x8011464  -> CALL
     pop   {r7,pc}                     # 0x8011472  -> RETURN

  leaf_add(x): ... bx lr               # 0x8011436  -> RETURN  (straight line)
  leaf_xor(x): ... bx lr               # 0x8011450  -> RETURN  (straight line)

The loop runs the body for i=0..7 (8 times, ble taken), then i=8 fails ble
(not-taken) and returns.

ETMv4 with BranchBroadcast=1: every taken branch/call/return emits an ATOM
(E=taken/N=not-taken) PLUS, for indirect branches (bx lr / pop pc) and when BB
is on for direct branches too, an ADDRESS packet with the target. Conditional
direct branches emit E/N atoms. The element-level (post-decode) truth is a
sequence of INSTR_RANGE (a straight run of instructions) separated by these
branch points. That element sequence is what we compare against the decoder
output — it is unambiguous from the control flow and does NOT depend on ETM
byte encoding details.
"""

# Addresses of the instruction ranges and their exit branch kind, for ONE full
# det_iter() call. We model the ELEMENT sequence the decoder must emit:
#   ('RANGE', start, end_incl_last_instr, exit_kind)
# exit_kind in {CALL, RET, COND_T, COND_N, DIR}
#
# One node() call expands to:
#   node entry .. bl leaf_add          -> CALL leaf_add
#   leaf_add body .. bx lr             -> RET to node
#   node .. bl leaf_xor                -> CALL leaf_xor
#   leaf_xor body .. bx lr             -> RET to node
#   node .. pop {pc}                   -> RET to det_iter
def node_elements():
    return [
        ("node.a", 0x8011452, 0x801145c, "CALL"),     # -> leaf_add
        ("leaf_add", 0x8011420, 0x8011436, "RET"),    # -> back to node
        ("node.b", 0x8011460, 0x8011464, "CALL"),     # -> leaf_xor
        ("leaf_xor", 0x8011438, 0x8011450, "RET"),    # -> back to node
        ("node.c", 0x8011468, 0x8011472, "RET"),      # -> back to det_iter
    ]


def det_iter_elements():
    seq = []
    # entry: b.n to cond
    seq.append(("det.entry", 0x8011474, 0x8011484, "DIR"))   # b.n L_cond
    for i in range(8):                     # i=0..7 : ble taken -> run body
        seq.append(("det.cond_t", 0x8011494, 0x8011498, "COND_T"))
        seq += node_elements()
        seq.append(("det.inc", 0x8011486, 0x8011492, "DIR"))  # body->inc->cond falls through
    # i=8 : ble NOT taken -> return
    seq.append(("det.cond_n", 0x8011494, 0x8011498, "COND_N"))
    seq.append(("det.ret", 0x801149a, 0x80114a2, "RET"))
    return seq


def summarize(seq):
    from collections import Counter
    kinds = Counter(k for _, _, _, k in seq)
    atoms = []
    for _, _, _, k in seq:
        if k == "COND_T":
            atoms.append("E")
        elif k == "COND_N":
            atoms.append("N")
        elif k in ("CALL", "RET", "DIR"):
            # direct branches/calls/returns are 'E' atoms (always taken) in the
            # atom stream; BB adds an address packet but the atom is E.
            atoms.append("E")
    return kinds, "".join(atoms)


if __name__ == "__main__":
    seq = det_iter_elements()
    kinds, atomstr = summarize(seq)
    print(f"elements per det_iter(): {len(seq)}")
    print(f"  kind counts: {dict(kinds)}")
    print(f"  branch/atom count: {len(atomstr)}")
    print(f"  atom string (E=taken,N=not): {atomstr}")
    print(f"  # calls (bl): {kinds['CALL']}  # returns: {kinds['RET']}  "
          f"# cond: {kinds['COND_T']+kinds['COND_N']}")
    print()
    print("Per det_iter: 8x node, each node = 2 calls + 3 returns (incl its own),")
    print("plus det_iter's 1 entry-dir + 8 cond-taken + 1 cond-not + 1 return.")
    print("This is the exact element sequence the decoder MUST reproduce; any")
    print("deviation localises the fault.")
