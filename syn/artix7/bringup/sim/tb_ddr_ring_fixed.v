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

    // ---- Behavioural MIG with realistic stalls (P0-1 per r36 §4.1) ---------
    // r36 硬伤 B: the trivial MIG model in tb_la_ddr_ring never stalls, so the
    // "concurrent R/W" race window that only opens when write bursts take real
    // physical time is compressed to zero. Add four stall/latency knobs so the
    // TB can *cover* the on-board race mechanism before we accept or reject any
    // hypothesis (蓝方 partial-write / 红方 H1 FIFO leak / H5 wbuf skew / ...).
    //
    // Enabled by default (WITH_MIG_STALL default 1). Set to 0 to run the
    // baseline model (matches tb_la_ddr_ring.v).
    localparam integer WITH_MIG_STALL = 1;

    // Stall parameters (deliberately conservative; scale up if P0-1 doesn't
    // reproduce ≥0.1% pollution).
    localparam integer WDF_STALL_CLK   = 40;   // app_wdf_rdy low after each beat
    localparam integer RDY_STALL_CLK   = 60;   // app_rdy low after each burst cmd
    localparam integer RD_LAT_BASE     = 6;    // base read latency
    localparam integer RD_LAT_JITTER   = 20;   // random jitter added to base
    localparam integer NET_STALL_EVERY = 100;  // stream_tready pulse-low every N clk
    localparam integer NET_STALL_LEN   = 10;   // ... for this many clk

    localparam integer MEM_WORDS = 8192;
    reg [127:0] mem [0:MEM_WORDS-1];
    integer i0;
`ifdef SIM_MEM_INIT_11
    initial for (i0 = 0; i0 < MEM_WORDS; i0 = i0 + 1) mem[i0] = 128'h11111111_11111111_11111111_11111111;
`else
    initial for (i0 = 0; i0 < MEM_WORDS; i0 = i0 + 1) mem[i0] = 128'hDEADBEEF_DEADBEEF_DEADBEEF_DEADBEEF;
