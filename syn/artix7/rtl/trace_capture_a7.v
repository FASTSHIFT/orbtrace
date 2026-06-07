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
    parameter CLK_BUF = "BUFG"
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
    input  wire        tap_load,

    // Captured outputs to traceIF
    output wire        trace_clk,
    output wire [3:0]  trace_a,      // rising-edge sample
    output wire [3:0]  trace_b,      // falling-edge sample
    output wire        idelayctrl_rdy
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
    // Per-lane: IBUF -> IDELAYE2 -> IDDR (DDR_CLK_EDGE = SAME_EDGE_PIPELINED).
    // IDDR Q1 = data sampled on rising edge of C, presented on the
    // following rising edge (one-cycle latency for both edges aligned).
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

            // IDDR: DDR input register, captures rising-edge sample to Q1
            // and falling-edge sample to Q2.  SAME_EDGE_PIPELINED presents
            // both Q1 and Q2 on the next rising edge of C, aligned to the
            // sys clock domain (traceIF traceClkin = trace_clk).
            IDDR #(
                .DDR_CLK_EDGE ("SAME_EDGE_PIPELINED"),
                .INIT_Q1      (1'b0),
                .INIT_Q2      (1'b0),
                .SRTYPE       ("ASYNC")
            ) u_iddr (
                .Q1 (trace_a[i]),  // rising-edge sample
                .Q2 (trace_b[i]),  // falling-edge sample
                .C  (trace_clk_io), // BUFIO (BUFR_IO) or BUFG net
                .CE (1'b1),
                .D  (data_dly[i]),
                .R  (rst),
                .S  (1'b0)
            );
        end
    endgenerate

endmodule

`default_nettype wire
