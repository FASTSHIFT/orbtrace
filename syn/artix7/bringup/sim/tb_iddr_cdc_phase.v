// tb_iddr_cdc_phase.v — faithful model of the g_iddr capture path, sweeping
// the trace_clk vs ref_200m PHASE (r26 R4). Unlike r26's tb_iddr_cdc.v (which
// drove iddr_a/iddr_b directly from a sequence on one posedge, i.e. NO real
// dual-edge sampling), this models:
//   * EDGE-ALIGNED data: the 4 TRACEDATA lanes flip ON each trace_clk edge
//     (walking-1s: one bit rotates each half-bit), exactly like the STM32 TPIU.
//   * a real dual-edge IDDR: iddr_a := data at posedge, iddr_b := data at
//     negedge, both presented to fabric on the NEXT posedge (SAME_EDGE_
//     PIPELINED semantics: one trace_clk of latency, pair aligned).
//   * the verbatim g_iddr CDC (tclk_byte/tclk_tgl -> tgl_sync/byte_s0/byte_s1).
// The initial trace_clk phase (PH_PS) is swept to see whether the 2-vs-3 stage
// data/strobe misalignment tears bytes at some phases (the R4 hypothesis).

`timescale 1ps/1ps

module tb_iddr_cdc_phase #(
    parameter integer HALF_PS = 41667,   // trace_clk half period (12 MHz)
    parameter integer PH_PS   = 0        // initial trace_clk phase offset
) ();
    reg ref_200m = 1'b0;
    always #2500 ref_200m = ~ref_200m;

    reg trace_clk = 1'b0;
    initial begin
        #(PH_PS);
        forever #(HALF_PS) trace_clk = ~trace_clk;
    end

    // ---- edge-aligned walking-1s data on the 4 lanes ----
    // one-hot bit rotates once per half-bit (per trace_clk edge). Data changes
    // exactly ON the edge (edge-aligned), like the TPIU.
    reg [3:0] dpins = 4'h1;
    task rotate; dpins = {dpins[2:0], dpins[3]}; endtask
    always @(posedge trace_clk) rotate;
    always @(negedge trace_clk) rotate;

    // ---- real dual-edge IDDR (SAME_EDGE_PIPELINED behavioural) ----
    // Sample data ON the edges (this is exactly the "sample on the transition
    // point" that edge-aligned DDR forces). rise-capture at posedge, fall-
    // capture at negedge; both re-registered onto the next posedge and
    // presented together (pipelined: one extra posedge of latency).
    reg [3:0] cap_rise = 0, cap_fall = 0;
    reg [3:0] iddr_a = 0, iddr_b = 0;
    always @(posedge trace_clk) cap_rise <= dpins;   // data at rising edge
    always @(negedge trace_clk) cap_fall <= dpins;   // data at falling edge
    always @(posedge trace_clk) begin                // pipeline align
        iddr_a <= cap_rise;
        iddr_b <= cap_fall;
    end

    // ---- verbatim g_iddr CDC ----
    reg [7:0] tclk_byte = 8'b0;
    reg       tclk_tgl  = 1'b0;
    always @(posedge trace_clk) begin
        tclk_byte <= {iddr_b, iddr_a};
        tclk_tgl  <= ~tclk_tgl;
    end
    reg [2:0] tgl_sync = 3'b0;
    reg [7:0] byte_s0 = 8'b0, byte_s1 = 8'b0;
    always @(posedge ref_200m) begin
        tgl_sync <= {tgl_sync[1:0], tclk_tgl};
        byte_s0  <= tclk_byte;
        byte_s1  <= byte_s0;
    end
    wire cap_valid = tgl_sync[2] ^ tgl_sync[1];
    wire [7:0] cap_byte = byte_s1;

    integer total=0, bad=0, lo5=0, hia=0;
    reg [7:0] b;
    function is_walk_nib(input [3:0] n);
        is_walk_nib = (n==4'h1)||(n==4'h2)||(n==4'h4)||(n==4'h8);
    endfunction
    always @(posedge ref_200m) begin
        if (cap_valid) begin
            b = cap_byte; total = total + 1;
            if (!is_walk_nib(b[3:0]) || !is_walk_nib(b[7:4])) begin
                bad = bad + 1;
                if (b[3:0]==4'h5) lo5 = lo5 + 1;
                if (b[7:4]==4'ha) hia = hia + 1;
            end
        end
    end
    initial begin
        #4000000;
        $display("PH=%0d ps: bytes=%0d bad=%0d (%0d.%02d%%) lo5=%0d hia=%0d",
                 PH_PS, total, bad,
                 total?(100*bad)/total:0, total?((10000*bad)/total)%100:0,
                 lo5, hia);
        $finish;
    end
endmodule
