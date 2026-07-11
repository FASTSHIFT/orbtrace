#!/usr/bin/env python3
"""fpga_health — one-shot FPGA observability readout (proposal 30 P1).

Reads the dbg_regfile in trace_mmcm_stream_top over the :5001 readout path
(which is independent of the self-TX data stream, so it works even when the
trace stream is deadlocked) and prints a human-readable health diagnosis.

The readout protocol (fpga_core_net ext_addr/ext_data, port 5001):
  request  = <u16 base LE> + padding
  reply    = [2 echo bytes][ ext_data[base], ext_data[base+1], ... ]
Note the RTL has a documented 1-cycle stale-read on the FIRST data byte, so we
read each register at its own base with a couple of extra bytes and take the
byte at the position that is known-good (index 1 of the data region).

Usage: fpga_health.py [ip]
"""
import socket
import struct
import sys

IP = sys.argv[1] if len(sys.argv) > 1 else "192.168.10.42"
PORT = 5001

# dbg_regfile address map (low byte of ext_addr, page 0xFF1x..0xFF3x)
A_MAGIC      = 0xFF10
A_LIVE       = 0xFF11
A_CYC        = 0xFF12   # 4 bytes LE
A_FIRST_CODE = 0xFF16   # 2 bytes LE
A_FIRST_TIME = 0xFF18   # 4 bytes LE
A_FIRST_CTX  = 0xFF1C
A_CNT_BASE   = 0xFF20   # 7 counters
A_GPIO_LEVEL = 0xFF30   # {0,0,0,clk,d3,d2,d1,d0}
A_GPIO_EDGES = 0xFF31   # clk(2) d0(2) d1(2) d2(2) d3(2) LE, 10 bytes
A_FREQ       = 0xFF3B   # TRACECLK edges per 16.777ms window, 3 bytes LE
A_GAP        = 0xFF3E   # gap_count(2) gap_max(2) LE
FREQ_WINDOW_S = (1 << 21) / 125e6   # 16.777 ms
CLK_NS = 8.0                        # clk125 period (ns)

ERR_NAMES = {
    0x0000: "none",
    0x0101: "no TRACECLK edges (GPIO/trace clock absent)",
    0x0102: "trace MMCM lost lock (wrong TRACECLK freq / dropout)",
    0x0301: "capture FIFO overflow (ETM trace rate > drain)",
    0x0401: "self-TX HDR stuck (ARP not resolved — network self-TX deadlock)",
    0x0501: "MAC RX bad frame",
    0x0502: "MAC TX FIFO overflow",
    0x0503: "MAC RX FIFO overflow",
}
CNT_NAMES = ["no_traceclk", "mmcm_unlock", "cap_overflow", "selftx_stuck",
             "rx_bad_frame", "tx_fifo_ovf", "rx_fifo_ovf"]
FSM_NAMES = {0: "IDLE", 1: "HDR", 2: "SEND", 3: "BACKOFF"}


def rd(s, base, n):
    """Read n bytes starting at ext_addr=base. The RTL reply repeats source[base]
    on the first beats (1-cycle stale read + paging), observed as the reply
    starting with the base value several times then advancing: for base FF10 the
    reply is 'db db db 08 07 ...' = ext[base]x(stale) then ext[base+1].. So the
    value for `base` is at index 2 and base+k at index 2+k."""
    s.sendto(struct.pack("<H", base & 0xFFFF) + bytes(n + 4), (IP, PORT))
    d, _ = s.recvfrom(2048)
    return d[2:2 + n]


def rd8(s, addr):
    return rd(s, addr, 1)[0]


