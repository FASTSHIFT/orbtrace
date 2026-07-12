// trace_capture_direct
// ====================
// FREQUENCY-INDEPENDENT, gap-tolerant parallel-trace capture (orbtrace-style,
// proposal 22 §7). This is the MINIMAL faithful port of orbtrace's upstream
// glue.py (Linaro OpenCSD-orbtrace):
//
//   traceclk_in  -> IBUF -> BUFG -> cd_trace   (fabric clock == TRACECLK)
//   tracedata[i] -> IBUF -> IDDR(.C=cd_trace)  (rising = trace_a[i],
//                                               falling = trace_b[i])
//
// Deliberately NO IDELAY: upstream does not use one (see glue.py TraceIO),
// and empirically inserting one shifts the DDR phase enough to break the
// TPIU frame-sync that the downstream traceIF module locks to. The IBUF+IDDR
// path already stays inside the safe window at TRACECLK <= ~100 MHz on a
// 7-series chip; anything faster warrants a proper source-synchronous IDELAY
// eye scan (proposal 33 candidate) but is out of scope for the H743 @ 50 MHz
// case that motivated proposal 33.
//
// pseudo-lock: reports mmcm_locked=1 after reset deasserts and a few trace
// clocks tick so the top-level LED / watchdog logic sees a healthy,
// never-flapping capture front-end. No real MMCM here.

`default_nettype none

module trace_capture_direct #(
    // Unused generics kept for port/param compatibility with trace_capture_mmcm
    parameter         MULT  = 40,
    parameter integer DIVID = 40,
    parameter         CLKIN_PERIOD = 47.6,
    parameter         PHASE = 90.0,
    parameter         WIDTH = 4
) (
    input  wire        rst,
    input  wire        trace_clk_p,
    input  wire [3:0]  trace_data_p,

    output wire        trace_clk,     // recovered fabric clock (BUFG on TRACECLK)
    output wire        clk90_out,     // == trace_clk (no phase shift here)
    output wire [3:0]  trace_a,       // DDR rising-edge sample
    output wire [3:0]  trace_b,       // DDR falling-edge sample
    output wire        mmcm_locked,   // pseudo-lock (see header)

    // Post-IBUF raw pin taps for the observability monitor (proposal 30).
    output wire        raw_clk_ibuf,
    output wire [3:0]  raw_data_ibuf,

    // trace-domain byte capture (one byte per TRACECLK period)
    output reg  [7:0]  cap_byte,
    output reg         cap_valid
);
    // ---- TRACECLK input -> BUFG -> capture clock domain ----
    wire trace_clk_ibuf, trace_clk_g;
    IBUF u_ibuf_clk (.I(trace_clk_p), .O(trace_clk_ibuf));
    BUFG u_bufg_clk (.I(trace_clk_ibuf), .O(trace_clk_g));
    assign raw_clk_ibuf = trace_clk_ibuf;
    assign trace_clk    = trace_clk_g;
    assign clk90_out    = trace_clk_g;

    // ---- data lanes: IBUF -> IDDR (clocked by trace clock itself) ----
    // No IDELAY: upstream glue.py doesn't use one, and inserting one under
    // BUFG-clocked IDDR shifts the DDR phase enough to break TPIU frame sync.
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
                .Q1(trace_a[i]),   // rising  half-bit
                .Q2(trace_b[i]),   // falling half-bit
                .C(trace_clk_g), .CE(1'b1),
                .D(data_ibuf[i]), .R(rst), .S(1'b0)
            );
        end
    endgenerate

    // ---- pseudo-lock: high once out of reset + a few trace clocks ticked ----
    // Sync reset in the trace domain (async trip DRC REQP-1839 on the FIFO WEA).
    reg [2:0] lock_cnt = 0;
    reg       locked_r = 0;
    always @(posedge trace_clk_g) begin
        if (rst) begin
            lock_cnt <= 0;
            locked_r <= 1'b0;
        end else if (!locked_r) begin
            lock_cnt <= lock_cnt + 1'b1;
            if (&lock_cnt) locked_r <= 1'b1;
        end
    end
    assign mmcm_locked = locked_r;

    // ---- byte capture in the trace-clock domain (one byte per TRACECLK) ----
    // Same packing as trace_capture_mmcm: {trace_a[k], trace_b[k-1]}.
    reg [3:0] trace_b_q;
    always @(posedge trace_clk_g) begin
        if (rst) begin
            trace_b_q <= 4'd0;
            cap_byte  <= 8'd0;
            cap_valid <= 1'b0;
        end else begin
            trace_b_q <= trace_b;
            cap_byte  <= {trace_a, trace_b_q};
            cap_valid <= locked_r;
        end
    end

endmodule

`default_nettype wire
