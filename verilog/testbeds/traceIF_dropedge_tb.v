// traceIF_dropedge_tb.v — red-team r27 R7B.
// Feed traceIF a CORRECT TPIU frame stream but DELIBERATELY DROP one TRACECLK
// half-bit (simulate the IDDR missing/adding one edge at high TRACECLK on
// edge-aligned data). Goal: reproduce doc 16's "correct right after A-sync,
// then garbage until the next sync" signature. If a single dropped edge
// derails the whole construct shift register, the 99.7% illegal rate is a
// SAMPLING-COMPLETENESS problem (edge drop), NOT the front-end architecture --
// so swapping to the "upstream minimal chain" (proposal 35) cannot fix it.
//
// Based on the upstream verilog/testbeds/traceIF_tb.v (4-bit width).
//   iverilog -o r traceIF.v traceIF_dropedge_tb.v ; vvp r

`timescale 1ns/100ps

module traceIF_dropedge_tb;
   parameter WIDTH=3;                 // 3 => 4-bit port
   parameter chunksize=(WIDTH==3)?3:(WIDTH==2)?1:0;

   // DROP_AT: which sendByte call index drops one half-bit (0 = never).
   parameter DROP_AT = 30;

   reg [3:0] traceDinA_tb, traceDinB_tb;
   reg [1:0] width_tb;
   reg       traceClk_tb, clk_tb, rst_tb;
   wire      dAvail_tb;
   wire [127:0] dout_tb;

   integer   byte_idx = 0;            // count of sendByte calls
   integer   do_drop_next = 0;

traceIF DUT (
   .rst(rst_tb),
   .traceDina(traceDinA_tb), .traceDinb(traceDinB_tb),
   .traceClkin(traceClk_tb), .width(width_tb),
   .FrAvail(dAvail_tb), .Frame(dout_tb)
);

   // Send a byte over the 4-bit DDR port. If drop_half is set, emit only the
   // rising half (skip the falling half) -> one half-bit (one IDDR edge) lost.
   task sendByteMaybeDrop;
      input [7:0] byteToSend;
      input       drop_half;
      integer     bitsToSend;
      reg [7:0]   txbuffer;
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
         // Inject: one extra rising-only tick that shifts construct by a half
         // (a spurious/duplicated edge) OR skip -- here we ADD one half-bit of
         // junk to model a mis-sampled extra edge.
         if (drop_half) begin
            traceDinA_tb[chunksize:0] = 4'hf;   // junk half-bit
            traceClk_tb <= 0; #10;
            traceClk_tb <= 1; #10;
            traceClk_tb <= 0;
         end
      end
   endtask

   task sendByte;
      input [7:0] b;
      begin
         sendByteMaybeDrop(b, (byte_idx == DROP_AT) ? 1'b1 : 1'b0);
         byte_idx = byte_idx + 1;
      end
   endtask

   // Detect each frame directly on FrAvail toggling (traceIF flips FrAvail
   // once per complete frame). Sample in the trace clock domain edges via a
   // simple last-value compare, checked after each byte in the stimulus.
   reg       fravail_last = 0;
   integer   frame_num = 0;
   always @(dAvail_tb) begin
      if (dAvail_tb !== fravail_last) begin
         #1 $display("FRAME[%0d]=%032x", frame_num, dout_tb);
         frame_num = frame_num + 1;
         fravail_last = dAvail_tb;
      end
   end

   always begin clk_tb = ~clk_tb; #2; end

   initial begin
      rst_tb=0; width_tb=WIDTH;
      traceDinA_tb=0; traceDinB_tb=0; traceClk_tb=0; clk_tb=0;
      #10; rst_tb=1; #10; rst_tb=0; #20;

      // junk then sync
      sendByte(8'h00); sendByte(8'h00); sendByte(8'h00);
      sendByte(8'hff); sendByte(8'hff); sendByte(8'hff); sendByte(8'h7f);

      // two full 16-byte frames of a recognizable ramp; drop happens at DROP_AT
      // (inside the 2nd frame) to show "1st frame ok, then garbage".
      repeat (2) begin
         sendByte(8'h00); sendByte(8'h01); sendByte(8'h02); sendByte(8'h03);
         sendByte(8'h04); sendByte(8'h05); sendByte(8'h06); sendByte(8'h07);
         sendByte(8'h08); sendByte(8'h09); sendByte(8'h0a); sendByte(8'h0b);
         sendByte(8'h0c); sendByte(8'h0d); sendByte(8'h0e); sendByte(8'h0f);
      end
      // re-sync then one more clean frame (does traceIF recover on next sync?)
      sendByte(8'hff); sendByte(8'hff); sendByte(8'hff); sendByte(8'h7f);
      sendByte(8'h10); sendByte(8'h11); sendByte(8'h12); sendByte(8'h13);
      sendByte(8'h14); sendByte(8'h15); sendByte(8'h16); sendByte(8'h17);
      sendByte(8'h18); sendByte(8'h19); sendByte(8'h1a); sendByte(8'h1b);
      sendByte(8'h1c); sendByte(8'h1d); sendByte(8'h1e); sendByte(8'h1f);
      #200;
      $display("DROP_AT=%0d done", DROP_AT);
      $finish;
   end
endmodule
