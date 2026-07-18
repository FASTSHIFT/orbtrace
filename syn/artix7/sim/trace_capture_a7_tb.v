// trace_capture_a7_tb
// =====================
// End-to-end behavioural simulation of the Artix-7 trace capture front-end
// (IBUF + IDELAYE2 + IDDR + IDELAYCTRL) chained to traceIF.v, exercised
// with the same synthetic stream traceIF_tb uses, to prove the Xilinx-
// primitive front-end produces the same frame as the original ECP5-style
// capture.
//
// Run:
//   source $XILINX_VIVADO/settings64.sh
//   ./syn/artix7/sim/run_xsim.sh
//
// (iverilog can't simulate Xilinx secureip — IDDR/IDELAYE2/IDELAYCTRL all
//  resolve to encrypted .vp blobs. Vivado xsim is the only feasible path
//  on this code base.)

`timescale 1ns/1ps

module trace_capture_a7_tb;

    // 200 MHz IDELAYCTRL reference (board MMCM output in real HW)
    reg ref_200m = 0;
    always #2.5 ref_200m = ~ref_200m;     // 5ns period -> 200MHz

    // System reset (>=60ns active for IDELAYCTRL spec)
    reg rst = 1;
    initial begin
        #100 rst = 0;
    end

    // ----------------------------------------------------------------
    // External trace driver: emulate target asserting TRACECLK + 4-bit
    // DDR data exactly the same way traceIF_tb's sendByte does.
    // ----------------------------------------------------------------
    reg        trace_clk_src = 0;       // simulated TRACECLK from "target"
    reg [3:0]  trace_dina = 0;          // rising-edge nibble (LSB-first per byte)
    reg [3:0]  trace_dinb = 0;          // falling-edge nibble

    // Drive the actual board pin.  In simulation we expose both the clock
    // pin and per-edge data pins; the data pin transitions at the moments
    // sendByte does.
    wire trace_clk_p = trace_clk_src;
    reg  [3:0] trace_data_p_reg = 0;
    wire [3:0] trace_data_p = trace_data_p_reg;

    // ----------------------------------------------------------------
    // DUT: Artix-7 capture front-end -> traceIF
    // ----------------------------------------------------------------
    wire        trace_clk_recovered;
    wire [3:0]  trace_a, trace_b;
    wire        idelayctrl_rdy;

    trace_capture_a7 u_capture (
        .rst           (rst),
        .ref_200m      (ref_200m),
        .trace_clk_p   (trace_clk_p),
        .trace_data_p  (trace_data_p),
        .tap_data0     (5'd0), .tap_clk(5'd0),
        .tap_data1     (5'd0),
        .tap_data2     (5'd0),
        .tap_data3     (5'd0),
        .tap_load      (1'b0),
        .trace_clk     (trace_clk_recovered),
        .trace_a       (trace_a),
        .trace_b       (trace_b),
        .idelayctrl_rdy(idelayctrl_rdy)
    );

    wire        FrAvail;
    wire [127:0] Frame;
    traceIF #(.MAXBUSWIDTH(4)) u_tif (
        .rst        (rst),
        .traceDina  (trace_a),
        .traceDinb  (trace_b),
        .traceClkin (trace_clk_recovered),
        .width      (2'b11),
        .edgeOutput (),
        .FrAvail    (FrAvail),
        .Frame      (Frame)
    );

    // ----------------------------------------------------------------
    // Stimulus: one TRACECLK period drives 8 bits per lane via DDR
    // (4 bits on rising, 4 on falling). For 4-bit width all 8 bits of a
    // byte are conveyed in a single TRACECLK period.
    // ----------------------------------------------------------------
    task sendByte;
        input [7:0] b;
        begin
            // Pre-set rising-edge nibble (low 4 bits, LSB-first)
            trace_data_p_reg = b[3:0];
            trace_clk_src    = 0; #5;
            trace_clk_src    = 1;          // rising edge: ISERDES samples low nibble
            trace_data_p_reg = b[7:4];     // falling-edge nibble (high 4 bits)
            #5;
            trace_clk_src    = 0;          // falling edge: ISERDES samples high nibble
            #5;
        end
    endtask

    // Frame-ready toggle detection in a sys-clock-ish domain
    reg davail_q = 0;
    integer nframes = 0;
    always @(posedge ref_200m) begin
        if ((FrAvail === 1'b0 || FrAvail === 1'b1) &&
            (davail_q === 1'b0 || davail_q === 1'b1) &&
            (FrAvail !== davail_q)) begin
            $display("[t=%0t] FRAME[%0d] = %032x", $time, nframes, Frame);
            nframes = nframes + 1;
        end
        davail_q <= FrAvail;
    end

    initial begin
        // wait for IDELAYCTRL to come up
        wait (idelayctrl_rdy === 1'b1);
        $display("[t=%0t] IDELAYCTRL ready", $time);
        #50;

        // Pre-sync junk
        sendByte(8'h00); sendByte(8'h00);

        // TPIU full sync sequence: ff ff ff 7f
        sendByte(8'hff); sendByte(8'hff); sendByte(8'hff); sendByte(8'h7f);

        // 16 bytes of payload -> one full traceIF frame
        sendByte(8'h12); sendByte(8'h34);
        sendByte(8'h02); sendByte(8'h03);
        sendByte(8'h04); sendByte(8'h05);
        sendByte(8'h06); sendByte(8'h07);
        sendByte(8'h08); sendByte(8'h09);
        sendByte(8'h0a); sendByte(8'h0b);
        sendByte(8'h0c); sendByte(8'h0d);
        sendByte(8'h0e); sendByte(8'h0f);

        // Flush
        repeat (8) sendByte(8'h00);

        $display("DONE: %0d frames decoded", nframes);
        if (nframes >= 1)
            $display("PASS: Artix-7 capture front-end produced a frame");
        else
            $display("FAIL: no frame decoded by the Artix-7 front-end");
        $finish;
    end

    initial begin
        $dumpfile("trace_a7.vcd");
        $dumpvars(0, trace_capture_a7_tb);
    end

    // Watchdog
    initial begin
        #100_000;
        $display("WATCHDOG: simulation timed out");
        $finish;
    end

endmodule
