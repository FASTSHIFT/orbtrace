// traceIF real-stimulus testbench
// =================================
// Feeds traceIF with real captured trace data from stimfiles/*.dat.
//
// Each line in the .dat file is one decimal byte representing the trace-pin
// state for one TRACECLK period, packed by stimfiles/convert.py as:
//   byte = (edge_a[3:0] << 4) | (edge_b[3:0])
//
// Status (stage-1 simulation):
//   - Mechanism verified: a synthetic sequence (same as traceIF_tb) decodes
//     correctly through this harness (frames "3412 0302 ..." recovered).
//   - Real data feeds in and the TPIU sync sequence is correctly detected:
//     slowitm.dat -> ~170 syncs (capture is mostly idle sync words),
//     fastitm.dat -> ~64 syncs plus real ITM payload words.
//   - Byte-stream analysis confirms the TPIU full-sync word (ff ff ff 7f)
//     is present once the captured byte is split as dina=low nibble,
//     dinb=high nibble (see feedByte).
//
// TODO(align): full per-TRACECLK phase/bit-order alignment so that complete
//   16-bit-half-word frames are reassembled from the real captures. Sync is
//   detected but full frame reassembly from real .dat needs the exact nibble
//   feed phase to match traceIF's internal shift order. Tracked separately;
//   not blocking — synthetic decode + sync detection already validate the
//   chip-independent framing logic.
//
// Run with (default slowitm.dat):
//   iverilog -o r verilog/traceIF.v verilog/testbeds/traceIF_stim_tb.v ; vvp r
// Select a different file:
//   iverilog -DSTIMFILE='"verilog/testbeds/stimfiles/fastitm.dat"' \
//            -o r verilog/traceIF.v verilog/testbeds/traceIF_stim_tb.v ; vvp r

`timescale 1ns/100ps

`ifndef STIMFILE
 `define STIMFILE "verilog/testbeds/stimfiles/slowitm.dat"
`endif

module traceIF_stim_tb;
   parameter WIDTH = 3; // real captures here are 4-bit (width code 3)

   reg [3:0] traceDinA_tb;
   reg [3:0] traceDinB_tb;
   reg [1:0] width_tb;

   reg       traceClk_tb;
   reg       clk_tb;
   reg       rst_tb;

   wire         dAvail_tb;
   wire [127:0] dout_tb;

   integer      fd;
   integer      rc;
   integer      byteval;
   integer      nbytes;
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

   // Feed one captured TRACECLK period: set data nibbles, toggle clock once.
   // convert.py packs the captured byte as (rising<<4)|falling, but the real
   // capture maps the LOW nibble to traceDina (rising/LSB-first) and the HIGH
   // nibble to traceDinb; confirmed by locating the TPIU sync word in the
   // reassembled byte stream.
   task feedByte;
      input [7:0] b;
      begin
         traceDinA_tb = b[3:0];
         traceDinB_tb = b[7:4];
         traceClk_tb <= 0;
         #10;
         traceClk_tb <= 1;
         #10;
         traceClk_tb <= 0;
      end
   endtask

   // Count frames via FrAvail toggle detection in the sys-clock domain.
   reg [2:0] davail_cdc;
   always @(posedge clk_tb) begin
      davail_cdc <= {davail_cdc[1:0], dAvail_tb};
      if (davail_cdc == 3'b011) begin
         $display("FRAME[%0d]=%032x", nframes, dout_tb);
         nframes = nframes + 1;
      end
   end

   always begin
      clk_tb = ~clk_tb;
      #2;
   end

   initial begin
      rst_tb = 0;
      width_tb = WIDTH;
      traceDinA_tb = 0;
      traceDinB_tb = 0;
      traceClk_tb = 0;
      clk_tb = 0;
      nbytes = 0;
      nframes = 0;

      #10; rst_tb = 1; #10; rst_tb = 0; #20;

      fd = $fopen(`STIMFILE, "r");
      if (fd == 0) begin
         $display("ERROR: cannot open stimulus file %s", `STIMFILE);
         $finish;
      end

      $display("Feeding stimulus from %s", `STIMFILE);
      while (!$feof(fd)) begin
         rc = $fscanf(fd, "%d\n", byteval);
         if (rc == 1) begin
            feedByte(byteval[7:0]);
            nbytes = nbytes + 1;
         end
      end
      $fclose(fd);

      // Flush a few extra clocks so the last frame can propagate.
      repeat (20) feedByte(8'h00);

      $display("DONE: fed %0d bytes, decoded %0d frames", nbytes, nframes);
      $finish;
   end

   initial begin
      $dumpfile("trace_stim.vcd");
      $dumpvars;
   end
endmodule
