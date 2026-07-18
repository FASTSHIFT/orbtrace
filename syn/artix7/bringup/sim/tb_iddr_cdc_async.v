// tb_iddr_cdc_async.v — the honest CDC test: ZERO artificial skew, ATOMIC
// byte bus, but a genuinely ASYNCHRONOUS trace_clk vs ref_200m (irrational-ish
// ratio -> continuous phase drift, like two independent oscillators). Plus a
// real dual-edge IDDR on edge-aligned walking data.
//
// Question this answers: does the g_iddr toggle-CDC produce RANDOM, per-run-
// varying byte errors from async beating ALONE (no injected skew)? That is the
// hardware signature we measured at 100 MHz (~2% mean, violently random per
// rearm, tap-independent, fall/rise symmetric). r26's sweep needed an injected
// 300 ps per-bit skew to tear; this asks whether pure async beating suffices.
//
// The toggle CDC's known failure: cap_valid = tgl_sync[2]^tgl_sync[1] samples
// tclk_tgl (which toggles once per trace_clk) in the ref_200m domain. When
// trace_clk approaches ref_200m/2, the toggle is sampled <2x per period ->
// missed/doubled -> byte drop/dup -> walking rotation breaks. At 100 MHz
// (trace_clk) vs 200 MHz (ref) that is EXACTLY ref/2, the worst case.

`timescale 1ps/1ps

module tb_iddr_cdc_async #(
    parameter integer TCLK_HALF = 5000,   // trace_clk half period ps (100MHz)
    parameter integer REF_HALF  = 2500,   // ref_200m half period ps (200MHz)
    parameter integer PH0       = 0,      // initial trace_clk phase (ps)
    parameter integer RUN_NS    = 8000
);
    reg ref_200m = 1'b0;
    always #(REF_HALF) ref_200m = ~ref_200m;
    reg trace_clk = 1'b0;
    initial begin #(PH0); forever #(TCLK_HALF) trace_clk = ~trace_clk; end

    // edge-aligned walking-1s: one-hot rotates each trace_clk edge
    reg [3:0] dpins = 4'h1;
    always @(posedge trace_clk) dpins <= {dpins[2:0], dpins[3]};
    always @(negedge trace_clk) dpins <= {dpins[2:0], dpins[3]};

    // real dual-edge IDDR (SAME_EDGE_PIPELINED behavioural): sample on edges,
    // present both on next posedge.
    reg [3:0] cr=0, cf=0, iddr_a=0, iddr_b=0;
    always @(posedge trace_clk) cr <= dpins;
    always @(negedge trace_clk) cf <= dpins;
    always @(posedge trace_clk) begin iddr_a <= cr; iddr_b <= cf; end

    // verbatim g_iddr CDC, ATOMIC byte bus (no per-bit skew)
    reg [7:0] tclk_byte = 8'b0;
    reg       tclk_tgl  = 1'b0;
    always @(posedge trace_clk) begin
        tclk_byte <= {iddr_b, iddr_a};
        tclk_tgl  <= ~tclk_tgl;
    end
    reg [2:0] tgl_sync = 3'b0;
    reg [7:0] byte_s0=0, byte_s1=0;
    always @(posedge ref_200m) begin
        tgl_sync <= {tgl_sync[1:0], tclk_tgl};
        byte_s0  <= tclk_byte;
        byte_s1  <= byte_s0;
    end
    wire cap_valid = tgl_sync[2] ^ tgl_sync[1];
    wire [7:0] cap_byte = byte_s1;

    integer total=0, bad=0, lo5=0, hia=0, dup=0, drop=0;
    reg [7:0] b;
    reg [3:0] exp_lo, exp_hi;    // no strict expectation (phase unknown); use walk-nib check
    function is_walk_nib(input [3:0] n); is_walk_nib=(n==1)||(n==2)||(n==4)||(n==8); endfunction
    always @(posedge ref_200m) if (cap_valid) begin
        b=cap_byte; total=total+1;
        if(!is_walk_nib(b[3:0])||!is_walk_nib(b[7:4])) begin
            bad=bad+1;
            if(b[3:0]==4'h5||b[7:4]==4'h5) lo5=lo5+1;
            if(b[3:0]==4'ha||b[7:4]==4'ha) hia=hia+1;
        end
    end
    initial begin
        #(RUN_NS*1000);
        $display("TCLK_HALF=%0dps(=%0dMHz) PH0=%0d: bytes=%0d bad=%0d (%0d.%02d%%) 0x5=%0d 0xa=%0d",
            TCLK_HALF, 1000000/(2*TCLK_HALF), PH0, total, bad,
            total?(100*bad)/total:0, total?((10000*bad)/total)%100:0, lo5, hia);
        $finish;
    end
endmodule
