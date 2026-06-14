"""Unit tests for etm_to_perfetto.build_stack_events — the function-level
call-stack reconstruction that turns (time, function) anchors into nested
Perfetto B/E events (doc 15 §25, the call-relationship view)."""
import pytest

from etm_to_perfetto import build_stack_events, func_for_pc


def be(events):
    """Strip metadata; return [(ph, ts, name?)] for the B/E events only."""
    return [(e["ph"], e["ts"], e.get("name")) for e in events
            if e["ph"] in ("B", "E")]


def assert_balanced(events):
    depth = 0
    for ph, _ts, _ in be(events):
        depth += 1 if ph == "B" else -1
        assert depth >= 0
    assert depth == 0


def test_nested_call_and_return():
    # main runs, calls add (nested), returns to main.
    anchors = [(0, "main"), (100, "add"), (200, "main")]
    events, calls = build_stack_events(anchors, end_ns=300)
    assert_balanced(events)
    assert calls == 2                       # main + add pushed
    seq = be(events)
    # B main, B add, E(add)@200, E(main)@300
    assert seq[0] == ("B", 0.0, "main")
    assert seq[1] == ("B", 0.1, "add")      # ts in us
    assert seq[2][0] == "E" and seq[2][1] == 0.2
    assert seq[3][0] == "E" and seq[3][1] == 0.3


def test_repeated_child_calls_each_close():
    # main -> add, back to main, -> add again: two SEPARATE add frames.
    anchors = [(0, "main"), (100, "add"), (200, "main"),
               (300, "add"), (400, "main")]
    events, calls = build_stack_events(anchors, end_ns=500)
    assert_balanced(events)
    bs = [s for s in be(events) if s[0] == "B"]
    # main once + add twice = 3 pushes
    assert calls == 3
    add_bs = [s for s in bs if s[2] == "add"]
    assert len(add_bs) == 2


def test_same_function_consecutive_no_dup():
    # two anchors in the same function -> one frame, not two.
    anchors = [(0, "loop"), (100, "loop"), (200, "loop")]
    events, calls = build_stack_events(anchors, end_ns=300)
    assert calls == 1
    assert_balanced(events)
    assert len([s for s in be(events) if s[0] == "B"]) == 1


def test_deeper_nesting_pops_multiple():
    # a -> b -> c, then jump straight back to a: pops c and b.
    anchors = [(0, "a"), (10, "b"), (20, "c"), (30, "a")]
    events, calls = build_stack_events(anchors, end_ns=40)
    assert calls == 3
    assert_balanced(events)
    seq = be(events)
    # at ts=30 (0.03us) two E's should fire (c then b) before a stays open
    es_at_30 = [s for s in seq if s[0] == "E" and s[1] == 0.03]
    assert len(es_at_30) == 2


def test_unclosed_frames_closed_at_end():
    anchors = [(0, "a"), (10, "b")]      # never returns
    events, _ = build_stack_events(anchors, end_ns=1000)
    assert_balanced(events)
    es = [s for s in be(events) if s[0] == "E"]
    # both close at end (1000 ns = 1.0 us)
    assert all(s[1] == 1.0 for s in es)


def test_empty_anchors():
    events, calls = build_stack_events([], end_ns=100)
    assert calls == 0
    assert be(events) == []


def test_end_ns_clamped_to_last_anchor():
    # if end_ns is before the last anchor, closing uses the last anchor time.
    anchors = [(0, "a"), (500, "a")]
    events, _ = build_stack_events(anchors, end_ns=100)
    assert_balanced(events)
    es = [s for s in be(events) if s[0] == "E"]
    assert es[-1][1] == 0.5              # 500 ns


def test_func_for_pc_ranges():
    starts = [0x100, 0x200]
    funcs = [(0x100, 0x150, "foo"), (0x200, 0x260, "bar")]
    assert func_for_pc(0x120, starts, funcs) == "foo"
    assert func_for_pc(0x250, starts, funcs) == "bar"
    # gap between functions -> hex bucket
    assert func_for_pc(0x180, starts, funcs).startswith("0x")
