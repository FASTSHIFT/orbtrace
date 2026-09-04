// ddr_ring_selftest_top
// =====================
// doc 21 S1b: prove the DDR ring buffer + streamer + NACK-ready datapath is
// end-to-end zero-loss BEFORE wiring the trace source in. Data source is an
// internal monotone-mod-256 byte ramp (STM32 not required). The stream is
// packetised (seq + payload) and self-TXed over the Ethernet stack, identical
// to the S2/S3/S4 production datapath — only cap_byte is replaced with the ramp
// so a failure isolates to the writer/streamer/network stack, never the trace
// side.
//
// Comparison vs trace_ddr_selftest_top (S1a):
//   S1a: internal FSM writes + reads-back + compares on FPGA -> :5001 status
//   S1b: internal ramp writes -> DDR ring -> streamer -> UDP :5555 -> PC ramp
//        check (`_rampcheck.py`, monotone mod 256)
//
// Clocks are identical to S1a (sys 125/125@90/100, MIG 200MHz sys ref, MIG
// ui_clk=50MHz). We drive the ramp source in ui_clk (50MHz) -> 50 MB/s peak
// through the writer, well within DDR3 and Ethernet capability but plenty to
// stress the ring buffer at production-relevant rates.

`default_nettype none

module ddr_ring_selftest_top #(
    parameter [31:0] DEST_IP        = {8'd192, 8'd168, 8'd10, 8'd245},
    parameter [15:0] DEST_PORT      = 16'd5555,
    parameter integer LENGTH        = 64,         // 128-bit words/DDR burst
    // Ring geometry — BOTH writer and streamer take RING_WORDS in APP-ADDRESS
    // UNITS (+8 per 128-bit word). 8M app-addr = 1M 128-bit words = 16 MB.
    // (The la_ddr_writer parameter comment "1M words = 16 MB" is wrong; the
    // internal wrap arithmetic wr_ptr_words + (LENGTH<<3) >= RING_WORDS proves
    // the value is app-addr, not 128-bit-word count. tb_la_ddr_ring passes
    // the SAME RING_WORDS to both modules -- doc 21 §4.2 was updated to match.)
    parameter [28:0]  RING_WORDS    = 29'h0800000,   // 16 MB in app-addr units
    parameter integer PKT_WORDS     = 64,            // 128-bit words/UDP packet
    parameter integer STREAM_PAYLOAD= 1024,          // payload bytes/UDP packet
    parameter integer STREAM_FIFO_DEPTH = 8192,
    parameter [31:0] BUILD_ID       = 32'hDEADBEEF
) (
    input  wire        sys_clk_50,
    input  wire        rst_n,

    // RGMII
    input  wire        phy_rx_clk,
    input  wire [3:0]  phy_rxd,
    input  wire        phy_rx_ctl,
    output wire        phy_tx_clk,
    output wire [3:0]  phy_txd,
    output wire        phy_tx_ctl,
    output wire        phy_reset_n,
    inout  wire        phy_mdio,
    output wire        phy_mdc,

    // DDR3
    output wire [14:0] ddr3_addr,
    output wire [2:0]  ddr3_ba,
    output wire        ddr3_cas_n,
    output wire [0:0]  ddr3_ck_n,
    output wire [0:0]  ddr3_ck_p,
    output wire [0:0]  ddr3_cke,
    output wire        ddr3_ras_n,
    output wire        ddr3_reset_n,
    output wire        ddr3_we_n,
    inout  wire [15:0] ddr3_dq,
    inout  wire [1:0]  ddr3_dqs_n,
    inout  wire [1:0]  ddr3_dqs_p,
    output wire [1:0]  ddr3_dm,
    output wire [0:0]  ddr3_odt,

    output wire        led0,          // sys mmcm locked
    output wire        led1           // streamer active (packet in flight)
);
    wire rst = ~rst_n;

    // ---- sys MMCM (50 -> 125/125@90/100) ----
    wire clkfb, clk125_u, clk125_90_u, clk100_u, mmcm_sys_locked;
    MMCME2_BASE #(
        .CLKIN1_PERIOD(20.0), .CLKFBOUT_MULT_F(20.0), .DIVCLK_DIVIDE(1),
        .CLKOUT0_DIVIDE_F(8.0),
        .CLKOUT1_DIVIDE(8), .CLKOUT1_PHASE(90.0),
        .CLKOUT3_DIVIDE(10),
        .CLKOUT0_PHASE(0.0), .CLKOUT3_PHASE(0.0)
    ) u_sysmmcm (
        .CLKIN1(sys_clk_50), .CLKFBIN(clkfb), .CLKFBOUT(clkfb),
        .CLKOUT0(clk125_u), .CLKOUT1(clk125_90_u), .CLKOUT3(clk100_u),
        .LOCKED(mmcm_sys_locked), .RST(rst), .PWRDWN(1'b0)
    );
    wire clk125, clk125_90, clk100;
    BUFG b0(.I(clk125_u), .O(clk125));
    BUFG b1(.I(clk125_90_u), .O(clk125_90));
    BUFG b3(.I(clk100_u), .O(clk100));

    reg [3:0] rst_sync = 4'hf;
    always @(posedge clk125 or posedge rst)
        if (rst) rst_sync <= 4'hf;
        else     rst_sync <= {rst_sync[2:0], ~mmcm_sys_locked};
    wire sys_rst = rst_sync[3];

    // ---- MIG 200MHz ref ----
    wire sys_clk_200, clk200_locked;
    clock u_clock (
        .clk_out1(sys_clk_200),
        .resetn  (rst_n),
        .locked  (clk200_locked),
        .clk_in1 (sys_clk_50)
    );

    // ============= DDR3 controller (ui_clk = 50MHz from MIG) =============
    wire        ui_clk, ui_rst, ddr3_busy;
    wire         wr_start_w, wr_data_req, wr_addr_req_w, wr_done_w;
    wire [127:0] wr_data_w;
    wire [28:0]  wr_addr_w;
    wire         rd_start_w, rd_addr_req_w, rd_data_vld_w, rd_done_w;
    wire [28:0]  rd_addr_w;
    wire [127:0] rd_data_w;

    wire mig_calib_raw;
    ddr3_ctrl u_ddr3 (
        .sys_clk    (sys_clk_200),
        .sys_rst_n  (clk200_locked & mmcm_sys_locked),
        .ui_clk     (ui_clk),
        .ui_rst     (ui_rst),
        .calib_complete(mig_calib_raw),
        .ddr3_busy  (ddr3_busy),
        .ddr3_wr_start(wr_start_w), .ddr3_wr_data_req(wr_data_req),
        .ddr3_wr_data(wr_data_w), .ddr3_wr_addr_req(wr_addr_req_w),
        .ddr3_wr_addr(wr_addr_w), .ddr3_wr_done(wr_done_w),
        .ddr3_rd_start(rd_start_w), .ddr3_rd_addr_req(rd_addr_req_w),
        .ddr3_rd_addr(rd_addr_w), .ddr3_rd_data_vld(rd_data_vld_w),
        .ddr3_rd_data(rd_data_w), .ddr3_rd_done(rd_done_w),
        .ddr3_addr(ddr3_addr), .ddr3_ba(ddr3_ba), .ddr3_cas_n(ddr3_cas_n),
        .ddr3_ck_n(ddr3_ck_n), .ddr3_ck_p(ddr3_ck_p), .ddr3_cke(ddr3_cke),
        .ddr3_ras_n(ddr3_ras_n), .ddr3_reset_n(ddr3_reset_n), .ddr3_we_n(ddr3_we_n),
        .ddr3_dq(ddr3_dq), .ddr3_dqs_n(ddr3_dqs_n), .ddr3_dqs_p(ddr3_dqs_p),
        .ddr3_dm(ddr3_dm), .ddr3_odt(ddr3_odt)
    );

    // ============= internal ramp source (ui_clk domain) =================
    // Monotone mod-256 byte counter. PC-side _rampcheck.py verifies every
    // received byte == (prev+1) mod 256. Zero break in the ramp == zero loss
    // through the writer + DDR ring + streamer + fpga_core_net + UDP + host.
    //
    // CSR 0x0B: source mode.
    //   bit0=0 (default): ramp source (ramp += 1 per ui_clk)
    //   bit0=1          : fixed value 0x42 (all bytes should be 0x42 on wire)
    //     -> diagnostic: if received bytes != 0x42, the writer/streamer/gearbox
    //        datapath is scrambling; if received bytes == 0x42 uniformly, the
    //        problem was the source or a rate/ordering mismatch upstream.
    reg [7:0] ramp = 8'd0;
    reg       ramp_valid = 0;
    reg       calib_done = 0;
    reg       src_fixed_125 = 1'b0;              // clk125-domain CSR bit
    reg       src_fixed_s0 = 0, src_fixed = 0;
    always @(posedge ui_clk) begin
        src_fixed_s0 <= src_fixed_125;
        src_fixed    <= src_fixed_s0;
    end
    always @(posedge ui_clk) begin
        if (ui_rst) begin ramp <= 8'd0; ramp_valid <= 0; calib_done <= 0; end
        else begin
            if (!calib_done && mig_calib_raw) calib_done <= 1'b1;
            ramp_valid <= calib_done;              // start feeding after calib
            if (ramp_valid) ramp <= ramp + 8'd1;
        end
    end
    wire [7:0] src_byte = src_fixed ? 8'h42 : ramp;

    // ============= writer (ramp -> DDR ring, ui_clk domain) =============
    wire [28:0] wr_ptr_words;
    wire [31:0] words_written;
    wire [31:0] wr_lost_bytes;
    la_ddr_writer #(
        .LENGTH(LENGTH), .IN_BYTES(1),
        .RING_BASE(29'd0), .RING_WORDS(RING_WORDS)
    ) u_wr (
        .cap_clk       (ui_clk),                   // same-domain (50 MHz)
        .cap_rst       (ui_rst),
        .cap_byte      (src_byte),
        .cap_valid_in  (ramp_valid),
        .freeze        (1'b0),
        .ui_clk        (ui_clk),
        .ui_rst        (ui_rst),
        .ddr3_busy     (ddr3_busy),
        .ddr3_wr_start (wr_start_w),
        .ddr3_wr_data_req(wr_data_req),
        .ddr3_wr_data  (wr_data_w),
        .ddr3_wr_addr_req(wr_addr_req_w),
        .ddr3_wr_addr  (wr_addr_w),
        .ddr3_wr_done  (wr_done_w),
        .wr_ptr_words  (wr_ptr_words),
        .words_written (words_written),
        .wr_lost_bytes (wr_lost_bytes)
    );

    // ============= streamer (DDR ring -> UDP, ui_clk + clk125) ==========
    wire [7:0]  stream_tdata;
    wire        stream_tvalid;
    wire        stream_tready;
    wire [31:0] stream_seq;
    wire        stream_rtx;
    wire [28:0] rd_ptr_words;
    wire [31:0] words_drained;
    wire        ring_overrun;
    wire        nack_busy, nack_fail;

    la_ddr_ring_streamer #(
        .LENGTH(LENGTH),
        .RING_BASE(29'd0),
        .RING_WORDS(RING_WORDS),
        .PKT_WORDS(PKT_WORDS)
    ) u_st (
        .ui_clk         (ui_clk),
        .ui_rst         (ui_rst),
        .wr_ptr_words   (wr_ptr_words),
        .wr_words_committed(words_written),
        .drain_credit   (1'b1),                    // S1b: full-speed drain
        .ddr3_rd_start  (rd_start_w),
        .ddr3_rd_addr_req(rd_addr_req_w),
        .ddr3_rd_addr   (rd_addr_w),
        .ddr3_rd_data_vld(rd_data_vld_w),
        .ddr3_rd_data   (rd_data_w),
        .ddr3_rd_done   (rd_done_w),
        .nack_valid     (1'b0),                    // S1b: NACK tie 0
        .nack_start_seq (32'd0),
        .nack_count     (16'd0),
        .nack_busy      (nack_busy),
        .nack_fail      (nack_fail),
        .clk125         (clk125),
        .sys_rst        (sys_rst),
        .stream_tdata   (stream_tdata),
        .stream_tvalid  (stream_tvalid),
        .stream_tready  (stream_tready),
        .stream_seq     (stream_seq),
        .stream_rtx     (stream_rtx),
        .rd_ptr_words   (rd_ptr_words),
        .words_drained  (words_drained),
        .ring_overrun   (ring_overrun)
    );

    // CSR-controlled pause (0x0A): host can halt streaming so :5001 CSR reads
    // are not drowned by the 100+ MB/s stream.
    reg stream_pause_125 = 1'b0;

    // ============= packetiser (clk125): [seq:4 BE] + PAYLOAD ============
    // Emit one UDP packet per PKT_WORDS*16 bytes of drained stream. seq comes
    // from the streamer (monotonic, wrap-independent, ties packet index to DDR
    // absolute-word offset, doc 19 §4). The streamer already emits one byte
    // per PKT_WORDS*16 bytes of ring content, so we frame with a 4-byte BE seq
    // header prepended once per packet, then STREAM_PAYLOAD data bytes.
    localparam integer PKT = STREAM_PAYLOAD + 4;
    reg  [15:0] pos = 0;
    reg  [31:0] pkt_seq = 0;
    reg         pkt_active = 0;
    reg  [31:0] latched_seq = 0;

    // Latch the streamer seq at packet start (first byte of a payload chunk).
    // The streamer's stream_seq is stable across a packet's bytes.
    wire        in_header = (pos < 16'd4);
    wire [7:0]  seq_byte = (pos == 16'd0) ? latched_seq[31:24] :
                           (pos == 16'd1) ? latched_seq[23:16] :
                           (pos == 16'd2) ? latched_seq[15:8]  :
                                            latched_seq[7:0];
    wire        pkt_tready;
    // Advance the streamer only when fpga_core_net actually consumes a payload
    // byte from us (payload phase && our valid && fpga ready). Otherwise the
    // streamer would rush ahead and the received bytes get scrambled.
    wire        pkt_tvalid = pkt_active & (in_header | stream_tvalid);
    assign      stream_tready = pkt_active & ~in_header & pkt_tready & pkt_tvalid;
    wire [7:0]  pkt_tdata  = in_header ? seq_byte : stream_tdata;

    always @(posedge clk125) begin
        if (sys_rst) begin pos <= 0; pkt_active <= 0; pkt_seq <= 0; latched_seq <= 0; stream_pause_125 <= 0; end
        else begin
            // CSR :5002 writes latch here in clk125 domain.
            if (csr_we_w && csr_addr_w == 8'h0A) stream_pause_125 <= csr_data_w[0];
            if (csr_we_w && csr_addr_w == 8'h0B) src_fixed_125   <= csr_data_w[0];
            if (!pkt_active) begin
                // Start only when the streamer has a byte ready — the streamer's
                // internal 128-bit gearbox has already latched a word and stream_seq
                // is stable across the whole PKT_WORDS byte run.
                if (stream_tvalid && !stream_pause_125) begin
                    pkt_active  <= 1'b1;
                    pos         <= 0;
                    latched_seq <= stream_seq;
                end
            end else if (pkt_tvalid && pkt_tready) begin
                if (pos == PKT-1) begin
                    pos <= 0; pkt_seq <= pkt_seq + 1'b1; pkt_active <= 1'b0;
                end else pos <= pos + 1'b1;
            end
        end
    end

    // ============= Ethernet + dbg_regfile (clk125 domain) ===============
    wire [7:0]  csr_addr_w, csr_data_w;
    wire        csr_we_w;
    wire [15:0] ext_addr;
    wire [7:0]  ext_data;
    wire        dbg_rx_good, dbg_rx_bad, dbg_tx_valid;
    wire [1:0]  dbg_selftx_state;
    wire        dbg_selftx_stuck;
    wire        dbg_tx_fifo_ovf, dbg_rx_fifo_ovf, dbg_rx_bad_frame;

    // Snapshot writer/streamer status across ui_clk -> clk125 via toggle
    // (multi-bit fields must cross atomically, same idiom as S1a).
    reg        snap_tog = 0;
    reg [21:0] snap_div = 0;
    reg [31:0] snap_wrote, snap_drained, snap_wr_lost;
    reg [28:0] snap_wr_ptr, snap_rd_ptr;
    reg        snap_migcal, snap_calib, snap_overrun, snap_nack_fail;
    always @(posedge ui_clk) begin
        snap_div <= snap_div + 1'b1;
        if (&snap_div) begin
            snap_wrote      <= words_written;
            snap_drained    <= words_drained;
            snap_wr_lost    <= wr_lost_bytes;
            snap_wr_ptr     <= wr_ptr_words;
            snap_rd_ptr     <= rd_ptr_words;
            snap_migcal     <= mig_calib_raw;
            snap_calib      <= calib_done;
            snap_overrun    <= ring_overrun;
            snap_nack_fail  <= nack_fail;
            snap_tog        <= ~snap_tog;
        end
    end
    reg tog_s0=0, tog_s1=0, tog_s2=0;
    always @(posedge clk125) begin tog_s0<=snap_tog; tog_s1<=tog_s0; tog_s2<=tog_s1; end
    wire snap_valid = tog_s1 ^ tog_s2;
    reg [31:0] wrote_125=0, drained_125=0, wr_lost_125=0;
    reg [28:0] wrptr_125=0, rdptr_125=0;
    reg        migcal_125=0, calib_125=0, overrun_125=0, nack_fail_125=0;
    always @(posedge clk125) if (snap_valid) begin
        wrote_125     <= snap_wrote;
        drained_125   <= snap_drained;
        wr_lost_125   <= snap_wr_lost;
        wrptr_125     <= snap_wr_ptr;
        rdptr_125     <= snap_rd_ptr;
        migcal_125    <= snap_migcal;
        calib_125     <= snap_calib;
        overrun_125   <= snap_overrun;
        nack_fail_125 <= snap_nack_fail;
    end

    wire [7:0] dbg_rdata;
    dbg_regfile u_dbg (
        .clk(clk125), .rst(sys_rst), .clr(1'b0),
        .e_no_traceclk(1'b0), .e_mmcm_unlock(1'b0), .e_cap_overflow(overrun_125),
        .e_selftx_stuck(dbg_selftx_stuck), .e_rx_bad_frame(dbg_rx_bad_frame),
        .e_tx_fifo_ovf(dbg_tx_fifo_ovf), .e_rx_fifo_ovf(dbg_rx_fifo_ovf),
        .sys_mmcm_locked(mmcm_sys_locked),
        .trace_mmcm_locked(calib_125),
        .traceclk_active(1'b0),
        .selftx_state(dbg_selftx_state), .pkt_active(pkt_active),
        .lost_cnt(wr_lost_125),
        .gpio_clk_level(1'b0), .gpio_data_level(4'd0),
        .gpio_clk_edge(1'b0), .gpio_data_edge(4'd0),
        .addr(ext_addr[7:0]), .rdata(dbg_rdata)
    );

    // ---- readout page mux ----
    // Reuse S1a page format at 0xFF5x with a distinct magic (0xD1 = DDR ring
    // selftest) so ddr_selftest_status.py can be extended to decode both.
    wire dbg_page = (ext_addr[15:8] == 8'hFF) &&
                    (ext_addr[7:4] >= 4'h1) && (ext_addr[7:4] <= 4'h4);
    wire [7:0] ring_status =
        (ext_addr == 16'hFF50) ? 8'hD1               :   // MAGIC: DDR ring selftest
        (ext_addr == 16'hFF51) ? {4'b0, nack_fail_125, overrun_125, migcal_125, calib_125} :
        (ext_addr == 16'hFF52) ? wrote_125[7:0]      :
        (ext_addr == 16'hFF53) ? wrote_125[15:8]     :
        (ext_addr == 16'hFF54) ? wrote_125[23:16]    :
        (ext_addr == 16'hFF55) ? wrote_125[31:24]    :
        (ext_addr == 16'hFF56) ? drained_125[7:0]    :
        (ext_addr == 16'hFF57) ? drained_125[15:8]   :
        (ext_addr == 16'hFF58) ? drained_125[23:16]  :
        (ext_addr == 16'hFF59) ? drained_125[31:24]  :
        (ext_addr == 16'hFF5A) ? wr_lost_125[7:0]    :
        (ext_addr == 16'hFF5B) ? wr_lost_125[15:8]   :
        (ext_addr == 16'hFF5C) ? wr_lost_125[23:16]  :
        (ext_addr == 16'hFF5D) ? wr_lost_125[31:24]  :
        (ext_addr == 16'hFF5E) ? wrptr_125[7:0]      :
        (ext_addr == 16'hFF5F) ? wrptr_125[15:8]     :
        (ext_addr == 16'hFF60) ? wrptr_125[23:16]    :
        (ext_addr == 16'hFF61) ? {3'b0, wrptr_125[28:24]} :
        (ext_addr == 16'hFF62) ? rdptr_125[7:0]      :
        (ext_addr == 16'hFF63) ? rdptr_125[15:8]     :
        (ext_addr == 16'hFF64) ? rdptr_125[23:16]    :
        (ext_addr == 16'hFF65) ? {3'b0, rdptr_125[28:24]} :
        (ext_addr == 16'hFF70) ? BUILD_ID[7:0]       :
        (ext_addr == 16'hFF71) ? BUILD_ID[15:8]      :
        (ext_addr == 16'hFF72) ? BUILD_ID[23:16]     :
        (ext_addr == 16'hFF73) ? BUILD_ID[31:24]     :
        8'h00;
    wire ring_page = (ext_addr[15:8] == 8'hFF) &&
                     (ext_addr[7:4] >= 4'h5) && (ext_addr[7:4] <= 4'h7);
    assign ext_data = dbg_page  ? dbg_rdata   :
                      ring_page ? ring_status : 8'h00;

    fpga_core_net #(
        .TARGET("XILINX"), .STREAM(1),
        .STREAM_DEST_IP(DEST_IP), .STREAM_DEST_PORT(DEST_PORT)
    ) u_eth (
        .clk(clk125), .clk90(clk125_90), .rst(sys_rst),
        .btnu(1'b0), .btnl(1'b0), .btnd(1'b0), .btnr(1'b0), .btnc(1'b0),
        .sw(8'h0), .led(),
        .phy_rx_clk(phy_rx_clk), .phy_rxd(phy_rxd), .phy_rx_ctl(phy_rx_ctl),
        .phy_tx_clk(phy_tx_clk), .phy_txd(phy_txd), .phy_tx_ctl(phy_tx_ctl),
        .phy_reset_n(phy_reset_n), .phy_int_n(1'b1), .phy_pme_n(1'b1),
        .uart_rxd(1'b1), .uart_txd(),
        .dbg_rx_good_frame(dbg_rx_good), .dbg_rx_bad_fcs(dbg_rx_bad), .dbg_tx_axis_tvalid(dbg_tx_valid),
        .dbg_selftx_state(dbg_selftx_state), .dbg_selftx_stuck(dbg_selftx_stuck),
        .dbg_tx_fifo_overflow(dbg_tx_fifo_ovf), .dbg_rx_fifo_overflow(dbg_rx_fifo_ovf),
        .dbg_rx_bad_frame(dbg_rx_bad_frame),
        .ext_addr(ext_addr), .ext_data(ext_data),
        .csr_addr(csr_addr_w), .csr_data(csr_data_w), .csr_we(csr_we_w),
        .stream_tdata(pkt_tdata), .stream_tvalid(pkt_tvalid), .stream_tready(pkt_tready)
    );

    // ---- LEDs ----
    reg [24:0] hb = 0;
    always @(posedge clk125) hb <= hb + 1'b1;
    assign led0 = mmcm_sys_locked;
    assign led1 = pkt_active ? hb[24] : 1'b0;

    assign phy_mdio = 1'bz;
    assign phy_mdc  = 1'b0;

endmodule

`default_nettype wire
