// tb_dsl_replay — replay a real logic-analyser .dsl capture (as a memh of
// per-sample pin states) into trace_capture_a7 (OVERSAMPLE) + the CAP_RAW
// byte-pack path, and dump the recovered byte stream.
//
// This drives the EXACT pin waveform the LA saw (which dsl_parse decodes to
// 818 flash anchors) into the RTL. If the RTL produces a decodable stream the
// front-end is correct; if not, the bug is in the RTL and observable here.
//
//   stim byte per sample: bit4=TRACECLK bit3=TD3 bit2=TD2 bit1=TD1 bit0=TD0
//   sample period: 20 ns (50 MSa/s, matches the DSLogic capture)
//   ref_200m:      200 MHz (5 ns)
//
// Plusargs:
//   +stim=<file>    memh stimulus (default /tmp/dsl_stim.memh)
//   +nsamp=<n>      number of samples to replay (default 300000)
//   +out=<file>     output raw-byte hex dump (default /tmp/sim_raw.hex)
//   +eye=<n>        EYE_DELAY override (default 4)
`default_nettype none
`timescale 1ns/1ps

module tb_dsl_replay;
    // ---- ref clock 200 MHz ----
    reg ref_200m = 0;
    always #2.5 ref_200m = ~ref_200m;

    reg rst = 1;

    // ---- stimulus memory ----
    integer NSAMP = 300000;
    reg [7:0] stim [0:52_000_000-1];
    reg [8*256-1:0] stim_file;
    reg [8*256-1:0] out_file;

    reg        trace_clk_p = 0;
    reg [3:0]  trace_data_p = 0;

    wire        trace_clk;
    wire [3:0]  trace_a, trace_b;
    wire        idelayctrl_rdy;
    wire [7:0]  cap_byte;
    wire        cap_valid;

    // DUT — EYE_DELAY overridable at compile time via -P tb_dsl_replay.EYE_DELAY=<n>
    parameter EYE_DELAY = 4;
    trace_capture_a7 #(
        .CLK_BUF("BUFG"),
        .CAP_METHOD("OVERSAMPLE"),
        .EYE_DELAY(EYE_DELAY)
    ) dut (
        .rst(rst), .ref_200m(ref_200m),
        .trace_clk_p(trace_clk_p), .trace_data_p(trace_data_p),
        .tap_data0(5'd16), .tap_data1(5'd16), .tap_data2(5'd16), .tap_data3(5'd16),
        .tap_load(1'b0),
        .test_en(1'b0), .test_clk(1'b0), .test_data(4'b0),
        .eye_delay_rt(8'd0),
        .cap_clear(1'b0),
        .trace_clk(trace_clk), .trace_a(trace_a), .trace_b(trace_b),
        .cap_byte(cap_byte), .cap_valid(cap_valid),
        .idelayctrl_rdy(idelayctrl_rdy)
    );

    // ---- CAP_RAW byte capture via the glitch-free ref_200m strobe ----
    // Mirrors trace_stream_top g_raw: write cap_byte on (clk200, cap_valid).
    integer outfd;
    integer nbytes = 0;
    reg cap_en = 0;
    always @(posedge ref_200m) begin
        if (cap_en && cap_valid) begin
            $fwriteh(outfd, "%02x\n", cap_byte);
            nbytes = nbytes + 1;
        end
    end

    // ---- replay driver ----
    integer si;
    reg [7:0] s;
    initial begin
        if (!$value$plusargs("stim=%s", stim_file)) stim_file = "/tmp/dsl_stim.memh";
        if (!$value$plusargs("nsamp=%d", NSAMP))    NSAMP = 300000;
        if (!$value$plusargs("out=%s", out_file))   out_file = "/tmp/sim_raw.hex";

        $readmemh(stim_file, stim);
        outfd = $fopen(out_file, "w");

        // release reset, let IDELAYCTRL go ready
        #50 rst = 0;
        #50 cap_en = 1;

        for (si = 0; si < NSAMP; si = si + 1) begin
            s = stim[si];
            trace_clk_p  <= s[4];
            trace_data_p <= s[3:0];
            #20;   // 50 MSa/s sample period
        end

        #200;
        $fclose(outfd);
        $display("tb_dsl_replay: replayed %0d samples -> %0d bytes (%s) [EYE_DELAY=%0d]",
                 NSAMP, nbytes, out_file, EYE_DELAY);
        $finish;
    end
endmodule

`default_nettype wire
