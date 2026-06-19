// swo_replay_tb
// =============
// Replay a REAL captured SWO line (logic-analyser waveform, exported by
// decode/swo_csv_to_simvec.py) through the actual FPGA SWO front-end RTL
//   swo_pulse_capture -> swo_nrz_decode -> swo_uart_decode
// and dump the recovered bytes to a file. This turns the "software UART decode
// matches" result into a HARDWARE-RTL result (red-team r17 Q2/Q5: prove the
// Verilog front-end, not just a Python model, recovers the same bytes).
//
// The .mem file is one bit per ref_200m cycle (LA samples upsampled x4 from
// 50 MHz to 200 MHz). bitlen = 200 MHz / 2 Mbaud = 100 ref cycles/bit.
//
// Build/run (see decode/run_swo_replay.sh):
//   iverilog -g2012 -DVEC='"/tmp/swo_vec.mem"' -DNBITS=1600000 \
//       -o /tmp/swo_replay rtl/sim/swo_replay_tb.v rtl/swo_*.v
//   vvp /tmp/swo_replay         # writes /tmp/swo_rtl_bytes.hex

`timescale 1ns/1ps
`default_nettype none

`ifndef VEC
 `define VEC "/tmp/swo_vec.mem"
`endif
`ifndef NBITS
 `define NBITS 1600000
`endif
`ifndef OUTHEX
 `define OUTHEX "/tmp/swo_rtl_bytes.hex"
`endif

module swo_replay_tb;
    localparam CW = 16;
    localparam integer NBITS  = `NBITS;
    localparam [CW-1:0] BITLEN = 16'd100;   // 200MHz / 2Mbaud

    reg clk = 0;
    always #2.5 clk = ~clk;   // 200 MHz
    reg rst = 1;

    // line samples, one bit per ref cycle
    reg vec [0:NBITS-1];
    integer idx;
    reg swo;

    initial $readmemb(`VEC, vec);

    // drive swo from the vector, one bit per clock
    always @(posedge clk) begin
        if (rst) begin
            idx <= 0;
            swo <= 1'b1;
        end else if (idx < NBITS) begin
            swo <= vec[idx];
            idx <= idx + 1;
        end
    end

    // DUT chain (same modules synthesised to the FPGA)
    wire        p_valid, p_level;
    wire [CW-1:0] p_count;
    swo_pulse_capture #(.CW(CW), .IDLE_FLUSH(16'd4000)) u_cap (
        .clk(clk), .rst(rst), .swo_in(swo),
        .pulse_valid(p_valid), .pulse_level(p_level), .pulse_count(p_count)
    );
    wire bvld, bval;
    swo_nrz_decode #(.CW(CW)) u_nrz (
        .clk(clk), .rst(rst),
        .pulse_valid(p_valid), .pulse_level(p_level), .pulse_count(p_count),
        .bit_valid(bvld), .bit_value(bval), .bitlen(BITLEN)
    );
    wire yvld; wire [7:0] ydata;
    swo_uart_decode u_uart (
        .clk(clk), .rst(rst),
        .bit_valid(bvld), .bit_value(bval),
        .byte_valid(yvld), .byte_data(ydata)
    );

    // collect bytes
    integer fout;
    integer nbytes = 0;
    initial fout = $fopen(`OUTHEX, "w");
    always @(posedge clk) begin
        if (!rst && yvld) begin
            $fwrite(fout, "%02x\n", ydata);
            nbytes = nbytes + 1;
        end
    end

    initial begin
        repeat (10) @(posedge clk);
        rst = 0;
        // run until the vector is consumed + drain
        wait (idx >= NBITS - 1);
        repeat (BITLEN*20) @(posedge clk);
        $fclose(fout);
        $display("SWO replay done: recovered %0d bytes -> %s", nbytes, `OUTHEX);
        $finish;
    end

    initial begin
        #200_000_000;   // safety timeout (200 ms sim time)
        $display("FAIL: timeout (recovered %0d bytes)", nbytes);
        $fclose(fout);
        $finish;
    end
endmodule

`default_nettype wire
