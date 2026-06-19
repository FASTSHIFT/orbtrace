// swo_chain_tb
// ============
// Stage-A simulation (提案 15, red-team r17: "下游零改动必须实测，不能靠理论同构").
// Drives a synthetic SWO NRZ (UART 8N1) line through the full Verilog chain
//   swo_pulse_capture -> swo_nrz_decode -> swo_uart_decode
// and checks that the recovered bytes equal the transmitted bytes.
//
// The SWO line is generated in the testbench at BIT_CYCLES ref cycles per UART
// bit (= the same bitlen handed to swo_nrz_decode), 8N1 LSB-first, with idle
// high between frames — exactly what an STM32 TPIU NRZ SWO output looks like.
// This validates the three modules end to end before any hardware.

`timescale 1ns/1ps
`default_nettype none

module swo_chain_tb;
    localparam CW = 16;
    localparam BIT_CYCLES = 20;   // ref cycles per UART bit (small for fast sim)

    reg clk = 0;
    always #2.5 clk = ~clk;       // 200 MHz ref_200m

    reg rst = 1;

    // ---- SWO line driver -------------------------------------------------
    reg swo = 1'b1;               // idle high

    // bytes to transmit (cover TPIU-ish + edge values)
    localparam NB = 8;
    reg [7:0] tx [0:NB-1];
    initial begin
        tx[0]=8'h00; tx[1]=8'hFF; tx[2]=8'h55; tx[3]=8'hAA;
        tx[4]=8'h08; tx[5]=8'h7F; tx[6]=8'h01; tx[7]=8'h88;
    end

    integer i, b;
    task send_byte(input [7:0] d);
        begin
            // start bit (0)
            swo = 1'b0;
            repeat (BIT_CYCLES) @(posedge clk);
            // 8 data bits, LSB first
            for (b = 0; b < 8; b = b + 1) begin
                swo = d[b];
                repeat (BIT_CYCLES) @(posedge clk);
            end
            // stop bit (1)
            swo = 1'b1;
            repeat (BIT_CYCLES) @(posedge clk);
            // a little idle high between frames
            repeat (BIT_CYCLES*2) @(posedge clk);
        end
    endtask

    // ---- DUT chain -------------------------------------------------------
    wire        p_valid, p_level;
    wire [CW-1:0] p_count;
    swo_pulse_capture #(.CW(CW), .IDLE_FLUSH(16'd200)) u_cap (
        .clk(clk), .rst(rst), .swo_in(swo),
        .pulse_valid(p_valid), .pulse_level(p_level), .pulse_count(p_count)
    );

    wire        bvld, bval;
    swo_nrz_decode #(.CW(CW)) u_nrz (
        .clk(clk), .rst(rst),
        .pulse_valid(p_valid), .pulse_level(p_level), .pulse_count(p_count),
        .bit_valid(bvld), .bit_value(bval),
        .bitlen(BIT_CYCLES[CW-1:0])
    );

    wire       yvld;
    wire [7:0] ydata;
    swo_uart_decode u_uart (
        .clk(clk), .rst(rst),
        .bit_valid(bvld), .bit_value(bval),
        .byte_valid(yvld), .byte_data(ydata)
    );

    // ---- capture recovered bytes ----------------------------------------
    reg [7:0] rx [0:63];
    integer   rxn = 0;
    always @(posedge clk) begin
        if (!rst && yvld) begin
            rx[rxn] = ydata;
            $display("  recovered byte[%0d] = 0x%02x", rxn, ydata);
            rxn = rxn + 1;
        end
    end

    // ---- stimulus + check -----------------------------------------------
    integer errors = 0;
    initial begin
        repeat (10) @(posedge clk);
        rst = 0;
        repeat (10) @(posedge clk);

        for (i = 0; i < NB; i = i + 1)
            send_byte(tx[i]);

        // let the chain drain
        repeat (BIT_CYCLES*40) @(posedge clk);

        // compare
        if (rxn != NB) begin
            $display("FAIL: recovered %0d bytes, expected %0d", rxn, NB);
            errors = errors + 1;
        end else begin
            for (i = 0; i < NB; i = i + 1) begin
                if (rx[i] !== tx[i]) begin
                    $display("FAIL: byte[%0d] got 0x%02x expected 0x%02x",
                             i, rx[i], tx[i]);
                    errors = errors + 1;
                end
            end
        end

        if (errors == 0)
            $display("PASS: SWO chain recovered all %0d bytes", NB);
        else
            $display("RESULT: %0d error(s)", errors);
        $finish;
    end

    // safety timeout
    initial begin
        #5_000_000;
        $display("FAIL: timeout");
        $finish;
    end

endmodule

`default_nettype wire
