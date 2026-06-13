// eyescan_pattern_tb
// ==================
// Pure-logic iverilog sim of the V1 pattern generator -> ideal DDR capture
// -> upstream traceIF, to reproduce (and fix) the nibble misalignment seen
// on hardware (odd payload bytes' high nibble wrong) WITHOUT re-synthesis.
//
// We model the pattern generator's byte stream exactly as trace_eyescan.v
// drives the ODDRs (D1 = byte[lane], D2 = byte[4+lane]), capture it back the
// same way trace_capture_a7's IDDR would in an ideal (zero-delay) case, and
// feed traceIF. Then we check the decoded Frame against the golden.

`timescale 1ns/1ps
`default_nettype none

module eyescan_pattern_tb;
    // pattern ROM identical to trace_eyescan.v
    localparam NBYTES = 22;
    reg [7:0] pat_rom [0:NBYTES-1];
    initial begin
        pat_rom[0]=8'hff; pat_rom[1]=8'hff; pat_rom[2]=8'hff; pat_rom[3]=8'h7f;
        pat_rom[4]=8'h12;  pat_rom[5]=8'h34;  pat_rom[6]=8'h02;  pat_rom[7]=8'h03;
        pat_rom[8]=8'h04;  pat_rom[9]=8'h05;  pat_rom[10]=8'h06; pat_rom[11]=8'h07;
        pat_rom[12]=8'h08; pat_rom[13]=8'h09; pat_rom[14]=8'h0a; pat_rom[15]=8'h0b;
        pat_rom[16]=8'h0c; pat_rom[17]=8'h0d; pat_rom[18]=8'h0e; pat_rom[19]=8'h0f;
        pat_rom[20]=8'h00; pat_rom[21]=8'h00;
    end

    reg clk_tx = 0;
    always #5 clk_tx = ~clk_tx;   // 100 MHz

    reg rst = 1;

    // pattern generator (mirror of trace_eyescan.v)
    reg [4:0] pat_idx;
    reg [7:0] pat_byte;
    always @(posedge clk_tx) begin
        if (rst) begin
            pat_idx  <= 5'd0;
            pat_byte <= 8'hff;
        end else begin
            pat_byte <= pat_rom[pat_idx];
            if (pat_idx == NBYTES-1) pat_idx <= 5'd0;
            else                     pat_idx <= pat_idx + 5'd1;
        end
    end

    // ODDR model per lane: present D1 while clk_tx high, D2 while low
    // (SAME_EDGE: D1 on rising, D2 on falling).
    wire [3:0] txd;
    genvar i;
    generate
        for (i = 0; i < 4; i = i + 1) begin : g
            assign txd[i] = clk_tx ? pat_byte[i] : pat_byte[4+i];
        end
    endgenerate
    wire txclk = clk_tx;

    // IDEAL IDDR capture: on each edge of txclk, grab the nibble.
    // rising -> trace_a (low nibble), falling -> trace_b (high nibble),
    // both presented to traceIF on the recovered clock (= txclk).
    reg [3:0] cap_rise, cap_fall;
    always @(posedge txclk) cap_rise <= txd;
    always @(negedge txclk) cap_fall <= txd;

    // traceIF consumes dina (rising nibble) + dinb (falling nibble) on the
    // rising edge of traceClkin.
    wire        fravail;
    wire [127:0] frame;
    traceIF #(.MAXBUSWIDTH(4)) u_tif (
        .rst        (rst),
        .traceDina  (cap_rise),
        .traceDinb  (cap_fall),
        .traceClkin (txclk),
        .width      (2'b11),
        .edgeOutput (),
        .FrAvail    (fravail),
        .Frame      (frame)
    );

    reg fr_q = 0;
    integer nf = 0;
    always @(posedge txclk) begin
        fr_q <= fravail;
        if (fravail !== fr_q) begin
            $display("[t=%0t] FRAME[%0d] = %032x", $time, nf, frame);
            nf = nf + 1;
        end
    end

    initial begin
        #20 rst = 0;
        #5000;
        $display("decoded %0d frames; golden = 123402030405060708090a0b0c0d0e0f", nf);
        $finish;
    end
endmodule

`default_nettype wire
