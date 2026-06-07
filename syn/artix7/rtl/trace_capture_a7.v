// trace_capture_a7
// =================
// Source-synchronous DDR capture front-end for the Cortex-M parallel TRACE
// port on Artix-7 (Xilinx 7-series). Replaces the ECP5-specific IDDRX1F /
// DELAYG primitives used by orbtrace's `glue.py` with the equivalent
// 7-series hard blocks: IDELAYE2 + ISERDESE2 (DDR mode), governed by a
// single IDELAYCTRL fed from a stable 200MHz reference.
//
// Output stream is the same {trace_a, trace_b} pair (rising-edge nibble and
// falling-edge nibble) that traceIF.v already consumes.
//
// Stage-2 T2 scope: prove the front-end synthesizes on xc7a35t and quantify
// its real OOC footprint. Phase calibration / IDELAY tap scanning state
// machine is intentionally minimal (static tap from a CSR-style port) — full
// per-lane training is a Stage-3 (on-board) PoC matter, not an OOC-resource
// matter. This module provides a realistic resource skeleton.
//
// Inputs (board side):
//   trace_clk_p     : TRACECLK from target (must land on a CC pin in xdc)
//   trace_data_p[3:0]: TRACED0..3 from target
//   ref_200m        : stable 200 MHz reference for IDELAYCTRL
//   rst             : synchronous reset (active high, in ref_200m domain)
//   tap_data[3:0][4:0]: per-lane IDELAY tap (5 bits, 0..31)
//   tap_load        : pulse to (re)load taps
//
// Outputs (to traceIF.v):
//   trace_clk       : recovered trace clock (BUFG'd) — feeds traceIF.traceClkin
//   trace_a[3:0]    : rising-edge sample of TRACED
//   trace_b[3:0]    : falling-edge sample of TRACED
//   idelayctrl_rdy  : IDELAYCTRL ready (must be high before sampling is valid)

`default_nettype none

module trace_capture_a7 (
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
    output wire        trace_clk,    // recovered trace clock (sys-side use is illustrative; traceIF runs on this)
    output wire [3:0]  trace_a,      // rising-edge sample
    output wire [3:0]  trace_b,      // falling-edge sample
    output wire        idelayctrl_rdy
);

    // ------------------------------------------------------------------
    // IDELAYCTRL: one per IO column; required for any IDELAYE2 in VARIABLE/VAR_LOAD modes.
    // Shared by all four data lanes. Reset must be asserted >=60ns and
    // released synchronously to ref_200m (handled by upper level).
    // ------------------------------------------------------------------
    (* IODELAY_GROUP = "trace_idelay_grp" *)
    IDELAYCTRL u_idelayctrl (
        .RDY    (idelayctrl_rdy),
        .REFCLK (ref_200m),
        .RST    (rst)
    );

    // ------------------------------------------------------------------
    // Clock path: TRACECLK -> IBUF -> BUFG (so traceIF can use it as a
    // clock and ISERDES sees the same edge as the data nibbles).
    // (For real HW, BUFR/BUFIO + region constraints can give better source-
    //  synchronous timing; BUFG is OOC-friendly and conservative.)
    // ------------------------------------------------------------------
    wire trace_clk_ibuf;
    IBUF u_ibuf_clk (.I(trace_clk_p), .O(trace_clk_ibuf));
    BUFG u_bufg_clk (.I(trace_clk_ibuf), .O(trace_clk));

    // ------------------------------------------------------------------
    // Per-lane: IBUF -> IDELAYE2 -> ISERDESE2 (DDR, x2 deserialization).
    // We want one rising-edge sample (trace_a) and one falling-edge sample
    // (trace_b) per TRACECLK period: ISERDES with DATA_RATE=DDR and
    // DATA_WIDTH=2 produces Q1 = falling edge sample, Q2 = rising edge sample
    // (per UG471 nomenclature). Pin them to trace_b/trace_a accordingly.
    // ------------------------------------------------------------------
    wire [3:0] data_ibuf;
    wire [3:0] data_dly;

    genvar i;
    generate
        for (i = 0; i < 4; i = i + 1) begin : g_lane
            IBUF u_ibuf (.I(trace_data_p[i]), .O(data_ibuf[i]));

            // Per-lane tap value mux
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
                .IDELAY_VALUE        (0),
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

            // ISERDESE2: DDR mode, x2. Q1 = first sample (per UG471: falling
            // edge for SDR/DDR networks where the rising-edge sample lands on Q2).
            // For our orbtrace mapping (trace_a = rising, trace_b = falling),
            // use Q2 -> trace_a, Q1 -> trace_b.
            ISERDESE2 #(
                .DATA_RATE        ("DDR"),
                .DATA_WIDTH       (4),       // minimum required by 7-series for DDR
                .INTERFACE_TYPE   ("NETWORKING"),
                .DYN_CLKDIV_INV_EN("FALSE"),
                .DYN_CLK_INV_EN   ("FALSE"),
                .NUM_CE           (1),
                .OFB_USED         ("FALSE"),
                .IOBDELAY         ("IFD"),
                .SERDES_MODE      ("MASTER"),
                .INIT_Q1          (1'b0),
                .INIT_Q2          (1'b0),
                .INIT_Q3          (1'b0),
                .INIT_Q4          (1'b0),
                .SRVAL_Q1         (1'b0),
                .SRVAL_Q2         (1'b0),
                .SRVAL_Q3         (1'b0),
                .SRVAL_Q4         (1'b0)
            ) u_iserdes (
                .Q1               (trace_b[i]),  // falling edge
                .Q2               (trace_a[i]),  // rising edge
                .Q3               (),
                .Q4               (),
                .O                (),
                .SHIFTOUT1        (),
                .SHIFTOUT2        (),
                .D                (1'b0),        // unused: data path is DDLY (post-IDELAY)
                .DDLY             (data_dly[i]),
                .CLK              (trace_clk),
                .CLKB             (~trace_clk),
                .CE1              (1'b1),
                .CE2              (1'b1),
                .RST              (rst),
                .CLKDIV           (trace_clk),   // x1 (no extra division); minimal OOC variant
                .CLKDIVP          (1'b0),
                .OCLK             (1'b0),
                .OCLKB            (1'b0),
                .BITSLIP          (1'b0),
                .SHIFTIN1         (1'b0),
                .SHIFTIN2         (1'b0),
                .OFB              (1'b0),
                .DYNCLKDIVSEL     (1'b0),
                .DYNCLKSEL        (1'b0)
            );
        end
    endgenerate

endmodule

`default_nettype wire
