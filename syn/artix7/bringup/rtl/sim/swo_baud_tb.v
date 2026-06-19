// swo_baud_tb
// ===========
// Robustness sim (red-team r17 Q5): quantify NRZ decoder sensitivity to a
// baud-rate mismatch between the SWO line and the configured `bitlen`. SWO NRZ
// is asynchronous, so if the target clock drifts (or bitlen is set wrong) the
// UART sampling walks off the bit centre and bytes corrupt. We drive the line
// at LINE_BIT ref cycles/bit but tell the decoder bitlen=CFG_BIT, sweeping the
// mismatch, and report how many of NB bytes survive.
//
// Run with: iverilog -g2012 -DCFG_BIT=<n> ... (default exercises a few values
// via the internal sweep below).

`timescale 1ns/1ps
`default_nettype none

module swo_baud_tb;
    localparam CW = 16;
    localparam LINE_BIT = 100;     // true line bit length (ref cycles) = 2 Mbaud@200MHz

    reg clk = 0;
    always #2.5 clk = ~clk;
    reg rst = 1;
    reg swo = 1'b1;

    localparam NB = 16;
    reg [7:0] tx [0:NB-1];
    integer k;
    initial for (k = 0; k < NB; k = k + 1) tx[k] = (k*37 + 5) & 8'hFF;

    reg [CW-1:0] cfg_bit;          // configured bitlen (may mismatch LINE_BIT)

    integer b;
    task send_byte(input [7:0] d);
        begin
            swo = 1'b0; repeat (LINE_BIT) @(posedge clk);
            for (b = 0; b < 8; b = b + 1) begin
                swo = d[b]; repeat (LINE_BIT) @(posedge clk);
            end
            swo = 1'b1; repeat (LINE_BIT) @(posedge clk);
            repeat (LINE_BIT) @(posedge clk);   // 1 idle bit between frames
        end
    endtask

    wire        p_valid, p_level;
    wire [CW-1:0] p_count;
    swo_pulse_capture #(.CW(CW), .IDLE_FLUSH(16'd1500)) u_cap (
        .clk(clk), .rst(rst), .swo_in(swo),
        .pulse_valid(p_valid), .pulse_level(p_level), .pulse_count(p_count)
    );
    wire bvld, bval;
    swo_nrz_decode #(.CW(CW)) u_nrz (
        .clk(clk), .rst(rst),
        .pulse_valid(p_valid), .pulse_level(p_level), .pulse_count(p_count),
        .bit_valid(bvld), .bit_value(bval), .bitlen(cfg_bit)
    );
    wire yvld; wire [7:0] ydata;
    swo_uart_decode u_uart (
        .clk(clk), .rst(rst),
        .bit_valid(bvld), .bit_value(bval),
        .byte_valid(yvld), .byte_data(ydata)
    );

    reg [7:0] rx [0:127];
    integer rxn = 0;
    always @(posedge clk) if (!rst && yvld) begin rx[rxn]=ydata; rxn=rxn+1; end

    integer i, good;
    integer fails;
    task run_case(input [CW-1:0] cb, input integer expect_ok);
        begin
            // reset chain + counters
            rst = 1; rxn = 0; cfg_bit = cb;
            repeat (8) @(posedge clk);
            rst = 0; repeat (8) @(posedge clk);
            for (i = 0; i < NB; i = i + 1) send_byte(tx[i]);
            repeat (LINE_BIT*16) @(posedge clk);   // drain > IDLE_FLUSH to flush last byte
            // count matched bytes in order
            good = 0;
            for (i = 0; i < NB && i < rxn; i = i + 1)
                if (rx[i] === tx[i]) good = good + 1;
            $display("  cfg_bit=%0d (line=%0d, %+0d%%): recovered=%0d  in-order-correct=%0d/%0d %s",
                     cb, LINE_BIT, (($signed(cb)-LINE_BIT)*100)/LINE_BIT, rxn, good, NB,
                     (expect_ok ? "[expect PASS]" : "[expect DEGRADE]"));
            // a "good" baud (<=5% mismatch) must recover all bytes in order
            if (expect_ok && good != NB) begin
                $display("    FAIL: expected all %0d bytes at this baud", NB);
                fails = fails + 1;
            end
        end
    endtask

    initial begin
        fails = 0;
        run_case(100, 1);   //  0%   must pass
        run_case(95,  1);   // -5%   must pass
        run_case(105, 1);   // +5%   must pass
        run_case(90,  0);   // -10%  documented degrade (no assert)
        run_case(110, 1);   // +10%  observed pass
        if (fails == 0) $display("PASS: NRZ baud tolerance within +/-5%% recovers all bytes");
        else            $display("RESULT: %0d baud case(s) failed", fails);
        $finish;
    end

    initial begin #20_000_000; $display("timeout"); $finish; end
endmodule

`default_nettype wire
