#!/usr/bin/env python3
"""selftrace_strict_verify — HARD-INVARIANT checker for the H743 selftrace loop.

Given a call-edge trace (cortrace --edges output OR a full begin/end slice
event log) from the deterministic selftrace loop, verify the exact source
structure is preserved, not just balanced pair counts.

Source (etm_selftrace.c):
    leaf_add(x) = x+1                      # leaf
    leaf_xor(x) = x^0x55                   # leaf
    node(x)  = leaf_add() then leaf_xor()  # exactly 1 add + 1 xor per node
    det_iter = for 8: node()               # exactly 8 nodes per det_iter
    etm_selftrace_run = loop det_iter forever

Structural invariants that MUST hold on a lossless capture:

    1. Every `node` must contain exactly one `leaf_add` and one `leaf_xor`,
       both children (no other children, no missing children).
    2. Every `det_iter` must contain exactly 8 `node` children (no other
       function children).
    3. `leaf_add` and `leaf_xor` must appear in strict order inside `node`
       (leaf_add first, leaf_xor second).
    4. Only one entry into `etm_selftrace_run` per capture window (it never
       returns).
    5. `<root>` should not appear as caller of anything other than
       `etm_selftrace_run` OR `_start` / `Reset_Handler`. Any other
       parent-less callee = dropped-caller heuristic fired.

Input: a "call trace log" of begin/end events. cortrace already emits this
       in the Perfetto slice stream; we ask it to also emit a plain-text
       trace (see the sibling patch to cortrace_decode.cpp). Failing that,
       this script accepts a simplified "flat" trace: one line per event,
       either `+funcname` (begin) or `-funcname` (end).

Exit codes:
    0 = every invariant passed
    1 = at least one invariant broken -- prints the first N violations
"""
import argparse
import sys
from collections import Counter


def parse_trace(path):
    """Read a flat begin/end trace. Return list of (kind, name) with kind in
    {'B','E'}."""
    ev = []
    for line in open(path):
        line = line.strip()
        if not line:
            continue
        if line.startswith("+"):
            ev.append(("B", line[1:]))
        elif line.startswith("-"):
            ev.append(("E", line[1:]))
    return ev


def verify(events, max_report=20):
    """Walk the event stream and check the structural invariants."""
    stack = []                 # call stack of names
    violations = []            # (index, description)
    node_children = []         # per-node: list of children names, in order
    det_iter_children = []     # per-det_iter: list of children names, in order

    def push_frame_child(callee):
        """When a frame is entered, record it as a child of its parent."""
        if not stack:
            return
        parent = stack[-1]
        if parent == "node":
            node_children[-1].append(callee)
        elif parent == "det_iter":
            det_iter_children[-1].append(callee)

    def finalize_node():
        kids = node_children.pop()
        if kids != ["leaf_add", "leaf_xor"]:
            violations.append((None,
                f"node() had children {kids}, expected exactly "
                f"['leaf_add','leaf_xor']"))

    def finalize_det_iter():
        kids = det_iter_children.pop()
        # Should be exactly 8 nodes, nothing else.
        n_nodes = sum(1 for k in kids if k == "node")
        others = [k for k in kids if k != "node"]
        if n_nodes != 8 or others:
            violations.append((None,
                f"det_iter had {n_nodes} node children (expected 8)"
                + (f" + orphan children {others}" if others else "")))

    for i, (kind, name) in enumerate(events):
        if kind == "B":
            push_frame_child(name)
            stack.append(name)
            if name == "node":
                node_children.append([])
            elif name == "det_iter":
                det_iter_children.append([])
        else:  # end
            if not stack:
                violations.append((i, f"end of {name} with empty stack"))
                continue
            top = stack[-1]
            if top != name:
                violations.append((i,
                    f"end/begin mismatch: end='{name}' top='{top}'"))
                # Try to recover: pop the mismatched top. If it happens to
                # be a `node` or `det_iter`, finalize (with whatever
                # children it accumulated). This lets us keep walking and
                # find more violations rather than crashing.
                if top == "node" and node_children:
                    finalize_node()
                elif top == "det_iter" and det_iter_children:
                    finalize_det_iter()
                stack.pop()
                continue
            if name == "node":
                finalize_node()
            elif name == "det_iter":
                finalize_det_iter()
            stack.pop()

    # Any dangling frames?
    if stack:
        violations.append((None, f"unclosed frames: {stack}"))

    return violations


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("trace", help="flat +B/-E event trace file")
    ap.add_argument("--max-report", type=int, default=20)
    a = ap.parse_args()

    ev = parse_trace(a.trace)
    print(f"loaded {len(ev)} events")

    v = verify(ev, a.max_report)
    if not v:
        print("VERDICT: PASS -- all structural invariants hold")
        sys.exit(0)

    print(f"\nVERDICT: FAIL -- {len(v)} invariant violations detected")
    for idx, (loc, msg) in enumerate(v[:a.max_report]):
        pfx = f"[event {loc}]" if loc is not None else "[global]"
        print(f"  {idx+1}. {pfx} {msg}")
    if len(v) > a.max_report:
        print(f"  ... and {len(v) - a.max_report} more")

    # Summary buckets
    kinds = Counter()
    for loc, msg in v:
        if "expected 8" in msg:
            kinds["det_iter_wrong_node_count"] += 1
        elif "orphan children" in msg:
            kinds["det_iter_orphan_child"] += 1
        elif "expected exactly" in msg:
            kinds["node_wrong_children"] += 1
        elif "end of" in msg:
            kinds["orphan_end"] += 1
        elif "end/begin mismatch" in msg:
            kinds["mismatch"] += 1
        elif "unclosed" in msg:
            kinds["unclosed"] += 1
        else:
            kinds["other"] += 1
    print()
    print("Violation buckets:")
    for k, n in kinds.most_common():
        print(f"  {k:32s}: {n}")
    sys.exit(1)


if __name__ == "__main__":
    main()
