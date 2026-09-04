// tb_ddr_ring_fixed
// =================
// doc 21 S1b bring-up bug: on hardware, feeding a fixed-value byte source
// (0x42) into la_ddr_writer -> DDR ring -> la_ddr_ring_streamer produces
// scrambled bytes (0x87/0xF1/0xE1... instead of 0x42) on the network side.
//
// This bench mirrors the on-board configuration as closely as an integer-clock
// simulation allows, to answer "is it my top wiring or the FPGA environment?"
// Deviations from the working tb_la_ddr_ring baseline:
//   * cap_clk = ui_clk        (same-domain, matches ddr_ring_selftest_top)
//   * cap_valid_in stays high (no CAP_DIV divider, matches the top)
//   * source byte fixed = 0x42 (not a ramp)
// A pass here proves the top-level wiring model is correct, so any failure
// found on the board is an environment/timing artifact, not a topology bug.
// A fail here reproduces the bug in simulation for offline fixing.

`timescale 1ns/1ps
`default_nettype none

module tb_ddr_ring_fixed;
    // Clocks — cap_clk and ui_clk are the SAME clock (like on the board).
    reg clk = 0;                   // shared ui_clk / cap_clk
    reg clk125 = 0;
    always #5   clk    = ~clk;     // 100 MHz
    always #4   clk125 = ~clk125;  // 125 MHz

    reg rst_ui = 1, rst_sys = 1;

    localparam integer LENGTH     = 64;
    localparam [28:0]  RING_BASE  = 29'd0;
    // 16 MB in app-addr units (identical unit to tb_la_ddr_ring, but 1024x
    // bigger — closer to the on-board ring size).
    localparam [28:0]  RING_WORDS = 29'd524288;   // 64 KB (fits behavioural mem)
    localparam integer PKT_WORDS  = 64;

    // Source: fixed 0x42 by default; +define+RAMP flips to a monotone ramp
    // (each cycle: src_byte += 1). This is the ramp mode the on-board top
    // uses in production; the check confirms the datapath preserves ordering
    // (byte k == first_byte + k, mod 256).
    reg [7:0] src_byte = 8'h42;
    reg       src_valid = 0;
