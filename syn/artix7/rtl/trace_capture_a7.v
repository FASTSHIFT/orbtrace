// trace_capture_a7
// =================
// Source-synchronous DDR capture front-end for the Cortex-M parallel TRACE
// port on Artix-7 (Xilinx 7-series).
//
// Replaces ECP5's IDDRX1F + DELAYG primitives used in orbtrace's `glue.py`
// with the equivalent 7-series primitives:
//   IBUF -> IDELAYE2 (per-lane deskew) -> IDDR (DDR_CLK_EDGE=SAME_EDGE_PIPELINED)
// governed by a single IDELAYCTRL fed from a stable 200 MHz reference.
//
// Note: orbtrace's upstream uses litex.build.io.DDRInput which lowers to an
// IDDR on 7-series — no ISERDES is needed. ISERDES makes sense for very high
// rate single-lane SerDes (>~500Mbps); for trace 4-bit DDR @ <=400Mbps the
// IDDR path is correct, simpler, and matches the upstream behaviour 1:1.
//
// Output stream is the same {trace_a, trace_b} pair (rising-edge nibble and
// falling-edge nibble) that traceIF.v already consumes.
//
// Stage-2 T2 scope: prove the front-end synthesizes on xc7a35t and quantify
// its real OOC footprint. Phase calibration / IDELAY tap scanning state
// machine is intentionally minimal (static tap from a CSR-style port) — full
// per-lane training is a Stage-3 (on-board) PoC matter.
//
// Inputs (board side):
//   trace_clk_p     : TRACECLK from target (must land on a CC pin in xdc)
//   trace_data_p[3:0]: TRACED0..3 from target
//   ref_200m        : stable 200 MHz reference for IDELAYCTRL
//   rst             : asynchronous reset (active high)
//   tap_data{0..3}  : per-lane IDELAY tap (5 bits, 0..31)
//   tap_load        : pulse to (re)load taps
//
// Outputs (to traceIF.v):
//   trace_clk       : recovered trace clock (BUFG'd) — feeds traceIF.traceClkin
//   trace_a[3:0]    : rising-edge sample of TRACED
//   trace_b[3:0]    : falling-edge sample of TRACED
//   idelayctrl_rdy  : IDELAYCTRL ready (must be high before sampling is valid)