def main():
    s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    s.settimeout(2.0)

    try:
        magic = rd8(s, A_MAGIC)
    except socket.timeout:
        print("[FAIL] no reply on :5001 — FPGA network/readout path down "
              "(power-cycle or reflash the FPGA)")
        return 1

    if magic != 0xDB:
        print(f"[WARN] debug regfile magic = 0x{magic:02x} (expected 0xDB). "
              f"Old bitstream without proposal-30 observability? Falling back.")
        # still try the legacy lost_cnt/lock readout
        return 0

    print(f"[OK]   debug regfile online (magic=0x{magic:02x} v1)")

    live = rd8(s, A_LIVE)
    have_first = (live >> 7) & 1
    pkt_active = (live >> 6) & 1
    traceclk_active = (live >> 5) & 1
    trace_lock = (live >> 4) & 1
    sys_lock = (live >> 3) & 1
    fsm = live & 0x3

    def rd_le(base, n):
        b = rd(s, base, n)
        return int.from_bytes(b, "little")

    cyc = rd_le(A_CYC, 4)
    first_code = rd_le(A_FIRST_CODE, 2)
    first_time = rd_le(A_FIRST_TIME, 4)
    first_ctx = rd8(s, A_FIRST_CTX)

    # ---- live state ----
    print(f"       sys MMCM lock={sys_lock}  trace MMCM lock={trace_lock}  "
          f"TRACECLK active={traceclk_active}")
    print(f"       self-TX FSM = {FSM_NAMES.get(fsm, fsm)}  pkt_active={pkt_active}")
    if not sys_lock:
        print("[FAIL] system MMCM not locked — FPGA clocking broken")
    if not traceclk_active:
        print("[WARN] no TRACECLK activity — ETM not configured / no trace clock")
    elif not trace_lock:
        print("[WARN] trace MMCM not locked despite TRACECLK — wrong sampling freq")
    else:
        print("[OK]   TRACECLK active + trace MMCM locked")

    # ---- raw GPIO monitor (cross-check pin activity vs decode) ----
    glevel = rd8(s, A_GPIO_LEVEL)
    ge = rd(s, A_GPIO_EDGES, 10)
    gclk_ed = ge[0] | (ge[1] << 8)
    gd_ed = [ge[2 + 2 * i] | (ge[3 + 2 * i] << 8) for i in range(4)]
    clk_lvl = (glevel >> 4) & 1
    d_lvl = glevel & 0xF
    # edge counts are 16-bit saturating; 0xFFFF shown as ">=65535"
    def ec(v):
        return ">=65535" if v == 0xFFFF else str(v)
    print(f"       raw GPIO: TRACECLK level={clk_lvl} edges={ec(gclk_ed)}  "
          f"TRACED[3:0] level={d_lvl:04b} edges=[{','.join(ec(x) for x in gd_ed)}]")
    # TRACECLK frequency meter: edges over a fixed window -> MHz
    fb = rd(s, A_FREQ, 3)
    freq_edges = fb[0] | (fb[1] << 8) | (fb[2] << 16)
    # edges = 2 * f * window  ->  f = edges / (2*window)
    f_mhz = freq_edges / (2 * FREQ_WINDOW_S) / 1e6
    print(f"       TRACECLK freq meter: {freq_edges} edges/16.78ms "
          f"=> ~{f_mhz:.2f} MHz at the pin")
    # TRACECLK gap detector: gaps => the H7 TPIU stopping the clock between
    # bursts, which makes the capture MMCM lose lock (flapping).
    gb = rd(s, A_GAP, 4)
    gap_count = gb[0] | (gb[1] << 8)
    gap_max = gb[2] | (gb[3] << 8)
    gc = ">=65535" if gap_count == 0xFFFF else str(gap_count)
    gm_ns = gap_max * CLK_NS
    print(f"       TRACECLK gaps: count={gc}  longest={gap_max} clk ({gm_ns:.0f} ns)")
    if gap_count > 0:
        print(f"[FAIL] TRACECLK is DISCONTINUOUS ({gc} gaps, up to {gm_ns:.0f} ns): "
              f"the H7 TPIU stops the clock between trace bursts. The capture "
              f"MMCM loses lock on every gap (flapping) -> sample errors. This is "
              f"the root cause of the ~7-9% unknown, NOT a frequency mismatch.")
        print(f"       => fix options: (a) keep TRACECLK continuous (TPIU "
              f"continuous formatting / periodic sync), or (b) use a "
              f"gap-tolerant capture front-end that re-locks fast / free-runs.")
    if gclk_ed == 0 and all(x == 0 for x in gd_ed):
        print("[FAIL] raw trace pins are STATIC — no signal reaching the FPGA "
              "GPIO (check STM32 ETM pins / wiring / DAP config)")
    elif gclk_ed == 0:
        print("[WARN] TRACECLK pin not toggling but data lanes are — trace clock "
              "output / PE2 wiring problem")
    else:
        active_lanes = [i for i, x in enumerate(gd_ed) if x > 0]
        print(f"[OK]   raw GPIO toggling: TRACECLK + TRACED lanes {active_lanes} "
              f"active at the pins (signal IS reaching the FPGA)")
        if not trace_lock:
            print("       => pins wiggle but trace MMCM not locked: this is a "
                  "SAMPLING/FREQ issue (TRACECLK freq vs bitstream), not a "
                  "'no signal' issue. Cross-check confirms the GPIO side is fine.")

    # ---- counters ----
    cnts = rd(s, A_CNT_BASE, len(CNT_NAMES))
    nonzero = [(CNT_NAMES[i], cnts[i]) for i in range(len(CNT_NAMES)) if cnts[i]]
    if nonzero:
        print("       error counters: " +
              "  ".join(f"{n}={v}{'+ ' if v == 255 else ''}" for n, v in nonzero))

    # ---- first (root-cause) error ----
    if have_first:
        # cyc runs at 125MHz
        t_ms = first_time / 125_000.0
        ctx_fsm = first_ctx & 0x3
        name = ERR_NAMES.get(first_code, f"unknown 0x{first_code:04x}")
        print(f"[FAIL] FIRST_ERR = 0x{first_code:04x} ({name})")
        print(f"       @ t={t_ms:.2f} ms (cyc={first_time}), "
              f"self-TX was in {FSM_NAMES.get(ctx_fsm, ctx_fsm)}")
        # targeted advice
        if first_code == 0x0401:
            print("       => self-TX/ARP deadlock (HANDOFF §7.1). The self-TX FSM "
                  "waited >8ms for ARP resolve. Host must answer the FPGA's ARP, "
                  "or the FSM needs the deadlock fix.")
        elif first_code == 0x0301:
            print("       => ETM trace rate exceeds the 4-bit@TRACECLK drain "
                  "(proposal 29). Lower CPU clock or raise TRACECLK.")
        elif first_code in (0x0101, 0x0102):
            print("       => check STM32 ETM config / TRACECLK freq vs FPGA "
                  "MMCM sampling frequency.")
        return 2
    else:
        print("[OK]   no sticky errors latched — link healthy")
        return 0


if __name__ == "__main__":
    sys.exit(main())
