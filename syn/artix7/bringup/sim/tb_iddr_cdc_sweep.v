// tb_iddr_cdc_sweep.v — same verbatim g_iddr CDC as tb_iddr_cdc.v, but
// parametrised on trace_clk half period so we can sweep TRACECLK and watch the
// toggle CDC (cap_valid = tgl_sync[2]^tgl_sync[1]) break as TRACECLK -> ref/2.
//
// Two independent stressors, BOTH digital (zero SI, exact 50% duty):
//   1. byte-bus tearing: tclk_byte bits settle with per-bit skew, so a ref
//      sample landing in the launch window latches a MIX of period k and k+1.
//   2. toggle undersample: at TRACECLK >= ~ref/2 the single toggle edge is
//      sampled <2x, so bytes are dropped/duplicated (walking rotation breaks).
//
// Reports total/bad and specifically the 0x5 (=4|1) and 0xa (=2|8) OR-tears,
// which are seq[k]|seq[k+2] — SAME-edge nibbles one full period apart. If these
// appear with an ideal clock, proposal 16's "duty cycle" root cause is refuted.

`timescale 1ps/1ps

module tb_iddr_cdc_sweep #(
    parameter integer THALF  = 41667,  // trace_clk half period (ps)
    parameter integer BITSKEW = 300,   // per-bit launch skew (ps)
    parameter integer RUN_NS = 6000    // sim length (ns)
);
    reg trace_clk = 1'b0;
    reg ref_200m  = 1'b0;
    always #2500 ref_200m = ~ref_200m;
    always #(THALF) trace_clk = ~trace_clk;

    reg [3:0] seq [0:3];
    integer   ridx = 0;
    initial begin seq[0]=4'h4; seq[1]=4'h2; seq[2]=4'h1; seq[3]=4'h8; end

    reg [3:0] iddr_a = 4'h4, iddr_b = 4'h2;
    always @(posedge trace_clk) begin
        iddr_a <= seq[ridx % 4];
        iddr_b <= seq[(ridx+1) % 4];
        ridx   <= ridx + 2;
    end

    // verbatim g_iddr CDC ---------------------------------------------------
    reg [7:0] tclk_byte = 8'b0;
    reg       tclk_tgl  = 1'b0;
    integer bk; reg vv;
    always @(posedge trace_clk) begin
        tclk_tgl <= ~tclk_tgl;
        for (bk = 0; bk < 8; bk = bk + 1) begin
            vv = (bk < 4) ? iddr_a[bk] : iddr_b[bk-4];
            tclk_byte[bk] <= #(BITSKEW * (bk % 4)) vv;
        end
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
    // -----------------------------------------------------------------------

    integer total=0, bad=0, lo5=0, hia=0;
    reg [7:0] b;
    function is_walk_nib(input [3:0] n);
        is_walk_nib=(n==1)||(n==2)||(n==4)||(n==8);
    endfunction
    always @(posedge ref_200m) if (cap_valid) begin
        b = cap_byte; total = total + 1;
        if (!is_walk_nib(b[3:0]) || !is_walk_nib(b[7:4])) begin
            bad = bad + 1;
            if (b[3:0]==4'h5 || b[7:4]==4'h5) lo5 = lo5 + 1;
            if (b[3:0]==4'ha || b[7:4]==4'ha) hia = hia + 1;
        end
    end

    integer tclk_khz;
    initial begin
        tclk_khz = 1000000000 / (2*THALF);   // kHz = 1e12ps/s / (2*THALF)
        #(RUN_NS*1000);
        $display("TRACECLK=%0dkHz THALF=%0dps SKEW=%0dps  bytes=%0d bad=%0d (%0d.%02d%%)  0x5-tears=%0d 0xa-tears=%0d",
                 tclk_khz, THALF, BITSKEW,
                 total, bad,
                 (total>0)? (100*bad)/total:0,
                 (total>0)? ((10000*bad)/total)%100:0,
                 lo5, hia);
        $finish;
    end
endmodule
