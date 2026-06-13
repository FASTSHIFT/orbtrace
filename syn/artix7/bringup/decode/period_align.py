"""Exploit the periodicity of the short-loop trace to align the board capture
against the LA golden and locate error positions / patterns.

The target runs a tiny loop, so the deframed ETM byte stream repeats. We can:
  * find the loop period via autocorrelation (self-period),
  * lock the board stream to the LA golden on a shared window and walk forward,
    reporting substitution rate + per-bit attribution (which ETM bit flips),
  * fold on the period to see fixed-position vs random deviations.

Subcommands:
  python3 period_align.py <raw.bin>            # self-periods (board + LA)
  python3 period_align.py <raw.bin> xcmp       # lock to LA, bit-attribute errs
  python3 period_align.py <raw.bin> fold       # fold deframed on period
  python3 period_align.py <raw.bin> rawfold    # fold raw bytes, lane-attribute
"""
import sys
import collections
import etm35lib as L
import dsl_parse as D

GOLDEN = "/home/vifex/workpath/orbcode/DSLogic U2Basic-la-260613-194702.dsl"


def deframe_board(path):
    raw = open(path, "rb").read()
    nibs = bytearray()
    for b in raw:
        nibs.append((b >> 4) & 0xf)
        nibs.append(b & 0xf)
    return _align_deframe(nibs)


def deframe_la(n):
    chans, sr, _ = D.load_channels(GOLDEN)
    clk = D.unpack_bits(chans[0], n)
    d = [D.unpack_bits(chans[ch], n) for ch in range(1, 5)]
    edges, half = D.find_edges(clk, n)
    eye = max(1, int(half * 0.5))
    nb = D.sample_nibbles(d, edges, eye)
    return _align_deframe(nb)


def _align_deframe(nibs):
    best = None
    for parity in (0, 1):
        for order in (0, 1):
            data = D.assemble(nibs, parity, order)
            fl = sum(1 for s in L.find_isyncs(data) if L.is_flash(s.addr))
            if best is None or fl > best[0]:
                best = (fl, data)
    data = best[1]
    if L.has_tpiu_sync(data):
        ph, _ = L.find_tpiu_phase(data)
        data = L.tpiu_deframe_hsync(data, ph)
    return data


def find_period(stream, lo=8, hi=4000, scan=20000):
    n = min(len(stream), scan)
    s = stream[:n]
    best = (0.0, 0)
    for lag in range(lo, min(hi, n // 3)):
        m = sum(1 for i in range(n - lag) if s[i] == s[i + lag])
        frac = m / (n - lag)
        if frac > best[0]:
            best = (frac, lag)
    return best


def run_periods(path):
    board = deframe_board(path)
    print("board deframed bytes:", len(board))
    frac, period = find_period(board)
    print(f"board self-period: lag={period} match={100*frac:.1f}%")
    la = deframe_la(4000000)
    fracl, periodl = find_period(la)
    print(f"LA self-period:    lag={periodl} match={100*fracl:.1f}%")


def run_xcmp(path):
    """Lock board to LA on a shared window and walk forward, tolerating small
    insert/delete drift, attributing each substitution to ETM-byte bits."""
    board = deframe_board(path)
    la = deframe_la(4000000)
    W = 24
    lock = None
    for bi in range(0, len(board) - W):
        win = bytes(board[bi:bi + W])
        li = la.find(win)
        if li >= 0:
            lock = (bi, li)
            break
    if lock is None:
        print("no exact lock window found")
        return
    bi, li = lock
    print(f"locked: board[{bi}] == LA[{li}] (window {W}B)")
    bit_err = [0] * 8
    nmis = ncmp = 0
    b, l = bi, li
    examples = []
    while b < len(board) and l < len(la):
        if board[b] == la[l]:
            b += 1
            l += 1
            ncmp += 1
            continue
        relocked = False
        for db in range(6):
            for dl in range(6):
                if (db or dl) and bytes(board[b + db:b + db + 8]) == bytes(la[l + dl:l + dl + 8]):
                    b += db
                    l += dl
                    relocked = True
                    break
            if relocked:
                break
        if relocked:
            continue
        x = board[b] ^ la[l]
        for bit in range(8):
            if (x >> bit) & 1:
                bit_err[bit] += 1
        if len(examples) < 12:
            examples.append((b, l, board[b], la[l], x))
        nmis += 1
        ncmp += 1
        b += 1
        l += 1
    print(f"compared {ncmp} aligned bytes; substitutions={nmis} "
          f"({100*nmis/max(1,ncmp):.2f}%)")
    print("per-bit substitution counts (ETM byte bit):")
    for bit in range(8):
        print(f"  bit{bit}: {bit_err[bit]}")
    print("example mismatches:")
    for b_, l_, bb, lb, x in examples:
        print(f"  board[{b_}]={bb:#04x} la[{l_}]={lb:#04x} xor={x:#04x}")


def run_rawfold(path):
    """Fold the RAW FPGA byte stream and attribute deviations to lanes/edges."""
    raw = open(path, "rb").read()
    frac, period = find_period(raw, lo=8, hi=8000, scan=30000)
    print(f"raw self-period: lag={period} match={100*frac:.1f}%")
    cols = [collections.Counter() for _ in range(period)]
    nrep = len(raw) // period
    for r in range(nrep):
        base = r * period
        for p in range(period):
            cols[p][raw[base + p]] += 1
    dev = total = hot = 0
    bit_dev = [0] * 8
    for p in range(period):
        c = cols[p]
        n = sum(c.values())
        majv, majc = c.most_common(1)[0]
        d = n - majc
        dev += d
        total += n
        if n >= 5 and d / n > 0.15:
            hot += 1
        for v, cnt in c.items():
            x = v ^ majv
            for bit in range(8):
                if (x >> bit) & 1:
                    bit_dev[bit] += cnt
    print(f"raw fold period={period}: repeats={nrep} bytes={total} "
          f"deviations={dev} ({100*dev/max(1,total):.2f}%)")
    print(f"inconsistent positions (>15%): {hot}/{period}")
    labels = ["a/TD0", "a/TD1", "a/TD2", "a/TD3",
              "b/TD0", "b/TD1", "b/TD2", "b/TD3"]
    print("per-bit deviation (lane/edge):")
    for bit in range(8):
        print(f"  bit{bit} {labels[bit]:8s}: {bit_dev[bit]} "
              f"({100*bit_dev[bit]/max(1,total):.2f}%)")


if __name__ == "__main__":
    cmd = sys.argv[2] if len(sys.argv) > 2 else "periods"
    {"periods": run_periods, "xcmp": run_xcmp,
     "rawfold": run_rawfold}.get(cmd, run_periods)(sys.argv[1])
