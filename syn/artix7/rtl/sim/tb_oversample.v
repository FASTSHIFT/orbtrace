// tb_oversample — functional check of trace_capture_a7 OVERSAMPLE mode.
//
// Models an EDGE-ALIGNED TPIU source: TRACECLK and the 4 data lanes change
// on the same instant (data transition == clock edge). A known nibble
// sequence is driven, one nibble per TRACECLK edge (DDR). The DUT must
// recover, mid-eye, trace_a = nibble at the rising edge, trace_b = nibble at
// the falling edge — matching what the logic-analyser reconstructs.
`default_nettype none
`timescale 1ns/1ps

module tb_oversample;
    reg ref_200m = 0;
    always #2.5 ref_200m = ~ref_200m;   // 200 MHz

    reg rst = 1;

    // TRACECLK: 2.5 MHz -> period 400 ns, half-bit 200 ns (40 ref cycles).
    reg trace_clk_p = 0;
    always #200 trace_clk_p = ~trace_clk_p;

    // Edge-aligned data: drive a new nibble on EACH trace_clk edge.
    reg [3:0] trace_data_p = 4'h0;
    // Known sequence of nibbles, one per edge.
    reg [3:0] seq [0:31];
    integer ei = 0;
    integer k;
    initial begin
        for (k = 0; k < 32; k = k + 1) seq[k] = k[3:0] ^ 4'b1010;
    end
    // Change data exactly on trace_clk edges (edge-aligned source).
    always @(posedge trace_clk_p or negedge trace_clk_p) begin
        trace_data_p <= seq[ei % 32];
        ei = ei + 1;
    end

    wire        trace_clk;
    wire [3:0]  trace_a, trace_b;
    wire        idelayctrl_rdy;

    trace_capture_a7 #(
        .CLK_BUF("BUFG"),
        .CAP_METHOD("OVERSAMPLE"),
        .EYE_DELAY(8)            // 8 ref cycles = 40 ns after edge, mid of 200 ns half-bit
    ) dut (
        .rst(rst), .ref_200m(ref_200m),
        .trace_clk_p(trace_clk_p), .trace_data_p(trace_data_p),
        .tap_data0(5'd16), .tap_data1(5'd16), .tap_data2(5'd16), .tap_data3(5'd16),
        .tap_clk(5'd0), .tap_load(1'b0),
        .test_en(1'b0), .test_clk(1'b0), .test_data(4'b0),
        .eye_delay_rt(8'd0),
        .cap_clear(1'b0),
        .trace_clk(trace_clk), .trace_a(trace_a), .trace_b(trace_b),
        .idelayctrl_rdy(idelayctrl_rdy)
    );

    // Reference model: what nibble was driven at the most recent rising / falling edge.
    reg [3:0] exp_a, exp_b;
    integer rising_idx = -1, falling_idx = -1;
    always @(posedge trace_clk_p) begin
        // the nibble driven at THIS rising edge is seq[ei] (ei not yet incremented
        // here? it is non-blocking + blocking mix) — capture from seq via index.
    end

    integer errors = 0;
    integer checks = 0;

    // Sample the DUT outputs near the END of each half-bit (where they are
    // stable and updated). Compare against the nibble that the LA would have
    // sampled mid-eye for that half-bit.
    // Easiest robust check: at a point well inside each half bit, trace_a (after
    // a rising edge) or trace_b (after a falling edge) must equal the nibble
    // driven during that half bit.

    reg [3:0] cur_nib;
    reg       cur_is_rising;
    // Track the nibble + edge type for the current half-bit.
    initial begin
        @(negedge rst);
        forever begin
            @(posedge trace_clk_p);
            cur_nib = trace_data_p;        // nibble just driven on this rising edge
            cur_is_rising = 1;
            #160;                           // 160 ns into the 200 ns half-bit (mid-late, stable)
            checks = checks + 1;
            if (trace_a !== cur_nib) begin
                errors = errors + 1;
                $display("[%0t] RISING mismatch: trace_a=%h expected=%h", $time, trace_a, cur_nib);
            end
            @(negedge trace_clk_p);
            cur_nib = trace_data_p;
            cur_is_rising = 0;
            #160;
            checks = checks + 1;
            if (trace_b !== cur_nib) begin
                errors = errors + 1;
                $display("[%0t] FALLING mismatch: trace_b=%h expected=%h", $time, trace_b, cur_nib);
            end
        end
    end

    initial begin
        #50 rst = 0;
        #20000;
        $display("checks=%0d errors=%0d -> %s", checks, errors,
                 (errors == 0 && checks > 10) ? "PASS" : "FAIL");
        $finish;
    end
endmodule

`default_nettype wire
