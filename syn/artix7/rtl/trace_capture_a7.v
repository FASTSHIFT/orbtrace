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
    // IDELAYE2 on the data lanes. 1 = per-lane VAR_LOAD deskew (the tap-sweep
    // path, frequency-coupled). 0 = BYPASS: feed data straight IBUF->IDDR, the
    // faithful port of orbtrace upstream glue.py (DDRInput, no delay element).
    // Upstream relies purely on IOB routing delay + flip-flop hold time to land
    // the IDDR sample inside the next half-bit, which is frequency-independent.
    // When 0, tap_data*/tap_clk/tap_load are ignored.
    parameter USE_IDELAY = 1,
    // Data-lane IDELAY mode:
    //   0 = VAR_LOAD: delay loaded at runtime from tap_data* (tap sweep). NOTE
    //       STA analyses the STATIC IDELAY_VALUE below, NOT the runtime tap, so
    //       timing closure and hardware can DISAGREE if they differ. Use only
    //       for interactive tap experiments.
    //   1 = FIXED: delay is the compile-time IDELAY_FIXED_VAL; STA and hardware
    //       use the SAME value, so a hold-closing tap found in STA is exactly
    //       what runs. This is the shipped, deterministic choice — one fixed
    //       tap compensates the (frequency-independent) clock-tree-vs-data hold
    //       skew. tap_data*/tap_load are ignored in this mode.
    parameter IDELAY_FIXED    = 1,
    // tap 24: STA hold WHS +0.079 ns (closes the IDDR input-hold violation with
    // margin over the tap-18 knife-edge; saturates by 24, tap 30 adds nothing).
    // See sweep_trace_hold.tcl / doc 25. ~78 ps/tap * 24 ~ 1.87 ns of data delay
    // to compensate the clock-tree-vs-data-direct skew (frequency-independent).
    parameter [4:0] IDELAY_FIXED_VAL = 5'd24
) (
    input  wire        rst,
    input  wire        ref_200m,

    // Trace pins from target
    input  wire        trace_clk_p,
    input  wire [3:0]  trace_data_p,

    // IDELAY control (static for OOC; runtime-calibrated on real HW)
    input  wire [4:0]  tap_data0,
    input  wire [4:0]  tap_data1,
    input  wire [4:0]  tap_data2,
    input  wire [4:0]  tap_data3,
    // Clock-lane IDELAY tap (>100MHz eye reach): delaying TRACECLK shifts the
    // effective sampling phase the OTHER way, so data_tap - clk_tap spans the
    // FULL UI (±2.4ns = 4.8ns > half-UI 4.7ns @ ~105MHz). At <=100MHz leave
    // clk_tap=0 (data tap alone reaches the eye). See doc 16.
    input  wire [4:0]  tap_clk,
    input  wire        tap_load,

    // Captured outputs to traceIF
    output wire        trace_clk,
    output wire [3:0]  trace_a,      // rising-edge sample
    output wire [3:0]  trace_b,      // falling-edge sample
    output wire        idelayctrl_rdy,

    // Raw byte capture in the ref_200m domain (one byte per TRACECLK period,
    // {falling nibble, rising nibble}) crossed atomically via the gray-code
    // async FIFO. cap_valid pulses when cap_byte is freshly popped.
    output wire [7:0]  cap_byte,
    output wire        cap_valid
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

    // Clock-lane IDELAY (only meaningful for the source-sync BUFR_IO/IDDR
    // path). Delaying the sampling clock relative to the data extends the
    // reachable sampling phase beyond the data-only IDELAY range, so the eye
    // centre stays inside [0..31] even above 100MHz where half-UI < 2.4ns.
    // A BUFIO clock must come from a clock-capable path; IDELAYE2 -> BUFIO is
    // legal on 7-series (the IDELAY sits in the IOB, BUFIO follows).
    wire trace_clk_dly;

    generate
        if (CLK_BUF == "BUFR_IO") begin : g_bufr
            (* IODELAY_GROUP = "trace_idelay_grp" *)
            IDELAYE2 #(
                .IDELAY_TYPE          ("VAR_LOAD"),
                .DELAY_SRC            ("IDATAIN"),
                .HIGH_PERFORMANCE_MODE("TRUE"),
                .IDELAY_VALUE         (0),
                .SIGNAL_PATTERN       ("CLOCK"),
                .REFCLK_FREQUENCY     (200.0),
                .CINVCTRL_SEL         ("FALSE"),
                .PIPE_SEL             ("FALSE")
            ) u_idelay_clk (
                .C          (ref_200m),
                .REGRST     (1'b0),
                .LD         (tap_load),
                .CE         (1'b0),
                .INC        (1'b0),
                .CINVCTRL   (1'b0),
                .CNTVALUEIN (tap_clk),
                .IDATAIN    (trace_clk_ibuf),
                .DATAIN     (1'b0),
                .DATAOUT    (trace_clk_dly),
                .CNTVALUEOUT()
            );
            BUFIO u_bufio_clk (.I(trace_clk_dly), .O(trace_clk_io));
            BUFR #(.BUFR_DIVIDE("BYPASS")) u_bufr_clk (
                .I(trace_clk_dly), .O(trace_clk), .CE(1'b1), .CLR(1'b0)
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

            if (USE_IDELAY && IDELAY_FIXED) begin : g_idelay_fixed
                // FIXED delay: STA and hardware use IDELAY_FIXED_VAL — no
                // runtime VAR_LOAD, so a hold-closing tap found in the timing
                // report is exactly what the silicon runs. This is the fix for
                // the IDDR input-hold violation on the direct path (clock tree
                // insertion delay >> data IBUF delay -> data arrives too early
                // -> hold fail). One fixed tap; frequency-independent.
                (* IODELAY_GROUP = "trace_idelay_grp" *)
                IDELAYE2 #(
                    .IDELAY_TYPE         ("FIXED"),
                    .DELAY_SRC           ("IDATAIN"),
                    .HIGH_PERFORMANCE_MODE("TRUE"),
                    .IDELAY_VALUE        (IDELAY_FIXED_VAL),
                    .SIGNAL_PATTERN      ("DATA"),
                    .REFCLK_FREQUENCY    (200.0),
                    .CINVCTRL_SEL        ("FALSE"),
                    .PIPE_SEL            ("FALSE")
                ) u_idelay (
                    .C          (1'b0),
                    .REGRST     (1'b0),
                    .LD         (1'b0),
                    .CE         (1'b0),
                    .INC        (1'b0),
                    .CINVCTRL   (1'b0),
                    .CNTVALUEIN (5'd0),
                    .IDATAIN    (data_ibuf[i]),
                    .DATAIN     (1'b0),
                    .LDPIPEEN   (1'b0),
                    .DATAOUT    (data_dly[i]),
                    .CNTVALUEOUT()
                );
            end else if (USE_IDELAY) begin : g_idelay
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
            end else begin : g_nodelay
                // Upstream-faithful: no delay element, IBUF straight to IDDR.
                assign data_dly[i] = data_ibuf[i];
            end
        end
    endgenerate

    // ------------------------------------------------------------------
    // Capture method: IDDR edge-sampling (the shipped path). The former
    // OVERSAMPLE mid-eye sampler was removed 2026-09-07 — it had no consumer
    // (all OVERSAMPLE tops retired) and the flat eye-sweep confirmed it was
    // dead code. See docs/artix7-port/stage4-datapath/25-*.md.
    //
    // IDDR: DDR input register sampled on the TRACECLK edges (Q1 rising, Q2
    // falling). The STM32 data is centre-aligned at the rates we run (doc 23),
    // so sampling on the edge lands in the eye. One byte per TRACECLK period
    // crosses to ref_200m through a gray-code async FIFO (atomic, gap-tolerant).
    // ------------------------------------------------------------------
    generate begin : g_iddr
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
    end
    endgenerate

endmodule

`default_nettype wire