`default_nettype none

module trace_capture_a7 #(
    // Clock buffering for TRACECLK:
    //   "BUFG"     : global clock buffer (OOC-friendly, conservative,
    //                larger insertion delay/skew — Stage-2 default).
    //   "BUFR_IO"  : BUFIO drives the IDDR bit-clock + BUFR drives the
    //                fabric clock. Region-local, much lower skew between
    //                TRACECLK and the IDDR C pins — the proper source-
    //                synchronous choice (r11 HG-2 sensitivity study).
    parameter CLK_BUF = "BUFG",
    // Capture method:
    //   "IDDR"       : sample data on the TRACECLK edges via IDDR. Correct
    //                  only if data is CENTRE-aligned. The STM32 TPIU is
    //                  EDGE-aligned (ARM CoreSight TRM: traceclk edges are not
    //                  offset from data edges), so IDDR samples right on the
    //                  data transition -> wrong (esp. the falling edge). Kept
    //                  for reference / centre-aligned sources.
    //   "OVERSAMPLE" : oversample TRACECLK + the 4 data lines on the fast
    //                  ref_200m clock, detect TRACECLK edges, and latch data
    //                  EYE_DELAY ref cycles after each edge — i.e. in the
    //                  centre of the half-bit. This mirrors exactly what the
    //                  logic analyser does in software (sample mid-eye, not on
    //                  the edge), which the LA-sim proved recovers the full
    //                  anchor set. The correct choice for edge-aligned TPIU at
    //                  the slow (~1.3 MHz) trace rates we run.  DEFAULT.
    parameter CAP_METHOD = "OVERSAMPLE",
    // ref_200m cycles to wait after a detected TRACECLK edge before latching
    // the data (mid-eye). At 200 MHz one cycle = 5 ns; the half-bit at
    // TRACECLK<=12.5 MHz is >=40 ns, so a few cycles lands safely inside the
    // eye. For TRACECLK ~1.3 MHz (half-bit ~380 ns) anything 1..~70 works;
    // pick a small value so it also tolerates faster trace clocks.
    parameter EYE_DELAY = 4
) (
    input  wire        rst,
    input  wire        ref_200m,

    // Runtime EYE delay override (OVERSAMPLE). When nonzero, replaces the
    // EYE_DELAY parameter at run time so the mid-eye sample point can be swept
    // over UDP without re-synthesising (frequency-sweep, doc 15). 0 => use the
    // EYE_DELAY parameter default. Tie 0 if unused.
    input  wire [7:0]  eye_delay_rt,

    // Per-capture clear (pulse on each soft re-arm). Resets the sampler's
    // clean-start state (seen_rise) so EVERY capture begins on a fresh rising
    // edge, decoupling capture-start from whatever sampler/TRACECLK phase
    // happened to be latched at re-arm. Tests + fixes the re-arm phase race
    // (red-team r16 §5/E1). Tie 0 if unused.
    input  wire        cap_clear,

    // Trace pins from target
    input  wire        trace_clk_p,
    input  wire [3:0]  trace_data_p,

    // IDELAY control (static for OOC; runtime-calibrated on real HW)
    input  wire [4:0]  tap_data0,
    input  wire [4:0]  tap_data1,
    input  wire [4:0]  tap_data2,
    input  wire [4:0]  tap_data3,
    input  wire        tap_load,

    // --- Self-test injection (red-team E1, doc r15) ---------------------
    // When test_en=1, the OVERSAMPLE sampler takes its clock + data from
    // test_clk/test_data (driven by an FPGA-internal generator in a DIFFERENT,
    // asynchronous clock domain) instead of the physical trace pins. This
    // exercises the full async oversampling architecture with CLEAN edges and
    // NO signal-integrity / IDELAY effects, isolating "async sampling
    // architecture" faults from physical SI. Tied to 0 in normal capture.
    input  wire        test_en,
    input  wire        test_clk,
    input  wire [3:0]  test_data,

    // Captured outputs to traceIF
    output wire        trace_clk,
    output wire [3:0]  trace_a,      // rising-edge sample
    output wire [3:0]  trace_b,      // falling-edge sample
    output wire        idelayctrl_rdy,

    // Glitch-free, ref_200m-domain raw byte capture (OVERSAMPLE only).
    // cap_byte = {falling nibble, rising nibble} for one TRACECLK period;
    // cap_valid pulses one ref_200m cycle when cap_byte is freshly complete.
    // Capturing on (clk200, cap_valid) avoids the async trace_clk->fabric CDC
    // that tears bytes when BUFR_IO trace_clk races the ref-domain a/b
    // registers (doc 14 §27). For BUFG/IDDR modes cap_valid stays 0.
    output wire [7:0]  cap_byte,
    output wire        cap_valid,

    // E3: real TRACECLK duty stats measured at the synchronised clock (FPGA
    // side), in ref_200m cycles. High/low half-period dwell min/max/sum/cnt;
    // the PC computes duty = hi_avg/(hi_avg+lo_avg). Cleared by cap_clear.
    output reg [15:0]  duty_hi_min,
    output reg [15:0]  duty_hi_max,
    output reg [15:0]  duty_lo_min,
    output reg [15:0]  duty_lo_max,
    output reg [31:0]  duty_hi_sum,
    output reg [15:0]  duty_hi_cnt,
    output reg [31:0]  duty_lo_sum,
    output reg [15:0]  duty_lo_cnt,
    // E3b: count of "mid-glitch" half-periods whose dwell is > LOCKOUT but
    // shorter than a real half-bit (a glitch/runt that slipped past the edge
    // lockout). A bad capture should show many more of these than a good one,
    // pinning the root cause. Cleared by cap_clear.
    output reg [15:0]  glitch_cnt
);

    // ------------------------------------------------------------------
    // IDELAYCTRL: shared by all four data lanes. Required for IDELAYE2 in
    // VAR_LOAD mode. UG471 mandates RST be asserted >=60ns asynchronously
    // and released synchronously to REFCLK; do that here.
    // ------------------------------------------------------------------
    reg [3:0] idc_rst_sync = 4'hf;
    always @(posedge ref_200m or posedge rst)
        if (rst) idc_rst_sync <= 4'hf;
        else     idc_rst_sync <= {idc_rst_sync[2:0], 1'b0};
    wire idc_rst = idc_rst_sync[3];

    (* IODELAY_GROUP = "trace_idelay_grp" *)
    IDELAYCTRL u_idelayctrl (
        .RDY    (idelayctrl_rdy),
        .REFCLK (ref_200m),
        .RST    (idc_rst)
    );

    // ------------------------------------------------------------------
    // Clock path: TRACECLK -> IBUF -> { BUFG | BUFIO+BUFR }.
    // r11 HG-2: BUFG is conservative (large insertion delay + global skew);
    // BUFIO/BUFR is region-local and gives a much tighter source-sync
    // window between TRACECLK and the IDDR C pins. CLK_BUF selects which,
    // so we can quantify the window difference in OOC without committing
    // the main line.
    //
    //   trace_clk_io  : the clock that drives the IDDR C pins (sampling)
    //   trace_clk     : the fabric-side clock (traceIF runs on this)
    // For BUFG both are the same net; for BUFR_IO the IDDR uses the BUFIO
    // output while the fabric uses the (divide-by-1) BUFR output.
    // ------------------------------------------------------------------
    wire trace_clk_ibuf;
    wire trace_clk_io;     // -> IDDR C
    IBUF u_ibuf_clk (.I(trace_clk_p), .O(trace_clk_ibuf));

    generate
        if (CLK_BUF == "BUFR_IO") begin : g_bufr
            BUFIO u_bufio_clk (.I(trace_clk_ibuf), .O(trace_clk_io));
            BUFR #(.BUFR_DIVIDE("BYPASS")) u_bufr_clk (
                .I(trace_clk_ibuf), .O(trace_clk), .CE(1'b1), .CLR(1'b0)
            );
        end else begin : g_bufg
            BUFG u_bufg_clk (.I(trace_clk_ibuf), .O(trace_clk));
            assign trace_clk_io = trace_clk;
        end
    endgenerate

    // ------------------------------------------------------------------
    // Per-lane input path: IBUF -> IDELAYE2 -> data_dly.
    // The IDELAY stays in both capture modes: it keeps the IDELAYCTRL group
    // legal and gives a known static lane delay. OVERSAMPLE does not rely on
    // it for phase (it re-times in the ref_200m domain) but reading the
    // delayed copy is harmless; IDDR mode uses it as the deskew element.
    // ------------------------------------------------------------------
    wire [3:0] data_ibuf;
    wire [3:0] data_dly;

    genvar i;
    generate
        for (i = 0; i < 4; i = i + 1) begin : g_lane
            IBUF u_ibuf (.I(trace_data_p[i]), .O(data_ibuf[i]));

            wire [4:0] tap;
            assign tap = (i == 0) ? tap_data0 :
                         (i == 1) ? tap_data1 :
                         (i == 2) ? tap_data2 :
                                    tap_data3;

            (* IODELAY_GROUP = "trace_idelay_grp" *)
            IDELAYE2 #(
                .IDELAY_TYPE         ("VAR_LOAD"),
                .DELAY_SRC           ("IDATAIN"),
                .HIGH_PERFORMANCE_MODE("TRUE"),
                // Default sits at mid-tap (16/31). Stage-3 deskew FSM
                // calibrates per lane; the static value here exists so
                // OOC/post-impl timing analysis sees a non-zero per-lane
                // delay and does not flag a -5 ns hold failure on the
                // bare trace_data_in -> IDDR/D path. ~78 ps/tap *  16 ~
                // 1.25 ns, aligned to the set_input_delay window in xdc.
                .IDELAY_VALUE        (16),
                .SIGNAL_PATTERN      ("DATA"),
                .REFCLK_FREQUENCY    (200.0),
                .CINVCTRL_SEL        ("FALSE"),
                .PIPE_SEL            ("FALSE")
            ) u_idelay (
                .C          (ref_200m),
                .REGRST     (1'b0),
                .LD         (tap_load),
                .CE         (1'b0),
                .INC        (1'b0),
                .CINVCTRL   (1'b0),
                .CNTVALUEIN (tap),
                .IDATAIN    (data_ibuf[i]),
                .DATAIN     (1'b0),
                .LDPIPEEN   (1'b0),
                .DATAOUT    (data_dly[i]),
                .CNTVALUEOUT()
            );
        end
    endgenerate

    // ------------------------------------------------------------------
    // Capture method.
    // ------------------------------------------------------------------
    generate
    if (CAP_METHOD == "OVERSAMPLE") begin : g_oversample
        // ----------------------------------------------------------------
        // Oversampled, mid-eye capture (mirrors the logic-analyser method).
        //
        // The STM32 TPIU drives TRACECLK *edge-aligned* with the data: data
        // transitions land on TRACECLK edges, so the centre of each half-bit
        // (the safe sampling point) is ~a quarter-period AFTER an edge. We
        // oversample TRACECLK and the 4 data lanes on the fast ref_200m clock,
        // detect each TRACECLK edge, then latch the data EYE_DELAY ref cycles
        // later — i.e. inside the eye, exactly like the LA samples at edge+N.
        //
        //   rising  TRACECLK edge -> (after EYE_DELAY) latch into a_reg
        //   falling TRACECLK edge -> (after EYE_DELAY) latch into b_reg
        //
        // a_reg/b_reg are held until the next same-direction edge (~one full
        // TRACECLK period, ~760 ns @1.3 MHz). traceIF reads them on the
        // recovered trace_clk; since they are stable for ~the whole period and
        // updated only ~EYE_DELAY*5 ns after an edge (far from the trace_clk
        // sampling instant), the CDC is safe at the low trace rates we run.
        // (At much higher TRACECLK this would need an explicit handshake;
        // out of scope for the low-speed 100%-correct milestone.)
        // ----------------------------------------------------------------

        // Synchronise TRACECLK (raw IBUF) and the 4 data lanes into ref_200m.
        // Self-test (test_en) swaps in an FPGA-internal async clean source
        // BEFORE the synchroniser, so the full async oversampling path is
        // exercised with no physical-pin / IDELAY / SI effects (doc r15 E1).
        wire       os_clk_src  = test_en ? test_clk  : trace_clk_ibuf;
        wire [3:0] os_data_src = test_en ? test_data : data_dly;
        reg [2:0] tck_sync = 3'b0;        // 3-FF async synchroniser
        reg [3:0] d_s0 = 4'b0, d_s1 = 4'b0;
        always @(posedge ref_200m) begin
            tck_sync <= {tck_sync[1:0], os_clk_src};
            d_s0 <= os_data_src;
            d_s1 <= d_s0;
        end

        // ----------------------------------------------------------------
        // Spurious-edge lockout (doc 15 §9 fix). The intermittent ~20%
        // bad-capture rate came from occasional SPURIOUS extra TRACECLK edges
        // (metastability / ringing crossing the synchroniser): one extra edge
        // inserts a nibble and permanently shifts the DDR pairing + byte
        // boundary, corrupting the rest of the capture ("clean region then
        // dirty to end" signature). Fix: after accepting an edge, ignore any
        // further edge for LOCKOUT ref cycles. Real TRACECLK edges are a
        // half-bit apart (76 ref cycles @1.3MHz), far longer than any glitch,
        // so a short lockout rejects glitches WITHOUT dropping real edges.
        // (Unlike a hold-based de-bounce, a lockout cannot delay/drop a real
        // edge — it only suppresses a too-soon second one.)
        // ----------------------------------------------------------------
        wire tck_s    = tck_sync[2];
        wire tck_prev = tck_sync[1];
        wire raw_rise = tck_s & ~tck_prev;
        wire raw_fall = ~tck_s & tck_prev;
        localparam [4:0] LOCKOUT = 5'd4;   // 4 ref cycles = 20ns min edge spacing
        reg [4:0] lock_cnt = 5'd0;
        wire locked = (lock_cnt != 0);
        always @(posedge ref_200m) begin
            if (rst) lock_cnt <= 0;
            else if ((raw_rise | raw_fall) & ~locked) lock_cnt <= LOCKOUT;
            else if (locked) lock_cnt <= lock_cnt - 1'b1;
        end
        wire rise_evt = raw_rise & ~locked;
        wire fall_evt = raw_fall & ~locked;

        // EYE delay actually used: runtime override if nonzero, else the
        // EYE_DELAY parameter default. 8-bit counters cover up to 255 ref
        // cycles (~1.275 us), enough for the half-bit even at /512.
        wire [7:0] eye_use = (eye_delay_rt != 8'd0) ? eye_delay_rt
                                                    : EYE_DELAY[7:0];

        // EYE_DELAY countdown timers, one per edge direction.
        reg [7:0] r_cnt = 0, f_cnt = 0;
        reg          r_arm = 1'b0, f_arm = 1'b0;
        reg [3:0]    a_reg = 4'b0, b_reg = 4'b0;

        always @(posedge ref_200m) begin
            if (rst) begin
                r_arm <= 1'b0; f_arm <= 1'b0;
                a_reg <= 4'b0; b_reg <= 4'b0;
            end else begin
                // rising-edge sample
                if (rise_evt) begin
                    r_arm <= 1'b1;
                    r_cnt <= eye_use;
                end else if (r_arm) begin
                    if (r_cnt == 0) begin
                        a_reg <= d_s1;
                        r_arm <= 1'b0;
                    end else begin
                        r_cnt <= r_cnt - 1'b1;
                    end
                end
                // falling-edge sample
                if (fall_evt) begin
                    f_arm <= 1'b1;
                    f_cnt <= eye_use;
                end else if (f_arm) begin
                    if (f_cnt == 0) begin
                        b_reg <= d_s1;
                        f_arm <= 1'b0;
                    end else begin
                        f_cnt <= f_cnt - 1'b1;
                    end
                end
            end
        end

        assign trace_a = a_reg;   // rising-edge nibble (mid-eye)
        assign trace_b = b_reg;   // falling-edge nibble (mid-eye)

        // --------------------------------------------------------------
        // Glitch-free capture strobe, all in ref_200m.
        // A DDR byte = (rising nibble, falling nibble) of one TRACECLK
        // period. We emit the byte one ref cycle AFTER b_reg is latched
        // (falling nibble is the second of the pair), pairing it with the
        // a_reg already latched earlier the same period. Both registers are
        // long-settled in the ref domain, so the captured byte cannot tear.
        // --------------------------------------------------------------
        // Clean start: suppress cap_valid until at least one rising-edge
        // sample has been latched, so every capture's first emitted byte is a
        // proper (rising, falling) pair. Without this, a capture (re-)armed
        // mid-period could emit a first byte pairing a falling nibble with a
        // stale rising nibble, offsetting the whole stream by half a period
        // and corrupting the capture from byte 0 (the uniform-dirty ~7% bad
        // captures seen after the glitch lockout, doc 15 §9/§12).
        reg        seen_rise = 1'b0;
        reg        b_latched = 1'b0;
        reg [7:0]  cap_byte_r = 8'b0;
        reg        cap_valid_r = 1'b0;
        always @(posedge ref_200m) begin
            if (rst) begin
                b_latched   <= 1'b0;
                cap_valid_r <= 1'b0;
                cap_byte_r  <= 8'b0;
                seen_rise   <= 1'b0;
            end else begin
                // Per-capture clear: re-arm forces a fresh rising-edge start so
                // capture-start is decoupled from the latched sampler/TRACECLK
                // phase (r16 E1). Also gate cap_valid off this cycle.
                if (cap_clear) seen_rise <= 1'b0;
                else if (r_arm && r_cnt == 0) seen_rise <= 1'b1;
                // detect the cycle b_reg gets latched (f_arm falling with cnt 0)
                b_latched <= (f_arm && f_cnt == 0);
                if (b_latched && seen_rise && !cap_clear) begin
                    cap_byte_r  <= {b_reg, a_reg};
                    cap_valid_r <= 1'b1;
                end else begin
                    cap_valid_r <= 1'b0;
                end
            end
        end
        assign cap_byte  = cap_byte_r;
        assign cap_valid = cap_valid_r;

        // E3 duty measurement: count high vs low half-period dwell of the
        // synchronised TRACECLK (tck_sync[2]) in ref_200m cycles. Cleared on
        // cap_clear so each capture reports its own window's duty (doc 15 §12).
        reg [15:0] dwell = 0;
        always @(posedge ref_200m) begin
            if (rst || cap_clear) begin
                dwell <= 0;
                duty_hi_min <= 16'hFFFF; duty_hi_max <= 0;
                duty_lo_min <= 16'hFFFF; duty_lo_max <= 0;
                duty_hi_sum <= 0; duty_lo_sum <= 0;
                duty_hi_cnt <= 0; duty_lo_cnt <= 0;
                glitch_cnt <= 0;
            end else if (tck_s != tck_prev) begin
                // a half-period (level tck_prev) just ended after `dwell` cycles
                if (tck_prev) begin
                    if (dwell < duty_hi_min) duty_hi_min <= dwell;
                    if (dwell > duty_hi_max) duty_hi_max <= dwell;
                    duty_hi_sum <= duty_hi_sum + dwell;
                    duty_hi_cnt <= duty_hi_cnt + 1'b1;
                end else begin
                    if (dwell < duty_lo_min) duty_lo_min <= dwell;
                    if (dwell > duty_lo_max) duty_lo_max <= dwell;
                    duty_lo_sum <= duty_lo_sum + dwell;
                    duty_lo_cnt <= duty_lo_cnt + 1'b1;
                end
                // mid-glitch: a half-period far shorter than a real half-bit
                // (real /64 half-bit = ~76 cyc; <32 cyc = a glitch that slipped
                // past the LOCKOUT=4 window). Count them per capture.
                if (dwell >= 2 && dwell < 32) glitch_cnt <= glitch_cnt + 1'b1;
                dwell <= 1;
            end else begin
                dwell <= dwell + 1'b1;
            end
        end

    end else begin : g_iddr
        // ----------------------------------------------------------------
        // IDDR: DDR input register sampled on the TRACECLK edges. Correct
        // only for CENTRE-aligned sources; the STM32 TPIU is edge-aligned so
        // this samples on the data transition (doc 14 §21 regression). Kept
        // for reference and for centre-aligned parts.
        // ----------------------------------------------------------------
        wire [3:0] iddr_a, iddr_b;
        genvar j;
        for (j = 0; j < 4; j = j + 1) begin : g_iddr_lane
            IDDR #(
                .DDR_CLK_EDGE ("SAME_EDGE_PIPELINED"),
                .INIT_Q1      (1'b0),
                .INIT_Q2      (1'b0),
                .SRTYPE       ("ASYNC")
            ) u_iddr (
                .Q1 (iddr_a[j]),  // rising-edge sample
                .Q2 (iddr_b[j]),  // falling-edge sample
                .C  (trace_clk_io), // BUFIO (BUFR_IO) or BUFG net
                .CE (1'b1),
                .D  (data_dly[j]),
                .R  (rst),
                .S  (1'b0)
            );
        end
        assign trace_a = iddr_a;
        assign trace_b = iddr_b;

        // ---- gap-tolerant raw-byte export for CAP_RAW (high-freq path) ----
        // v2 (r26 R4 fix): the byte crosses trace_clk -> ref_200m through a
        // PROPER async FIFO (gray-code pointers) instead of the old bare-bus
        // toggle CDC. The old design exposed the combinationally-updated 8-bit
        // `tclk_byte` bus directly to a ref_200m sampler; with real per-bit
        // routing skew, a ref sample landing in the launch window latched a MIX
        // of period k and k+1 -> the 0x5=0x1|0x4 / 0xa=0x2|0x8 OR-tears. The
        // FIFO's gray-coded pointer crossing makes the byte transfer ATOMIC:
        // the reader only ever sees a fully-written entry, never a torn one.
        //
        // Gap tolerance preserved: the WRITE port is clocked by trace_clk, so a
        // stopped TRACECLK simply stops pushing (no garbage). No PLL/MMCM lock
        // to lose. Depth 32 is ample: write rate <= TRACECLK (<=200M), read rate
        // = ref_200m (200M), so it never backs up in steady state.
        reg [7:0] tclk_byte = 8'b0;
        reg       tclk_push = 1'b0;
        always @(posedge trace_clk) begin
            tclk_byte <= {iddr_b, iddr_a};   // big-endian: falling nibble MS
            tclk_push <= 1'b1;               // push one byte per TRACECLK period
        end

        wire        fifo_s_ready;
        wire [7:0]  fifo_m_data;
        wire        fifo_m_valid;
        // read side: pop whenever data is available (ref_200m is >= TRACECLK, so
        // we drain at least as fast as it fills).
        wire        fifo_m_ready = fifo_m_valid;

        axis_async_fifo #(
            .DEPTH(32), .DATA_WIDTH(8),
            .KEEP_ENABLE(0), .LAST_ENABLE(0), .USER_ENABLE(0), .FRAME_FIFO(0)
        ) u_cdc_fifo (
            .s_clk(trace_clk), .s_rst(rst),
            .s_axis_tdata(tclk_byte), .s_axis_tkeep(1'b0),
            .s_axis_tvalid(tclk_push), .s_axis_tready(fifo_s_ready),
            .s_axis_tlast(1'b0), .s_axis_tid(8'h0), .s_axis_tdest(8'h0),
            .s_axis_tuser(1'b0),
            .m_clk(ref_200m), .m_rst(rst),
            .m_axis_tdata(fifo_m_data), .m_axis_tkeep(),
            .m_axis_tvalid(fifo_m_valid), .m_axis_tready(fifo_m_ready),
            .m_axis_tlast(), .m_axis_tid(), .m_axis_tdest(), .m_axis_tuser(),
            .s_pause_req(1'b0), .s_pause_ack(), .m_pause_req(1'b0), .m_pause_ack(),
            .s_status_depth(), .s_status_depth_commit(), .s_status_overflow(),
            .s_status_bad_frame(), .s_status_good_frame(),
            .m_status_depth(), .m_status_depth_commit(), .m_status_overflow(),
            .m_status_bad_frame(), .m_status_good_frame()
        );
        assign cap_valid = fifo_m_valid & fifo_m_ready;
        assign cap_byte  = fifo_m_data;

        // IDDR mode does not measure duty; hold the stats at 0.
        always @(posedge ref_200m) begin
            duty_hi_min <= 0; duty_hi_max <= 0; duty_lo_min <= 0;
            duty_lo_max <= 0; duty_hi_sum <= 0; duty_hi_cnt <= 0;
            duty_lo_sum <= 0; duty_lo_cnt <= 0; glitch_cnt <= 0;
        end
    end
    endgenerate

endmodule

`default_nettype wire
