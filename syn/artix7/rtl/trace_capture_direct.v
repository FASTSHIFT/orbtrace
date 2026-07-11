// trace_capture_direct
// ====================
// FREQUENCY-INDEPENDENT, gap-tolerant parallel-trace capture (orbtrace-style,
// proposal 22 §7 "治本"). Drop-in replacement for trace_capture_mmcm.v: SAME
// port list, so trace_mmcm_stream_top can select it with a DIRECT generic and
// reuse the whole AsyncFIFO -> packetiser -> UDP path unchanged.
//
// WHY (vs the MMCM 90-deg phase-shift front-end):
//   trace_capture_mmcm feeds TRACECLK into an MMCM to make a 90-deg sample
//   clock. That MMCM only LOCKS for CLKIN >= ~10-19MHz AND needs the VCO
//   (TRACECLK*MULT) to land in 600-1440MHz, so the SAME bitstream only works
//   in a narrow TRACECLK band -- change the H7 clock and it stops locking.
//   Board-measured: at TRACECLK=12.8MHz the capture MMCM never locks (lock=0)
//   even though all 4 data lanes + clock are toggling continuously (gaps=0).
//
//   orbtrace (orbtrace/orbtrace/trace/glue.py) instead uses TRACECLK DIRECTLY
//   as the FPGA capture clock (ClockSignal().eq(traceclk)) + DDRInput, then an
//   AsyncFIFO crosses into the system domain. No PLL/MMCM lock => works at ANY
//   TRACECLK the fabric+BUFG can carry (~5-250MHz on Artix-7), and it tolerates
//   TRACECLK stopping/restarting (the clock domain just pauses, the AsyncFIFO
//   holds what it has). This is the robust long-term capture path.
//
//   The tradeoff orbtrace accepts (and we accept): sampling DDR data with the
//   trace clock's own edges instead of a phase-shifted eye-centre clock. At LOW
//   TRACECLK this is trivially safe -- e.g. 12.8MHz DDR => a 39ns half-bit eye,
//   vastly larger than the pin+IDDR setup/hold. (The MMCM eye-centre trick only
//   earns its keep near/above ~80-100MHz where the UI shrinks below ~12ns.)
//
//   TRACECLK(any) -> IBUF -> BUFG -> cd_trace  (capture clock == trace clock)
//   TRACEDATA[i]  -> IBUF -> IDDR(.C = cd_trace) -> Q1/Q2 = trace_a/trace_b[i]
//   {trace_a, trace_b_q} byte @ 1/TRACECLK -> (top) AsyncFIFO -> clk125
//
// mmcm_locked: there is no MMCM, so "lock" is not a real thing here. We report
// locked=1 after reset deasserts and a few trace clocks have ticked, so the
// top's LED / watchdog logic sees a healthy, never-flapping capture front-end.

`default_nettype none

module trace_capture_direct #(
    // Unused generics kept for port/param compatibility with trace_capture_mmcm
    // (so the build TCL can pass the same -generic list either way).
    parameter         MULT  = 40,
    parameter integer DIVID = 40,
    parameter         CLKIN_PERIOD = 47.6,
    parameter         PHASE = 90.0,
    parameter         WIDTH = 4
) (
    input  wire        rst,
    input  wire        trace_clk_p,
    input  wire [3:0]  trace_data_p,

    output wire        trace_clk,        // recovered fabric clock (BUFG on TRACECLK)
    output wire        clk90_out,        // == trace_clk (no phase shift here)
    output wire [3:0]  trace_a,          // DDR rising-edge sample
    output wire [3:0]  trace_b,          // DDR falling-edge sample
    output wire        mmcm_locked,      // pseudo-lock (see header): 1 when running

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
    assign clk90_out    = trace_clk_g;   // capture domain == trace clock

    // ---- data lanes: IBUF -> IDDR clocked by the trace clock itself ----
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
                .Q1(trace_a[i]),   // sampled on trace_clk rising  = DDR half-bit 0
                .Q2(trace_b[i]),   // sampled on trace_clk falling = DDR half-bit 1
                .C(trace_clk_g), .CE(1'b1),
                .D(data_ibuf[i]), .R(rst), .S(1'b0)
            );
        end
    endgenerate

    // ---- pseudo-lock: high once out of reset + a few trace clocks ticked ----
    // Gives the top a stable "trace_mmcm_locked" so LED/watchdog treat the
    // direct front-end as permanently healthy (it never loses lock).
    // Synchronous reset (matches trace_capture_mmcm): an ASYNC reset on these
    // regs drives the AsyncFIFO WEA and trips DRC REQP-1839 (RAMB async control
    // -> possible memory corruption). Sync reset in the trace domain is clean.
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
    // Same packing as trace_capture_mmcm: {trace_a[k], trace_b[k-1]} -- the
    // decodable TPIU byte boundary sits one half-bit off from the naive pack
    // (board-measured, decode/mmcm_halfbit_search.py). The PC-side decoder also
    // runs a nibble-alignment search, so either ordering is recoverable.
    reg [3:0] trace_b_q;
    always @(posedge trace_clk_g) begin
        if (rst) begin
            trace_b_q <= 4'd0;
            cap_byte  <= 8'd0;
            cap_valid <= 1'b0;
        end else begin
            trace_b_q <= trace_b;
            cap_byte  <= {trace_a, trace_b_q};   // {a[k], b[k-1]}
            cap_valid <= locked_r;
        end
    end

endmodule

`default_nettype wire
