// swo_iddr_tb
// ===========
// Validate the IDDR double-edge SWO front-end (提案 17): model the IDDR by
// feeding 2 oversamples per sample_clk cycle (rising-edge then falling-edge of
// the SWO line, in 500 MSa/s order), through
//   swo_iddr_capture -> swo_nrz_decode -> swo_uart_decode
// and check that the transmitted UART bytes are recovered.
//
// The "line" is generated at SAMP_PER_BIT samples in 500 MSa/s ticks per UART
// bit. bitlen handed to swo_nrz_decode is the same SAMP_PER_BIT (count units
// are 500 MSa/s half-cycles, matching swo_iddr_capture.pulse_count).

`timescale 1ns/1ps
`default_nettype none

module swo_iddr_tb;
    localparam CW = 16;
    localparam integer SAMP_PER_BIT = 16;   // 500 MSa/s ticks per UART bit

    reg sclk = 0;
    always #2 sclk = ~sclk;     // 250 MHz sample clock (period 4 ns)
    reg rst = 1;

    // ---- SWO line model: a flat array of 500 MSa/s samples ----
    localparam NB = 8;
    reg [7:0] tx [0:NB-1];
    initial begin
        tx[0]=8'h00; tx[1]=8'hFF; tx[2]=8'h55; tx[3]=8'hAA;
        tx[4]=8'h08; tx[5]=8'h7F; tx[6]=8'h01; tx[7]=8'h88;
    end

    // Build the half-cycle sample sequence (idle + frames), then feed 2/cycle.
    localparam integer MAXS = (NB*10 + 8) * SAMP_PER_BIT + 64;
    reg lvl [0:MAXS-1];
    integer ns; integer b, k, j, t;
    initial begin
        ns = 0;
        for (j = 0; j < SAMP_PER_BIT; j = j + 1) lvl[ns++] = 1'b1; // idle
        for (b = 0; b < NB; b = b + 1) begin
            for (j = 0; j < SAMP_PER_BIT; j = j + 1) lvl[ns++] = 1'b0;      // start
            for (k = 0; k < 8; k = k + 1)
                for (j = 0; j < SAMP_PER_BIT; j = j + 1) lvl[ns++] = tx[b][k];
            for (j = 0; j < SAMP_PER_BIT; j = j + 1) lvl[ns++] = 1'b1;      // stop
            for (j = 0; j < SAMP_PER_BIT; j = j + 1) lvl[ns++] = 1'b1;      // 1 idle bit
        end
        // long idle tail so the last byte's stop flushes
        for (j = 0; j < SAMP_PER_BIT*40; j = j + 1) lvl[ns++] = 1'b1;
    end

    // feed 2 samples per cycle: s_d1 = lvl[2i], s_d2 = lvl[2i+1]
    reg [31:0] si = 0;
    reg s_d1, s_d2;
    always @(posedge sclk) begin
        if (rst) begin si <= 0; s_d1 <= 1; s_d2 <= 1; end
        else begin
            s_d1 <= (si   < ns) ? lvl[si]   : 1'b1;
            s_d2 <= (si+1 < ns) ? lvl[si+1] : 1'b1;
            si   <= si + 2;
        end
    end

    // ---- DUT chain ----
    wire        p_valid, p_level;
    wire [CW-1:0] p_count;
    swo_iddr_capture #(.CW(CW), .IDLE_FLUSH(16'd2000)) u_cap (
        .sample_clk(sclk), .rst(rst), .s_d1(s_d1), .s_d2(s_d2),
        .pulse_valid(p_valid), .pulse_level(p_level), .pulse_count(p_count)
    );
    wire bvld, bval;
    swo_nrz_decode #(.CW(CW)) u_nrz (
        .clk(sclk), .rst(rst),
        .pulse_valid(p_valid), .pulse_level(p_level), .pulse_count(p_count),
        .bit_valid(bvld), .bit_value(bval), .bitlen(SAMP_PER_BIT[CW-1:0])
    );
    wire yvld; wire [7:0] ydata;
    swo_uart_decode u_uart (
        .clk(sclk), .rst(rst),
        .bit_valid(bvld), .bit_value(bval),
        .byte_valid(yvld), .byte_data(ydata)
    );

    reg [7:0] rx [0:63];
    integer rxn = 0;
    always @(posedge sclk) if (!rst && yvld) begin
        rx[rxn] = ydata;
        $display("  recovered byte[%0d] = 0x%02x", rxn, ydata);
        rxn = rxn + 1;
    end

    integer i, errors = 0;
    initial begin
        repeat (10) @(posedge sclk);
        rst = 0;
        wait (si >= ns);
        repeat (SAMP_PER_BIT*60) @(posedge sclk);
        if (rxn != NB) begin
            $display("FAIL: recovered %0d of %0d bytes", rxn, NB);
            errors = errors + 1;
        end else for (i = 0; i < NB; i = i + 1)
            if (rx[i] !== tx[i]) begin
                $display("FAIL byte[%0d]: got %02x exp %02x", i, rx[i], tx[i]);
                errors = errors + 1;
            end
        if (errors == 0) $display("PASS: IDDR SWO chain recovered all %0d bytes", NB);
        else             $display("RESULT: %0d error(s)", errors);
        $finish;
    end
    initial begin #2_000_000; $display("FAIL: timeout"); $finish; end
endmodule

`default_nettype wire
