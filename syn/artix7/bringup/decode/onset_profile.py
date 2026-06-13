"""Show the unknown-byte density profile (deciles) of one or more board
captures' deframed streams — to reveal a clean-then-dirty onset (capture-FSM /
buffer-progress fault) vs uniform errors (SI / metastability)."""
import sys
import etm35lib as L
import period_align as P


def main():
    for f in sys.argv[1:]:
        board = P.deframe_board(f)
        n = len(board)
        if n < 10:
            print(f"{f}: too short")
            continue
        dec = n // 10
        dens = []
        for k in range(10):
            seg = board[k * dec:(k + 1) * dec]
            u = sum(1 for c in seg if L._classify(c) == "unknown")
            dens.append(100 * u / max(1, len(seg)))
        name = f.split("/")[-1]
        prof = " ".join("%4.0f" % d for d in dens)
        print(f"{name:26s} decile%: {prof}")


if __name__ == "__main__":
    main()