`endif

    // app_wdf_rdy stall: after each accepted data beat, hold low for
    // WDF_STALL_CLK cycles (models MIG write-data FIFO drain to physical DDR3).
    reg  [15:0] wdf_stall_cnt = 0;
    reg         wdf_rdy_r     = 1'b1;
    always @(posedge clk) begin
        if (rst_ui) begin wdf_stall_cnt <= 0; wdf_rdy_r <= 1'b1; end
        else if (WITH_MIG_STALL == 0) wdf_rdy_r <= 1'b1;
        else if (app_wdf_wren && wdf_rdy_r) begin
            wdf_stall_cnt <= WDF_STALL_CLK;
            wdf_rdy_r     <= 1'b0;
        end else if (wdf_stall_cnt != 0) begin
            wdf_stall_cnt <= wdf_stall_cnt - 1'b1;
        end else begin
            wdf_rdy_r <= 1'b1;
        end
    end
    assign app_wdf_rdy = wdf_rdy_r;

    // app_rdy stall: after each accepted command (app_en pulse), hold low for
    // RDY_STALL_CLK cycles (models MIG bank activate/precharge time).
    reg  [15:0] rdy_stall_cnt = 0;
    reg         rdy_r         = 1'b1;
    always @(posedge clk) begin
        if (rst_ui) begin rdy_stall_cnt <= 0; rdy_r <= 1'b1; end
        else if (WITH_MIG_STALL == 0) rdy_r <= 1'b1;
        else if (app_en && rdy_r) begin
            rdy_stall_cnt <= RDY_STALL_CLK;
            rdy_r         <= 1'b0;
        end else if (rdy_stall_cnt != 0) begin
            rdy_stall_cnt <= rdy_stall_cnt - 1'b1;
        end else begin
            rdy_r <= 1'b1;
        end
    end
    assign app_rdy = rdy_r;

    // Write path: latch data into mem on wdf_wren & wdf_rdy (real MIG behaviour).
    always @(posedge clk) begin
        if (app_wdf_wren & app_wdf_rdy)
            mem[app_addr[15:3]] <= app_wdf_data;
    end

    // Read path with jittery latency. Read command is app_en && cmd==1 && rdy.
    // Instead of a fixed 2-stage pipe we push {addr, valid} into a small shift
    // register keyed by RD_LAT_BASE + $random%RD_LAT_JITTER so different reads
    // can interleave differently.
    localparam integer RD_MAX_LAT = RD_LAT_BASE + RD_LAT_JITTER + 4;
    reg         rd_lat_v [0:RD_MAX_LAT-1];
    reg [127:0] rd_lat_d [0:RD_MAX_LAT-1];
    integer rk;
    initial for (rk = 0; rk < RD_MAX_LAT; rk = rk + 1) begin
        rd_lat_v[rk] = 0; rd_lat_d[rk] = 0;
    end
    reg [31:0] rand_seed = 32'h1;
    always @(posedge clk) begin
        // shift the pipe forward every clock
        for (rk = RD_MAX_LAT - 1; rk > 0; rk = rk - 1) begin
            rd_lat_v[rk] <= rd_lat_v[rk-1];
            rd_lat_d[rk] <= rd_lat_d[rk-1];
        end
        rd_lat_v[0] <= 1'b0;
        // accept a read cmd only when ready
        if (app_en && (app_cmd == 3'd1) && app_rdy) begin
            // deterministic pseudo-random jitter derived from addr to avoid $random
            // side effects on other RNG consumers.
            rand_seed <= rand_seed ^ {app_addr, 3'b0};
            // slot the data at (RD_LAT_BASE + rand%RD_LAT_JITTER)
            begin : slot_it
                integer slot;
                if (WITH_MIG_STALL == 0) slot = 2;
                else slot = RD_LAT_BASE + (rand_seed[7:0] % (RD_LAT_JITTER==0?1:RD_LAT_JITTER));
                rd_lat_v[slot] <= 1'b1;
                rd_lat_d[slot] <= mem[app_addr[15:3]];
            end
        end
    end
    assign app_rd_data       = rd_lat_d[RD_MAX_LAT-1];
    assign app_rd_data_valid = rd_lat_v[RD_MAX_LAT-1];
    assign app_rd_data_end   = rd_lat_v[RD_MAX_LAT-1];

    // Network backpressure: pulse stream_tready low every NET_STALL_EVERY clk
    // for NET_STALL_LEN clk to simulate downstream slower than writer.
    reg [15:0] net_stall_cnt = 0;
    reg        net_stall_active = 0;
    always @(posedge clk125) begin
        if (rst_sys) begin net_stall_cnt <= 0; net_stall_active <= 0; end
        else if (WITH_MIG_STALL == 0) net_stall_active <= 0;
        else begin
            net_stall_cnt <= net_stall_cnt + 1'b1;
            if (net_stall_cnt == NET_STALL_EVERY) begin
                net_stall_active <= 1'b1;
                net_stall_cnt <= 0;
            end else if (net_stall_active && net_stall_cnt == NET_STALL_LEN) begin
                net_stall_active <= 1'b0;
                net_stall_cnt <= 0;
            end
        end
    end
    // (stream_tready is a reg initialised to 1; drive it here instead)
    always @(*) stream_tready = (WITH_MIG_STALL == 0) ? 1'b1 : ~net_stall_active;

    // ---- byte tap: capture stream_tdata + log every bad byte ---------------
    // r36 §4.1 P1 step 5: dump each (rx_offset, expected, actual) so pattern
    // is inspectable offline.
    integer rx_cnt = 0;
    integer bad_cnt = 0;
    integer bad_fd  = 0;
    reg [7:0] rx_bytes [0:255];
`ifdef RAMP
    reg [7:0] rx_prev = 0;
    reg       have_prev = 0;
`endif
    initial bad_fd = $fopen("bad_bytes.csv", "w");
    always @(posedge clk125) begin
        if (stream_tvalid && stream_tready) begin
            if (rx_cnt < 256) rx_bytes[rx_cnt] <= stream_tdata;
`ifdef RAMP
            if (have_prev && stream_tdata !== ((rx_prev + 8'd1) & 8'hFF)) begin
                bad_cnt <= bad_cnt + 1;
                if (bad_fd) $fdisplay(bad_fd, "%0d,%0d,%02x,%02x,%08x,%b",
                    $time, rx_cnt, (rx_prev + 8'd1) & 8'hFF, stream_tdata,
                    stream_seq, stream_rtx);
            end
            rx_prev   <= stream_tdata;
            have_prev <= 1'b1;
`else
            if (stream_tdata !== 8'h42) begin
                bad_cnt <= bad_cnt + 1;
                if (bad_fd) $fdisplay(bad_fd, "%0d,%0d,42,%02x,%08x,%b",
                    $time, rx_cnt, stream_tdata,
                    stream_seq, stream_rtx);
            end
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
