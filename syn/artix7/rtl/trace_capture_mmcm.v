// trace_capture_mmcm
// ==================
// Mid-speed source-synchronous capture for edge-aligned DDR parallel trace.
// Uses an MMCM to phase-shift the recovered TRACECLK by 90 degrees and clocks
// an IDDR with that shifted clock, so the IDDR's two edges land in the CENTRE
// of the two DDR half-bits (the eye), not on the data transition.
//
// Why this (proposal 22 §7.1): edge-aligned DDR has data flipping on both
// TRACECLK edges. Sampling on the raw clock edges (plain IDDR) hits the
// transition. IDELAY can only move ~2.5ns -> needs TRACECLK >=~100MHz to reach
// the eye centre. OVERSAMPLE only works <=~10MHz TRACECLK. The 10-100MHz gap is
// covered by phase-shifting the sample clock 90 deg with an MMCM (MMCM locks
// for CLKIN >= ~10MHz, so this is a MID-SPEED-only technique).
//
//   TRACECLK(21M) -> IBUF -> BUFG -> MMCM(CLKIN) -> CLKOUT0 @ +90deg -> BUFG
//                                                       |
//   TRACEDATA -> IBUF -----------------> IDDR(.C = clk90) -> Q1/Q2 = trace_a/b
//
// CLKIN range 10-800MHz (7-series MMCM). VCO = CLKIN*M must be 600-1200MHz;
// pick M from a generic so the same RTL covers a band of TRACECLK by changing
// only MULT at synth (e.g. 21M*40=840M; 42M*20=840M).
//
// Output is the same {trace_a (rising-half centre), trace_b (falling-half
// centre)} pair traceIF consumes, plus a ref-domain cap_byte/cap_valid built
// in the clk90 domain (its own clock, no async CDC).

`default_nettype none

module trace_capture_mmcm #(
    parameter         MULT  = 40,        // MMCM CLKFBOUT_MULT_F; VCO=TRACECLK*MULT
    parameter integer DIVID = 40,        // CLKOUT0_DIVIDE: VCO/DIVID = TRACECLK
    parameter         CLKIN_PERIOD = 47.6, // ns, must match real TRACECLK period
    parameter         PHASE = 90.0,     // CLKOUT1 sample-clock phase (deg)
    parameter         WIDTH = 4          // data lanes used (2 or 4)
) (
    input  wire        rst,
    input  wire        trace_clk_p,
    input  wire [3:0]  trace_data_p,

    output wire        trace_clk,        // recovered fabric clock (0-deg, BUFG)
    output wire        clk90_out,        // 90-deg sample clock (capture domain)
    output wire [3:0]  trace_a,          // first half-bit (eye centre)
    output wire [3:0]  trace_b,          // second half-bit (eye centre)
    output wire        mmcm_locked,

    // Post-IBUF raw pin taps for the observability monitor (proposal 30). These
    // are the buffered (but NOT MMCM-sampled) pin signals, so the top can
    // detect raw GPIO toggling independent of the sampling MMCM, without adding
    // a second (illegal) IBUF on the same input pin.
    output wire        raw_clk_ibuf,
    output wire [3:0]  raw_data_ibuf,

    // clk90-domain glitch-free byte capture (mirrors trace_capture_a7)
    output reg  [7:0]  cap_byte,
    output reg         cap_valid
);
    // ---- TRACECLK input -> BUFG -> MMCM ----
    wire trace_clk_ibuf, trace_clk_bufg;
    IBUF u_ibuf_clk (.I(trace_clk_p), .O(trace_clk_ibuf));
    BUFG u_bufg_in  (.I(trace_clk_ibuf), .O(trace_clk_bufg));
    assign raw_clk_ibuf = trace_clk_ibuf;

    wire clkfb, clk0_u, clk90_u;
    wire clk90;
    MMCME2_BASE #(
        .BANDWIDTH("OPTIMIZED"),
        .CLKFBOUT_MULT_F(MULT),
        .DIVCLK_DIVIDE(1),
        .CLKIN1_PERIOD(CLKIN_PERIOD),    // real TRACECLK period (generic)
        .CLKOUT0_DIVIDE_F(DIVID),
        .CLKOUT1_DIVIDE(DIVID),
        .CLKOUT0_PHASE(0.0),
        .CLKOUT1_PHASE(PHASE),           // sample-clock phase (deg, generic).
        // Board-verified eye-centre phase RISES with frequency (fixed
        // data-clock skew is a growing fraction of the shrinking UI). Measured
        // optima (proposal 22 §7.5, by min unknown-byte rate, NOT anchor count):
        //   21M -> 90.0   (0.002% unknown, golden)
        //   84M -> 112.5  (0.01%  unknown, golden)
        // The optimum is narrow at 84M (UI=11.9ns): 135 deg gives 1.2%, 112.5
        // gives 0.01% -- so PHASE MUST be set per target frequency at build.
        // (Runtime dynamic phase calibration is the robust long-term fix.)
        .STARTUP_WAIT("FALSE")
    ) u_mmcm (
        .CLKIN1(trace_clk_bufg),
        .CLKFBIN(clkfb), .CLKFBOUT(clkfb),
        .CLKOUT0(clk0_u), .CLKOUT1(clk90_u),
        .LOCKED(mmcm_locked),
        .RST(rst), .PWRDWN(1'b0)
    );
    BUFG u_bufg0  (.I(clk0_u),  .O(trace_clk));
    BUFG u_bufg90 (.I(clk90_u), .O(clk90));
    assign clk90_out = clk90;

    // ---- data lanes: IBUF -> IDDR clocked by the 90-deg sample clock ----
    wire [3:0] data_ibuf;
    genvar i;
    generate
        for (i = 0; i < 4; i = i + 1) begin : g_lane
            IBUF u_ibuf (.I(trace_data_p[i]), .O(data_ibuf[i]));
            assign raw_data_ibuf[i] = data_ibuf[i];
            IDDR #(
                .DDR_CLK_EDGE("SAME_EDGE_PIPELINED"),
                .INIT_Q1(1'b0), .INIT_Q2(1'b0), .SRTYPE("ASYNC")
            ) u_iddr (
                .Q1(trace_a[i]),   // sampled on clk90 rising  = half-bit 0 centre
                .Q2(trace_b[i]),   // sampled on clk90 falling = half-bit 1 centre
                .C(clk90), .CE(1'b1),
                .D(data_ibuf[i]), .R(rst), .S(1'b0)
            );
        end
    endgenerate

    // ---- byte capture in the clk90 domain (one byte per TRACECLK period) ----
    // Half-bit time order on clk90 is a[k] (rising-half) then b[k] (falling).
    // Board-measured truth (decode/mmcm_halfbit_search.py on real STM32 ETM):
    // the decodable TPIU byte is {a[k] (high nibble), b[k-1] (low nibble)} --
    // the byte boundary sits one half-bit off from the naive {b[k],a[k]} pack
    // (IDDR SAME_EDGE_PIPELINED phase). So pair the CURRENT rising nibble with
    // the PREVIOUS falling nibble.
    reg [3:0] trace_b_q;
    always @(posedge clk90) begin
        if (rst) begin
            trace_b_q <= 4'd0;
            cap_byte  <= 8'd0;
            cap_valid <= 1'b0;
        end else begin
            trace_b_q <= trace_b;
            cap_byte  <= {trace_a, trace_b_q};   // {a[k], b[k-1]}
            cap_valid <= mmcm_locked;     // valid once MMCM has locked
        end
    end

endmodule

`default_nettype wire
