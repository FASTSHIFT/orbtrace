#!/usr/bin/env python3
"""sampling_guard — guard against using the wrong capture method for the
measured TRACECLK, and against drawing conclusions from an IDELAY tap sweep in
a frequency band where IDELAY has no authority.

Why this exists (hard-won): the capture front-end has TWO sampling methods with
DISJOINT valid bands (doc 15 §2):

    method        valid band              dead zone
    ----------    ----------------------  --------------------------------
    OVERSAMPLE    half-bit >= ~15 ns      high freq: edge-detect LOCKOUT fails
                  (TRACECLK <~ 33 MHz)
    IDDR+IDELAY   half-bit <  ~15 ns       LOW freq: IDELAY's ~2.5 ns range is a
                  (TRACECLK >~ 33 MHz)     tiny fraction of the wide half-bit, so
                                           tap sweeps have NO resolving power and
                                           tap-insensitivity means NOTHING.

The recurring mistake this catches: running IDDR at 12 MHz (half-bit 41.7 ns),
sweeping the tap, seeing "fall error flat across all taps", and concluding
"error is phase-independent -> must be CDC". At 12 MHz the 2.5 ns IDELAY only
covers 6% of the half-bit, so of course the tap does nothing -- that flatness
is an ARTIFACT of the dead zone, not evidence about the root cause.

IDELAY_RANGE_NS = 31 taps * ~78 ps ~= 2.4 ns.

Usage as a library:
    from sampling_guard import check
    check(traceclk_hz, cap_method)          # raises/prints
    check(traceclk_hz, cap_method, sweeping_tap=True)

Usage as CLI:
    sampling_guard.py <traceclk_MHz> <IDDR|OVERSAMPLE> [--tap-sweep]
"""
import sys

IDELAY_RANGE_NS = 2.4              # 31 * 78 ps
OVERSAMPLE_MAX_MHZ = 33.0          # half-bit 15 ns
IDDR_MIN_MHZ = 33.0                # below this IDELAY can't move the eye
# require IDELAY range to cover at least this fraction of the half-bit for a
# tap sweep to have any resolving power
MIN_TAP_AUTHORITY = 0.30


def half_bit_ns(traceclk_hz):
    # DDR: one bit per half TRACECLK period
    return 1e9 / (2.0 * traceclk_hz)


def tap_authority(traceclk_hz):
    """Fraction of the half-bit that the full IDELAY range can sweep."""
    return IDELAY_RANGE_NS / half_bit_ns(traceclk_hz)


def check(traceclk_hz, cap_method, sweeping_tap=False, raise_on_error=False):
    """Return (ok, level, msg). level in {'ok','warn','error'}."""
    f_mhz = traceclk_hz / 1e6
    hb = half_bit_ns(traceclk_hz)
    method = cap_method.upper()
    msgs = []
    level = "ok"

    if method == "IDDR":
        if f_mhz < IDDR_MIN_MHZ:
            level = "error"
            msgs.append(
                f"IDDR capture at {f_mhz:.1f} MHz (half-bit {hb:.1f} ns) is in "
                f"the LOW-FREQUENCY DEAD ZONE: below ~{IDDR_MIN_MHZ:.0f} MHz use "
                f"OVERSAMPLE instead. IDDR samples on the clock edge and relies "
                f"on IDELAY to move into the eye, but IDELAY's {IDELAY_RANGE_NS} "
                f"ns range is only {100*tap_authority(traceclk_hz):.0f}% of this "
                f"half-bit.")
        if sweeping_tap:
            auth = tap_authority(traceclk_hz)
            if auth < MIN_TAP_AUTHORITY:
                level = "error" if level != "error" else level
                min_mhz = 1e9 / (2 * IDELAY_RANGE_NS / MIN_TAP_AUTHORITY) / 1e6
                msgs.append(
                    f"IDELAY tap sweep at {f_mhz:.1f} MHz has NO resolving power: "
                    f"the {IDELAY_RANGE_NS} ns range covers only "
                    f"{100*auth:.0f}% of the {hb:.1f} ns half-bit (need "
                    f">={100*MIN_TAP_AUTHORITY:.0f}%). 'tap-insensitive' here is a "
                    f"dead-zone ARTIFACT and says NOTHING about phase vs CDC. "
                    f"To make the tap sweep meaningful, raise TRACECLK to "
                    f">= {min_mhz:.0f} MHz.")
    elif method == "OVERSAMPLE":
        if f_mhz > OVERSAMPLE_MAX_MHZ:
            level = "error"
            msgs.append(
                f"OVERSAMPLE capture at {f_mhz:.1f} MHz (half-bit {hb:.1f} ns) is "
                f"ABOVE its ceiling (~{OVERSAMPLE_MAX_MHZ:.0f} MHz): the edge-"
                f"detect LOCKOUT (20 ns) exceeds the half-bit and eats real "
                f"edges. Use IDDR+IDELAY instead.")
    else:
        level = "warn"
        msgs.append(f"unknown cap_method '{cap_method}'")

    if level == "ok":
        msgs.append(f"OK: {method} at {f_mhz:.1f} MHz (half-bit {hb:.1f} ns).")

    msg = "\n".join(f"  [sampling-guard/{level}] {m}" for m in msgs)
    if level == "error" and raise_on_error:
        raise ValueError(msg)
    return (level == "ok", level, msg)


def main():
    if len(sys.argv) < 3:
        print(__doc__)
        return 2
    f_mhz = float(sys.argv[1])
    method = sys.argv[2]
    sweep = "--tap-sweep" in sys.argv[3:]
    ok, level, msg = check(f_mhz * 1e6, method, sweeping_tap=sweep)
    print(msg)
    return 0 if level != "error" else 1


if __name__ == "__main__":
    sys.exit(main())
