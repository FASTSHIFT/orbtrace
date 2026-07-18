// tb_iddr_cdc.v — isolate the IDDR-branch trace_clk->ref_200m CDC from
// trace_capture_a7.v and feed it an IDEAL walking-1s DDR waveform.
//
// Goal: reproduce (or refute) the blue-team "0x5/0xa" fall-nibble error under
// ZERO signal-integrity / ZERO duty-cycle distortion. If the error appears
// with a perfect 50% duty clock and clean data, the root cause is the DIGITAL
// CDC, not the analog TRACECLK duty cycle (proposal 16 §"2.5% 的谜底").
//
// The DUT below is copied VERBATIM from the g_iddr branch of
// trace_capture_a7.v (the tclk_byte/tclk_tgl launch + tgl_sync/byte_s0/byte_s1
// receiver + cap_valid/cap_byte). Only the Xilinx IDDR primitive is replaced
// by an ideal behavioural DDR sampler; everything downstream is identical.

`timescale 1ps/1ps

module tb_iddr_cdc;
    reg trace_clk = 1'b0;
    reg ref_200m  = 1'b0;

    // ref_200m = 200 MHz -> 2500 ps half period.
    always #2500 ref_200m = ~ref_200m;

    // trace_clk with EXACT 50% duty (both halves identical) -> NO duty distortion.
    // 12.0 MHz -> half period 41667 ps.
    always #41667 trace_clk = ~trace_clk;

    // walking-1s nibble sequence 4 -> 2 -> 1 -> 8 -> 4 ...
    reg [3:0] seq [0:3];
    integer   ridx = 0;
    initial begin
        seq[0]=4'h4; seq[1]=4'h2; seq[2]=4'h1; seq[3]=4'h8;
    end

    // per-bit launch skew on the {iddr_b,iddr_a} byte bus (ps). 0 = atomic bus.
    parameter integer BITSKEW = 200;

    reg [3:0] iddr_a = 4'h4;   // rising-edge nibble
    reg [3:0] iddr_b = 4'h2;   // falling-edge nibble

    always @(posedge trace_clk) begin
        iddr_a <= seq[ridx % 4];
        iddr_b <= seq[(ridx+1) % 4];
        ridx   <= ridx + 2;
    end

    // ================= DUT: verbatim g_iddr CDC =================
    reg [7:0] tclk_byte = 8'b0;
    reg       tclk_tgl  = 1'b0;

    integer bk;
    reg v;
    always @(posedge trace_clk) begin
        tclk_tgl <= ~tclk_tgl;
        for (bk = 0; bk < 8; bk = bk + 1) begin
            v = (bk < 4) ? iddr_a[bk] : iddr_b[bk-4];
            tclk_byte[bk] <= #(BITSKEW * (bk % 4)) v;
        end
    end

    // receiver domain (ref_200m) — identical to RTL
    reg [2:0] tgl_sync = 3'b0;
    reg [7:0] byte_s0 = 8'b0, byte_s1 = 8'b0;
    always @(posedge ref_200m) begin
        tgl_sync <= {tgl_sync[1:0], tclk_tgl};
        byte_s0  <= tclk_byte;
        byte_s1  <= byte_s0;
    end
    wire cap_valid = tgl_sync[2] ^ tgl_sync[1];
    wire [7:0] cap_byte = byte_s1;
    // ============================================================

    integer total = 0, bad = 0;
    integer bad_lo5 = 0, bad_hi_a = 0;
    reg [7:0] b;

    function is_walk_nib(input [3:0] n);
        is_walk_nib = (n==4'h1)||(n==4'h2)||(n==4'h4)||(n==4'h8);
    endfunction

    always @(posedge ref_200m) begin
        if (cap_valid) begin
            b = cap_byte;
            total = total + 1;
            if (!is_walk_nib(b[3:0]) || !is_walk_nib(b[7:4])) begin
                bad = bad + 1;
                if (b[3:0] == 4'h5) bad_lo5 = bad_lo5 + 1;
                if (b[7:4] == 4'ha) bad_hi_a = bad_hi_a + 1;
                if (bad <= 20)
                    $display("  bad #%0d: 0x%02x (lo=%1x hi=%1x) t=%0t",
                             bad, b, b[3:0], b[7:4], $time);
            end
        end
    end

    initial begin
        #4000000;
        $display("\n=== RESULT (BITSKEW=%0d ps, ideal 50%% duty, clean data) ===",
                 BITSKEW);
        $display("captured bytes = %0d", total);
        if (total > 0)
            $display("bad bytes      = %0d  (%0d.%02d%%)",
                     bad, (100*bad)/total, ((10000*bad)/total)%100);
        $display("  lo-nibble==0x5 : %0d", bad_lo5);
        $display("  hi-nibble==0xa : %0d", bad_hi_a);
        $finish;
    end
endmodule
