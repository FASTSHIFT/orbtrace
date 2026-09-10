// tb_prbs_cdc — reproduce the framed-PRBS path through the REAL axis_async_fifo
// (8-bit, trace_clk->ref_200m) exactly as trace_capture_a7 wires it, plus the
// la_ddr_writer 16-byte packer, and check the drained byte stream against the
// known framed-PRBS reference. Goal: reproduce the "1 byte in 16 is 2 words
// stale" hardware symptom in simulation so we can see WHICH stage introduces it.
//
// Run: iverilog -g2012 -o /tmp/tb_prbs_cdc.out \
//        tb_prbs_cdc.v ../../../external/verilog-ethernet/lib/axis/rtl/axis_async_fifo.v
//      vvp /tmp/tb_prbs_cdc.out
`timescale 1ns/1ps
`default_nettype none

module tb_prbs_cdc;
    reg trace_clk = 0;
    reg ref_200m  = 0;
    reg rst = 1;

    // 10.2 MHz trace_clk (period ~98 ns) ; 200 MHz ref (5 ns)
    always #49 trace_clk = ~trace_clk;
    always #2.5 ref_200m = ~ref_200m;

    initial begin repeat(8) @(posedge ref_200m); rst = 0; end

    // ---- framed PRBS source in trace_clk (verbatim from trace_capture_a7) ----
    localparam [12:0] BLK_LEN = 13'd8192;
    reg  [12:0] blkpos = 0;
    reg  [31:0] prbs   = 32'h1;
    wire [31:0] prbs_x1  = prbs    ^ (prbs    << 13);
    wire [31:0] prbs_x2  = prbs_x1 ^ (prbs_x1 >> 17);
    wire [31:0] prbs_nxt = prbs_x2 ^ (prbs_x2 << 5);
    reg [7:0] marker;
    always @(*) case (blkpos[2:0])
        3'd0: marker=8'hA5; 3'd1: marker=8'h5A; 3'd2: marker=8'hC3; 3'd3: marker=8'h3C;
        3'd4: marker=8'hF0; 3'd5: marker=8'h0F; 3'd6: marker=8'h99; default: marker=8'h66;
    endcase
    wire in_marker = (blkpos < 13'd8);
    wire [7:0] test_byte = in_marker ? marker : prbs[7:0];
    always @(posedge trace_clk) begin
        if (!rst) begin
            blkpos <= (blkpos==BLK_LEN-1) ? 13'd0 : blkpos+13'd1;
            prbs   <= (blkpos < 13'd8) ? 32'h1 : prbs_nxt;
        end
    end

    reg [7:0] tclk_byte = 0;
    reg       tclk_push = 0;
    always @(posedge trace_clk) begin
        tclk_byte <= test_byte;
        tclk_push <= ~rst;
    end

    // ---- CDC FIFO (verbatim wiring) ----
    wire fifo_s_ready;
    wire [7:0] fifo_m_data;
    wire fifo_m_valid;
    wire fifo_m_ready = fifo_m_valid;
    wire cap_valid = fifo_m_valid & fifo_m_ready;
    wire [7:0] cap_byte = fifo_m_data;

    axis_async_fifo #(.DEPTH(32), .DATA_WIDTH(8),
        .KEEP_ENABLE(0), .LAST_ENABLE(0), .USER_ENABLE(0), .FRAME_FIFO(0)
    ) u_cdc (
        .s_clk(trace_clk), .s_rst(rst),
        .s_axis_tdata(tclk_byte), .s_axis_tkeep(1'b0),
        .s_axis_tvalid(tclk_push), .s_axis_tready(fifo_s_ready),
        .s_axis_tlast(1'b0), .s_axis_tid(8'h0), .s_axis_tdest(8'h0), .s_axis_tuser(1'b0),
        .m_clk(ref_200m), .m_rst(rst),
        .m_axis_tdata(fifo_m_data), .m_axis_tkeep(),
        .m_axis_tvalid(fifo_m_valid), .m_axis_tready(fifo_m_ready),
        .m_axis_tlast(), .m_axis_tid(), .m_axis_tdest(), .m_axis_tuser(),
        .s_pause_req(1'b0), .s_pause_ack(), .m_pause_req(1'b0), .m_pause_ack(),
        .s_status_depth(), .s_status_depth_commit(), .s_status_overflow(),
        .s_status_bad_frame(), .s_status_good_frame(),
        .m_status_depth(), .m_status_depth_commit(), .m_status_overflow(),
        .m_status_bad_frame(), .m_status_good_frame()
    );

    // ---- la_ddr_writer packer (verbatim: {cap_word[119:0], cap_byte}) ----
    reg [127:0] cap_word = 0;
    reg [4:0]   cap_bidx = 0;
    reg         word_valid = 0;
    wire [127:0] cap_word_next = {cap_word[119:0], cap_byte};
`ifdef FIX_LATCH
    // FIX: latch the completed word into a dedicated register on the
    // completing cycle, and present THAT to the consumer. cap_word_full then
    // does not depend on the next (17th) byte that may arrive on the valid
    // cycle.
    reg [127:0] cap_word_latched = 0;
    always @(posedge ref_200m) begin
        word_valid <= 1'b0;
        if (rst) begin cap_bidx <= 0; cap_word <= 0; end
        else if (cap_valid) begin
            cap_word <= cap_word_next;
            if (cap_bidx == 5'd15) begin
                cap_bidx <= 0; word_valid <= 1'b1;
                cap_word_latched <= cap_word_next;   // sampled THIS cycle
            end else cap_bidx <= cap_bidx + 1'b1;
        end
    end
    wire [127:0] cap_word_full = cap_word_latched;
`else
    // ORIGINAL (buggy): combinational full word sampled when the REGISTERED
    // word_valid is high -- one cycle late, so if a 17th byte arrives on that
    // cycle cap_word_next already shifted it in.
    always @(posedge ref_200m) begin
        word_valid <= 1'b0;
        if (rst) begin cap_bidx <= 0; cap_word <= 0; end
        else if (cap_valid) begin
            cap_word <= cap_word_next;
            if (cap_bidx == 5'd15) begin cap_bidx <= 0; word_valid <= 1'b1; end
            else cap_bidx <= cap_bidx + 1'b1;
        end
    end
    wire [127:0] cap_word_full = cap_word_next;
`endif

    // ---- collect drained bytes (big-endian within word) and check ----
    integer fo, nbytes = 0;
    integer wi;
    reg [7:0] b;
    initial fo = $fopen("/tmp/tb_prbs_bytes.bin","wb");
    always @(posedge ref_200m) begin
        if (!rst && word_valid) begin
            for (wi = 15; wi >= 0; wi = wi - 1) begin
                b = cap_word_full[wi*8 +: 8];
                $fwrite(fo, "%c", b);
                nbytes = nbytes + 1;
            end
        end
    end

    // Also log the RAW popped byte stream (before packing) with cap_valid, to
    // see whether the FIFO output itself is already defective or the packer is.
    integer fr, nraw = 0;
    initial fr = $fopen("/tmp/tb_prbs_raw.bin","wb");
    always @(posedge ref_200m) begin
        if (!rst && cap_valid) begin
            $fwrite(fr, "%c", cap_byte);
            nraw = nraw + 1;
        end
    end

    initial begin
        #2_000_000;   // ~2 ms sim -> ~20k trace_clk bytes
        $fclose(fo);
        $fclose(fr);
        $display("tb_prbs_cdc: wrote %0d packed bytes, %0d raw popped bytes", nbytes, nraw);
        $finish;
    end
endmodule
`default_nettype wire