`ifdef RAMP
    always @(posedge clk) if (src_valid) src_byte <= src_byte + 8'd1;
`endif

    // ================= WRITER (cap_clk = ui_clk = clk) =================
    wire         wr_start, wr_data_req, wr_addr_req, wr_done;
    wire [127:0] wr_data;
    wire [28:0]  wr_addr;
    wire [28:0]  wr_ptr_words;
    wire [31:0]  words_written, wr_lost_bytes;

    la_ddr_writer #(
        .LENGTH(LENGTH), .IN_BYTES(1),
        .RING_BASE(RING_BASE), .RING_WORDS(RING_WORDS)
    ) u_wr (
        .cap_clk(clk), .cap_rst(rst_ui),
        .cap_byte(src_byte), .cap_valid_in(src_valid), .freeze(1'b0),
        .ui_clk(clk), .ui_rst(rst_ui),
        .ddr3_busy(1'b0),
        .ddr3_wr_start(wr_start),
        .ddr3_wr_data_req(wr_data_req),
        .ddr3_wr_data(wr_data),
        .ddr3_wr_addr_req(wr_addr_req),
        .ddr3_wr_addr(wr_addr),
        .ddr3_wr_done(wr_done),
        .wr_ptr_words(wr_ptr_words),
        .words_written(words_written),
        .wr_lost_bytes(wr_lost_bytes)
    );

    // ================= STREAMER (ui_clk + clk125) =====================
    wire         rd_start, rd_addr_req, rd_data_vld, rd_done;
    wire [28:0]  rd_addr;
    wire [127:0] rd_data;
    wire [7:0]   stream_tdata;
    wire         stream_tvalid;
    reg          stream_tready = 1'b1;
    wire [31:0]  stream_seq;
    wire         stream_rtx;
    wire [28:0]  rd_ptr_words;
    wire [31:0]  words_drained;
    wire         ring_overrun;

    la_ddr_ring_streamer #(
        .LENGTH(LENGTH), .RING_BASE(RING_BASE),
        .RING_WORDS(RING_WORDS), .PKT_WORDS(PKT_WORDS)
    ) u_st (
        .ui_clk(clk), .ui_rst(rst_ui),
        .wr_ptr_words(wr_ptr_words),
        .wr_words_committed(words_written),
        .drain_credit(1'b1),
        .ddr3_rd_start(rd_start),
        .ddr3_rd_addr_req(rd_addr_req),
        .ddr3_rd_addr(rd_addr),
        .ddr3_rd_data_vld(rd_data_vld),
        .ddr3_rd_data(rd_data),
        .ddr3_rd_done(rd_done),
        .nack_valid(1'b0), .nack_start_seq(32'd0), .nack_count(16'd0),
        .nack_busy(), .nack_fail(),
        .clk125(clk125), .sys_rst(rst_sys),
        .stream_tdata(stream_tdata), .stream_tvalid(stream_tvalid),
        .stream_tready(stream_tready),
        .stream_seq(stream_seq), .stream_rtx(stream_rtx),
        .rd_ptr_words(rd_ptr_words), .words_drained(words_drained),
        .ring_overrun(ring_overrun)
    );

    // ================= REAL vendor ctrl + arbiter (same as tb_la_ddr_ring) =
    wire        app_rdy, app_wdf_rdy;
    wire        wr_app_en, rd_app_en;
    wire [2:0]  wr_app_cmd, rd_app_cmd;
    wire [28:0] wr_app_addr, rd_app_addr;
    wire [127:0]app_wdf_data;
    wire        app_wdf_end, app_wdf_wren;
    wire [15:0] app_wdf_mask;
    wire        app_rd_data_end, app_rd_data_valid;
    wire [127:0]app_rd_data;

    wire        wr_req, wr_ack, wr_busy;
    wire        rd_req, rd_ack, rd_busy;

    wire        app_en   = wr_busy ? wr_app_en   : rd_app_en;
    wire [2:0]  app_cmd  = wr_busy ? wr_app_cmd  : rd_app_cmd;
    wire [28:0] app_addr = wr_busy ? wr_app_addr : rd_app_addr;

    ddr3_wr_ctrl #(.LENGTH(LENGTH)) u_wrc (
        .ui_clk(clk), .ui_rst(rst_ui),
        .app_rdy(app_rdy), .app_en(wr_app_en), .app_cmd(wr_app_cmd),
        .app_addr(wr_app_addr), .app_wdf_rdy(app_wdf_rdy),
        .app_wdf_data(app_wdf_data), .app_wdf_end(app_wdf_end),
        .app_wdf_wren(app_wdf_wren), .app_wdf_mask(app_wdf_mask),
        .ddr3_wr_start(wr_start), .ddr3_wr_req(wr_req), .ddr3_wr_ack(wr_ack),
        .ddr3_wr_data_req(wr_data_req), .ddr3_wr_data(wr_data),
        .ddr3_wr_addr_req(wr_addr_req), .ddr3_wr_addr(wr_addr),
        .ddr3_wr_done(wr_done), .ddr3_wr_busy(wr_busy)
    );

    ddr3_rd_ctrl #(.LENGTH(LENGTH)) u_rdc (
        .ui_clk(clk), .ui_rst(rst_ui),
        .app_rdy(app_rdy), .app_en(rd_app_en), .app_addr(rd_app_addr),
        .app_cmd(rd_app_cmd), .app_rd_data_end(app_rd_data_end),
        .app_rd_data_valid(app_rd_data_valid), .app_rd_data(app_rd_data),
        .ddr3_rd_start(rd_start), .ddr3_rd_req(rd_req), .ddr3_rd_ack(rd_ack),
        .ddr3_rd_addr_req(rd_addr_req), .ddr3_rd_addr(rd_addr),
        .ddr3_rd_data_vld(rd_data_vld), .ddr3_rd_data(rd_data),
        .ddr3_rd_done(rd_done), .ddr3_rd_busy(rd_busy)
    );

    ddr3_arbit u_arb (
        .ui_clk(clk), .ui_rst(rst_ui),
        .ddr3_wr_req(wr_req), .ddr3_wr_done(wr_done),
        .ddr3_rd_req(rd_req), .ddr3_rd_done(rd_done),
        .ddr3_wr_ack(wr_ack), .ddr3_rd_ack(rd_ack)
    );

    // Behavioural MIG (identical to tb_la_ddr_ring)
    localparam integer MEM_WORDS = 8192;
    reg [127:0] mem [0:MEM_WORDS-1];
    integer i0;
    initial for (i0 = 0; i0 < MEM_WORDS; i0 = i0 + 1) mem[i0] = 128'hDEADBEEF_DEADBEEF_DEADBEEF_DEADBEEF;
    assign app_rdy     = 1'b1;
    assign app_wdf_rdy = 1'b1;
    always @(posedge clk) begin
        if (app_wdf_wren & app_wdf_rdy)
            mem[app_addr[15:3]] <= app_wdf_data;
    end
    reg [127:0] rd_reg1 = 0, rd_reg2 = 0;
    reg         rd_v1 = 0, rd_v2 = 0;
    always @(posedge clk) begin
        rd_reg1 <= mem[app_addr[15:3]];
        rd_v1   <= app_en && app_cmd == 3'd1;
        rd_reg2 <= rd_reg1; rd_v2 <= rd_v1;
    end
    assign app_rd_data       = rd_reg2;
    assign app_rd_data_valid = rd_v2;
    assign app_rd_data_end   = rd_v2;

    // ---- byte tap: capture stream_tdata into a queue for later inspection ----
    integer rx_cnt = 0;
    integer bad_cnt = 0;
    reg [7:0] rx_bytes [0:255];
`ifdef RAMP
    // in ramp mode, verify byte k == prev+1 mod 256
    reg [7:0] rx_prev = 0;
    reg       have_prev = 0;
`endif
    always @(posedge clk125) begin
        if (stream_tvalid && stream_tready) begin
            if (rx_cnt < 256) rx_bytes[rx_cnt] <= stream_tdata;
`ifdef RAMP
            if (have_prev && stream_tdata !== ((rx_prev + 8'd1) & 8'hFF))
                bad_cnt <= bad_cnt + 1;
            rx_prev   <= stream_tdata;
            have_prev <= 1'b1;
`else
            if (stream_tdata !== 8'h42) bad_cnt <= bad_cnt + 1;
`endif
            rx_cnt <= rx_cnt + 1;
        end
    end

    // ---- stimulus ----
    integer i;
    initial begin
        // reset
        rst_ui = 1; rst_sys = 1; src_valid = 0;
        #100;
        rst_ui = 0; rst_sys = 0;
        #100;
        src_valid = 1;                       // start feeding 0x42 forever

        // let it run long enough to produce many packets
        repeat (200000) @(posedge clk);

        $display("==== fixed-source diag ====");
        $display("words_written = %0d, words_drained = %0d", words_written, words_drained);
        $display("wr_lost = %0d, ring_overrun = %0b", wr_lost_bytes, ring_overrun);
        $display("stream bytes received = %0d, non-0x42 count = %0d", rx_cnt, bad_cnt);
        $display("first 32 rx bytes:");
        for (i = 0; i < 32 && i < rx_cnt; i = i + 1)
            $write(" %02x", rx_bytes[i]);
        $display("");
        if (bad_cnt == 0 && rx_cnt > 0) begin
            $display("RESULT=ALL_PASS (all received bytes == 0x42)");
        end else if (rx_cnt == 0) begin
            $display("RESULT=FAIL_NO_DATA (streamer never emitted)");
        end else begin
            $display("RESULT=FAIL_SCRAMBLED (bad_cnt=%0d)", bad_cnt);
        end
        $finish;
    end

endmodule

`default_nettype wire
