// traceIF re-sync / corner-case testbench
// ========================================
// Exercises sync-loss-then-resync and back-to-back frame decode, which the
// original traceIF_tb (single clean message) does not cover. Red-team review
// asked for: drop-sync-then-resync and multi-frame handling.
//
// Run (4-bit, WIDTH=3):
//   iverilog -o r verilog/traceIF.v verilog/testbeds/traceIF_resync_tb.v ; vvp r

`timescale 1ns/100ps

module traceIF_resync_tb;
   parameter WIDTH = 3; // 4-bit bus

   parameter chunksize = (WIDTH==3)?3:(WIDTH==2)?1:0;

   reg [3:0] traceDinA_tb;
   reg [3:0] traceDinB_tb;
   reg [1:0] width_tb;

   reg       traceClk_tb;
   reg       clk_tb;
   reg       rst_tb;

   wire         dAvail_tb;
   wire [127:0] dout_tb;

   integer      nframes;

traceIF DUT (
        .rst(rst_tb),
        .traceDina(traceDinA_tb),
        .traceDinb(traceDinB_tb),
        .traceClkin(traceClk_tb),
        .width(width_tb),
        .FrAvail(dAvail_tb),
        .Frame(dout_tb)
     );

   task sendByte;
      input [7:0] byteToSend;
      integer bitsToSend;
      reg [7:0] txbuffer;
      begin
         bitsToSend = 8;
         txbuffer = {byteToSend[7:4], byteToSend[3:0]};
         while (bitsToSend > 0) begin
            traceDinA_tb[chunksize:0] = txbuffer;
            bitsToSend = bitsToSend - (chunksize+1);
            txbuffer = txbuffer >> (chunksize+1);
            traceDinB_tb[chunksize:0] = txbuffer;
            bitsToSend = bitsToSend - (chunksize+1);
            txbuffer = txbuffer >> (chunksize+1);
            traceClk_tb <= 0; #10;
            traceClk_tb <= 1; #10;
            traceClk_tb <= 0;
         end
      end
   endtask

   task sendSync;
      begin
         sendByte(8'hff); sendByte(8'hff); sendByte(8'hff); sendByte(8'h7f);
      end
   endtask

   // Send one full 16-byte TPIU frame (8 packets) with a recognisable pattern.
   task sendFrame;
      input [7:0] base;
      integer k;
      begin
         for (k = 0; k < 16; k = k + 1)
            sendByte(base + k[7:0]);
      end
   endtask

   // Count frame-ready toggles directly in the trace domain (FrAvail is a
   // toggle output of traceIF). Real designs cross this via the AsyncFIFO,
   // which is covered separately by tests/test_cdc.py; here we only need to
   // confirm traceIF actually emitted each frame.
   reg davail_q;
   always @(posedge traceClk_tb) begin
      if ((dAvail_tb === 1'b0 || dAvail_tb === 1'b1) &&
          (davail_q  === 1'b0 || davail_q  === 1'b1) &&
          (dAvail_tb !== davail_q)) begin
         $display("FRAME[%0d]=%032x", nframes, dout_tb);
         nframes = nframes + 1;
      end
      davail_q <= dAvail_tb;
   end

   always begin clk_tb = ~clk_tb; #2; end

   initial begin
      rst_tb = 0; width_tb = WIDTH;
      traceDinA_tb = 0; traceDinB_tb = 0; traceClk_tb = 0; clk_tb = 0;
      nframes = 0;
      #10; rst_tb = 1; #10; rst_tb = 0; #20;

      // --- Scenario 1: garbage, then sync, then one full frame -------------
      $display("== S1: sync after garbage ==");
      sendByte(8'h00); sendByte(8'h55); sendByte(8'haa); // junk, no sync
      sendSync();
      sendFrame(8'h10);                                  // expect 1 frame

      // --- Scenario 2: lose sync (partial frame) then re-sync --------------
      $display("== S2: partial frame then re-sync ==");
      sendByte(8'h20); sendByte(8'h21); sendByte(8'h22); // partial, interrupted
      sendSync();                                        // re-sync
      sendFrame(8'h30);                                  // expect another frame

      // --- Scenario 3: back-to-back frames after a single sync -------------
      $display("== S3: two back-to-back frames ==");
      sendSync();
      sendFrame(8'h40);
      sendFrame(8'h50);                                  // expect two frames

      // flush
      repeat (40) sendByte(8'h00);

      $display("DONE: decoded %0d frames total", nframes);
      $finish;
   end

   initial begin
      $dumpfile("trace_resync.vcd");
      $dumpvars;
   end
endmodule
