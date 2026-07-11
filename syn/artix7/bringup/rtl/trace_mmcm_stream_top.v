// trace_mmcm_stream_top
// ======================
// CONTINUOUS streaming variant of trace_mmcm_top (proposal 22 §8). Instead of
// the one-shot 64 KB BRAM, the MMCM-sampled trace bytes go through a CDC
// AsyncFIFO into fpga_core_net's self-initiated UDP TX path, so the host gets
// an unbounded stream of trace bytes (enough to capture LVGL, not just a 64 KB
// window).
//
//   STM32 ETM 4-bit (TRACECLK 21M) -> trace_capture_mmcm (IDDR on 90-deg clk)
//        -> cap_byte {trace_a[k],trace_b[k-1]} per TRACECLK period (clk90)
//        -> axis_async_fifo (clk90 -> clk125)
//        -> packetiser: [4-byte seq][PKT_BYTES trace] -> fpga_core_net STREAM
//        -> continuous UDP to STREAM_DEST_IP:STREAM_DEST_PORT
//
// Loss accounting (the trace source CANNOT be back-pressured):
//   - trace_lost_cnt: cap_valid arrived while the FIFO was full (capture-side
//     drop). Read via :5002 CSR readback / status.
//   - per-packet 32-bit sequence number lets the host detect network/host drop
//     AND capture-side gaps (seq jumps but the lost counter localises cause).
//
// Decode: host strips the 4-byte seq per packet, concatenates trace bytes, then
// runs the SAME pipeline as the one-shot path (decode/mmcm_decode.py).

`default_nettype none

module trace_mmcm_stream_top #(
    parameter MULT  = 40,            // MMCM mult: VCO = TRACECLK*MULT (600-1440M)
    parameter DIVID = 40,            // CLKOUT divide: VCO/DIVID = TRACECLK
    parameter CLKIN_PERIOD = 47.6,   // ns, real TRACECLK period
    parameter PHASE = 90.0,          // CLKOUT1 sample-clock phase (deg)
    parameter WIDTH = 4,
    parameter [31:0] DEST_IP   = {8'd192, 8'd168, 8'd10, 8'd245},
    parameter [15:0] DEST_PORT = 16'd5555,
    parameter integer PAYLOAD  = 1024,        // trace bytes per UDP packet
    parameter integer FIFO_DEPTH = 8192,      // CDC FIFO bytes (abosrb TX bursts)
    parameter integer BANDWIDTH_TEST = 0      // 1: bypass trace, fill FIFO from
                                              // free-running counter at clk125 rate
                                              // to measure pure network throughput
) (
    input  wire        sys_clk_50,
    input  wire        rst_n,

    input  wire        phy_rx_clk,
    input  wire [3:0]  phy_rxd,
    input  wire        phy_rx_ctl,
    output wire        phy_tx_clk,
    output wire [3:0]  phy_txd,
    output wire        phy_tx_ctl,
    output wire        phy_reset_n,
    inout  wire        phy_mdio,
    output wire        phy_mdc,

    input  wire        trace_clk_in,
    input  wire [3:0]  trace_data_in,

    output wire        led0,          // mmcm locked
    output wire        led1           // streaming activity
);
    wire rst = ~rst_n;

    // ---- system clocks (sys 50M -> 125 / 125@90 / 100) ----
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
    always @(posedge clk100 or posedge rst)
        if (rst) rst_sync <= 4'hf;
        else     rst_sync <= {rst_sync[2:0], ~mmcm_sys_locked};
    wire sys_rst = rst_sync[3];

    // ---- MMCM 90-deg phase-shift capture front-end (clk90 domain) ----
    wire        cap_clk;
    wire        clk90;
    wire        clk90_locked;
    wire [3:0]  trace_a, trace_b;
    wire [7:0]  cap_byte;
    wire        cap_valid;
    trace_capture_mmcm #(.MULT(MULT), .DIVID(DIVID), .CLKIN_PERIOD(CLKIN_PERIOD),
                         .PHASE(PHASE), .WIDTH(WIDTH)) u_cap (
        .rst(sys_rst),
        .trace_clk_p(trace_clk_in), .trace_data_p(trace_data_in),
        .trace_clk(cap_clk), .clk90_out(clk90),
        .trace_a(trace_a), .trace_b(trace_b),
        .mmcm_locked(clk90_locked),
        .cap_byte(cap_byte), .cap_valid(cap_valid)
    );

    // ---- CDC AsyncFIFO: clk90 capture -> clk125 stream ----
    wire        fifo_in_ready;
    wire [7:0]  fifo_out_data;
    wire        fifo_out_valid;
    wire        fifo_out_ready;
    wire [$clog2(FIFO_DEPTH):0] m_depth;

    // BANDWIDTH_TEST mode: bypass trace front-end entirely, feed the FIFO a
    // free-running counter from clk125.  This saturates the network TX path at
    // 125 MB/s (one byte per 125MHz clock), letting us measure the pure UDP
    // egress throughput without needing an STM32 trace source.
    generate if (BANDWIDTH_TEST) begin : g_bwtest
        // Direct stream to fpga_core_net — NO FIFO, NO packetiser.
        // Exactly like selftx_test_top: counter byte, always valid.
        reg [7:0] bw_cnt = 0;
        always @(posedge clk125)
            if (sys_rst) bw_cnt <= 8'd0;
            else if (stream_tready) bw_cnt <= bw_cnt + 8'd1;

        // No FIFO needed — stub out fifo signals
        assign fifo_in_ready = 1'b1;

        axis_async_fifo #(
            .DEPTH(FIFO_DEPTH), .DATA_WIDTH(8),
            .KEEP_ENABLE(0), .LAST_ENABLE(0), .USER_ENABLE(0), .FRAME_FIFO(0)
        ) u_cdc (
            .s_clk(clk125), .s_rst(sys_rst),
            .s_axis_tdata(8'd0), .s_axis_tkeep(1'b0),
            .s_axis_tvalid(1'b0), .s_axis_tready(),
            .s_axis_tlast(1'b0), .s_axis_tid(8'h0), .s_axis_tdest(8'h0), .s_axis_tuser(1'b0),
            .m_clk(clk125), .m_rst(sys_rst),
            .m_axis_tdata(fifo_out_data), .m_axis_tkeep(),
            .m_axis_tvalid(fifo_out_valid), .m_axis_tready(fifo_out_ready),
            .m_axis_tlast(), .m_axis_tid(), .m_axis_tdest(), .m_axis_tuser(),
            .s_pause_req(1'b0), .s_pause_ack(), .m_pause_req(1'b0), .m_pause_ack(),
            .s_status_depth(), .s_status_depth_commit(), .s_status_overflow(),
            .s_status_bad_frame(), .s_status_good_frame(),
            .m_status_depth(m_depth), .m_status_depth_commit(), .m_status_overflow(),
            .m_status_bad_frame(), .m_status_good_frame()
        );
    end else begin : g_trace
        // Trace data path: either raw cap_byte (4-bit) or traceIF-framed (2-bit).
        // traceIF correctly handles the 2-bit TPIU frame assembly that cannot
        // be reliably done on the PC side.
        wire [7:0] trace_byte;
        wire       trace_byte_valid;

        if (WIDTH == 2) begin : g_traceif
            // 2-bit: traceIF assembles TPIU frames, tpiu_demux extracts ETM bytes
            wire        fr_avail;
            wire [127:0] frame;
            traceIF #(.MAXBUSWIDTH(4)) u_traceif (
                .rst(sys_rst | ~clk90_locked),
                .traceDina(trace_b), .traceDinb(trace_a),
                .traceClkin(clk90),
                .width(2'b10),
                .edgeOutput(), .FrAvail(fr_avail), .Frame(frame)
            );

            // Toggle → pulse for FrAvail (in clk90 domain)
            reg fr_d;
            always @(posedge clk90) fr_d <= fr_avail;
            wire frame_pulse = fr_avail ^ fr_d;

            // Byte-reverse frame for tpiu_demux (it expects in_frame[7:0]=first byte)
            wire [127:0] dmux_frame;
            genvar gi;
            for (gi = 0; gi < 16; gi = gi + 1) begin : g_rev
                assign dmux_frame[8*gi +: 8] = frame[8*(15-gi) +: 8];
            end

            // tpiu_demux: extracts ETM stream bytes from TPIU frames
            wire [7:0] dmux_data;
            wire       dmux_valid, dmux_last, dmux_ready;
            tpiu_demux u_demux (
                .clk(clk90), .rst(sys_rst | ~clk90_locked),
                .in_frame(dmux_frame), .in_valid(frame_pulse), .in_ready(),
                .bp_valid(1'b0), .bp_data(8'd0), .bp_ready(),
                .bypass_sel(1'b0),
                .out_data(dmux_data), .out_valid(dmux_valid),
                .out_last(dmux_last), .out_ready(fifo_in_ready)
            );

            assign trace_byte = dmux_data;
            assign trace_byte_valid = dmux_valid;
        end else begin : g_raw
            // 4-bit: raw {trace_a, trace_b_q} byte, 1 per TRACECLK
            assign trace_byte = cap_byte;
            assign trace_byte_valid = cap_valid & clk90_locked;
        end

        axis_async_fifo #(
            .DEPTH(FIFO_DEPTH), .DATA_WIDTH(8),
            .KEEP_ENABLE(0), .LAST_ENABLE(0), .USER_ENABLE(0), .FRAME_FIFO(0)
        ) u_cdc (
            .s_clk(clk90), .s_rst(sys_rst),
            .s_axis_tdata(trace_byte), .s_axis_tkeep(1'b0),
            .s_axis_tvalid(trace_byte_valid), .s_axis_tready(fifo_in_ready),
            .s_axis_tlast(1'b0), .s_axis_tid(8'h0), .s_axis_tdest(8'h0), .s_axis_tuser(1'b0),
            .m_clk(clk125), .m_rst(sys_rst),
            .m_axis_tdata(fifo_out_data), .m_axis_tkeep(),
            .m_axis_tvalid(fifo_out_valid), .m_axis_tready(fifo_out_ready),
            .m_axis_tlast(), .m_axis_tid(), .m_axis_tdest(), .m_axis_tuser(),
            .s_pause_req(1'b0), .s_pause_ack(), .m_pause_req(1'b0), .m_pause_ack(),
            .s_status_depth(), .s_status_depth_commit(), .s_status_overflow(),
            .s_status_bad_frame(), .s_status_good_frame(),
            .m_status_depth(m_depth), .m_status_depth_commit(), .m_status_overflow(),
            .m_status_bad_frame(), .m_status_good_frame()
        );
    end endgenerate

    // capture-side drop counter: counts bytes lost to FIFO overflow.
    // Clock domain depends on mode: trace mode writes from clk90, bw test from clk125.
    wire [31:0] lost_cnt;
    generate if (BANDWIDTH_TEST) begin : g_lost
        reg [31:0] cnt_r = 0;
        always @(posedge clk125) begin
            if (sys_rst) cnt_r <= 0;
            else if (~fifo_in_ready) cnt_r <= cnt_r + 1'b1;
        end
        assign lost_cnt = cnt_r;
    end else begin : g_lost_t
        reg [31:0] cnt_r = 0;
        wire drop_evt = g_trace.trace_byte_valid & ~fifo_in_ready;
        always @(posedge clk90) begin
            if (sys_rst) cnt_r <= 0;
            else if (drop_evt) cnt_r <= cnt_r + 1'b1;
        end
        assign lost_cnt = cnt_r;
    end endgenerate

    // ---- packetiser (clk125): prepend a 32-bit big-endian sequence number to
    //      each PAYLOAD-byte UDP packet so the host can detect any gap. The
    //      self-TX FSM in fpga_core_net counts STREAM_PKT_BYTES per packet and
    //      pulls a byte whenever stream_tready is high; we track that position
    //      and emit seq[0..3] for the first 4, then FIFO bytes. ----
    localparam integer PKT = BANDWIDTH_TEST ? 1024 : (PAYLOAD + 4);
    wire       stream_tready;
    wire [7:0] stream_tdata;
    wire       stream_tvalid;
    reg        pkt_active = 0;

    generate if (BANDWIDTH_TEST) begin : g_pkt_bw
        // Bypass packetiser: direct stream like selftx_test_top
        assign stream_tvalid = 1'b1;
        assign stream_tdata  = g_bwtest.bw_cnt;
        assign fifo_out_ready = 1'b0;  // FIFO unused
        always @(posedge clk125) pkt_active <= 1'b1; // for LED: always "active"
    end else begin : g_pkt_trace
        reg [31:0] seq = 0;
        reg [15:0] pos = 0;
        wire       in_header = (pos < 16'd4);

        // Heartbeat: when FIFO has insufficient data for a full packet AND
        // ~1 second has elapsed since the last packet, send a heartbeat packet
        // (payload = all zeros). This keeps ARP alive and lets host confirm link.
        // Startup delay: don't send ANY packet for ~5s after reset, giving the
        // network time to establish link + ARP before self-TX starts.
        reg [29:0] startup_cnt = 0;
        wire startup_done = startup_cnt[29];  // ~4.3s at 125MHz
        always @(posedge clk125)
            if (sys_rst) startup_cnt <= 0;
            else if (!startup_done) startup_cnt <= startup_cnt + 1'b1;

        reg [29:0] hb_timer = 0;            // 2^30/125MHz ≈ 8.6s between heartbeats
        wire       hb_due = hb_timer[29];
        wire       can_start_data = (m_depth >= PAYLOAD[$clog2(FIFO_DEPTH):0]);
        wire       can_start = startup_done & (can_start_data | hb_due);
        reg        is_heartbeat = 0;        // current packet is a heartbeat (payload=0)

        always @(posedge clk125) begin
            if (sys_rst)
                hb_timer <= 0;
            else if (pkt_active)
                hb_timer <= 0;              // reset on any packet sent
            else
                hb_timer <= hb_timer + 1'b1;
        end

        // Data mux: heartbeat packets send 0x00 instead of FIFO data
        assign stream_tvalid = pkt_active & (in_header | (is_heartbeat ? 1'b1 : fifo_out_valid));
        wire [7:0] seq_byte = (pos == 16'd0) ? seq[31:24] :
                              (pos == 16'd1) ? seq[23:16] :
                              (pos == 16'd2) ? seq[15:8]  : seq[7:0];
        assign stream_tdata = in_header ? seq_byte : (is_heartbeat ? 8'h00 : fifo_out_data);
        // Only pop FIFO for real data packets (not heartbeat)
        assign fifo_out_ready = pkt_active & (~in_header) & (~is_heartbeat) & stream_tready;

        always @(posedge clk125) begin
            if (sys_rst) begin
                pos <= 0; seq <= 0; pkt_active <= 0; is_heartbeat <= 0;
            end else if (!pkt_active) begin
                if (can_start) begin
                    pkt_active <= 1'b1;
                    is_heartbeat <= ~can_start_data;  // heartbeat if no data
                end
                pos <= 0;
            end else if (stream_tvalid && stream_tready) begin
                if (pos == PKT-1) begin
                    pos <= 0;
                    seq <= seq + 1'b1;
                    pkt_active <= 1'b0;
                    is_heartbeat <= 0;
                end else begin
                    pos <= pos + 1'b1;
                end
            end
        end
    end endgenerate

    // ---- CSR :5002 readback of lost_cnt (CDC clk90 -> clk125) ----
    reg [31:0] lost_s0 = 0, lost_125 = 0;
    always @(posedge clk125) begin lost_s0 <= lost_cnt; lost_125 <= lost_s0; end

    // ---- forward declarations for the debug taps + readout below ----
    wire [7:0]  csr_addr_w, csr_data_w;
    wire        csr_we_w;
    wire [15:0] ext_addr;
    wire [7:0]  ext_data;
    wire        dbg_rx_good, dbg_rx_bad, dbg_tx_valid;
    wire [1:0]  dbg_selftx_state;
    wire        dbg_selftx_stuck;
    wire        dbg_tx_fifo_ovf, dbg_rx_fifo_ovf, dbg_rx_bad_frame;

    // ==================================================================
    // Observability taps -> dbg_regfile (proposal 30 P1). All in clk125.
    // ==================================================================
    // clk90_locked / cap_valid are in other domains; sync into clk125.
    reg trace_lock_s0=0, trace_lock_125=0, trace_lock_125_q=0;
    always @(posedge clk125) begin
        trace_lock_s0   <= clk90_locked;
        trace_lock_125  <= trace_lock_s0;
        trace_lock_125_q<= trace_lock_125;
    end
    // TRACECLK activity: toggle a flag in clk90 on each cap_valid, sync + edge-
    // detect in clk125; "active" if it changed within a ~13ms window.
    reg cap_tog = 0;
    always @(posedge clk90) if (cap_valid) cap_tog <= ~cap_tog;
    reg cap_tog_s0=0, cap_tog_125=0, cap_tog_125_q=0;
    always @(posedge clk125) begin
        cap_tog_s0<=cap_tog; cap_tog_125<=cap_tog_s0; cap_tog_125_q<=cap_tog_125;
    end
    wire cap_edge = cap_tog_125 ^ cap_tog_125_q;
    reg [20:0] noact_cnt = 0;          // ~13.4ms at 125MHz before "no TRACECLK"
    reg traceclk_active = 0;
    always @(posedge clk125) begin
        if (cap_edge) begin noact_cnt <= 0; traceclk_active <= 1'b1; end
        else if (!noact_cnt[20]) noact_cnt <= noact_cnt + 1'b1;
        else traceclk_active <= 1'b0;
    end
    // lost_cnt increment -> capture overflow pulse
    reg [31:0] lost_125_q = 0;
    always @(posedge clk125) lost_125_q <= lost_125;
    wire e_cap_overflow = (lost_125 != lost_125_q);
    // trace MMCM lost lock (falling edge), only meaningful once it locked once
    reg trace_locked_ever = 0;
    always @(posedge clk125) if (trace_lock_125) trace_locked_ever <= 1'b1;
    wire e_mmcm_unlock = trace_locked_ever & trace_lock_125_q & ~trace_lock_125;
    // no-TRACECLK error: became inactive after having been active (edge to 0)
    reg traceclk_active_q = 0;
    always @(posedge clk125) traceclk_active_q <= traceclk_active;
    wire e_no_traceclk = traceclk_active_q & ~traceclk_active;

    wire [7:0] dbg_rdata;
    dbg_regfile u_dbg (
        .clk(clk125), .rst(sys_rst), .clr(1'b0),
        .e_no_traceclk (e_no_traceclk),
        .e_mmcm_unlock (e_mmcm_unlock),
        .e_cap_overflow(e_cap_overflow),
        .e_selftx_stuck(dbg_selftx_stuck),
        .e_rx_bad_frame(dbg_rx_bad_frame),
        .e_tx_fifo_ovf (dbg_tx_fifo_ovf),
        .e_rx_fifo_ovf (dbg_rx_fifo_ovf),
        .sys_mmcm_locked(mmcm_sys_locked),
        .trace_mmcm_locked(trace_lock_125),
        .traceclk_active(traceclk_active),
        .selftx_state(dbg_selftx_state),
        .pkt_active(pkt_active),
        .lost_cnt(lost_125),
        .addr(ext_addr[7:0]),
        .rdata(dbg_rdata)
    );

    // status readout (paged :5001 like the one-shot top): lost_cnt + locked,
    // plus the dbg_regfile at page 0xFF1x..0xFF3x (proposal 30 P1).
    wire        dbg_page = (ext_addr[15:8] == 8'hFF) &&
                           (ext_addr[7:4] >= 4'h1) && (ext_addr[7:4] <= 4'h3);
    wire [7:0] status_byte =
        (ext_addr == 16'hFF00) ? lost_125[7:0]   :
        (ext_addr == 16'hFF01) ? lost_125[15:8]  :
        (ext_addr == 16'hFF02) ? lost_125[23:16] :
        (ext_addr == 16'hFF03) ? lost_125[31:24] :
        (ext_addr == 16'hFF04) ? {7'b0, clk90_locked} :
        dbg_page                ? dbg_rdata : 8'h00;
    assign ext_data = status_byte;

    // ---- LED status + observability taps declared above (before dbg_regfile) ----

    fpga_core_net #(
        .TARGET("XILINX"),
        .STREAM(1),
        .UDP_CHECKSUM_GEN_ENABLE(0),   // see fpga_core_net: checksum gen stalls
                                       // a continuous self-TX stream (sim-proven)
        .STREAM_DEST_IP(DEST_IP),
        .STREAM_DEST_PORT(DEST_PORT),
        .STREAM_PKT_BYTES(PKT[15:0])
    ) u_eth (
        .clk(clk125), .clk90(clk125_90), .rst(sys_rst),
        .btnu(1'b0), .btnl(1'b0), .btnd(1'b0), .btnr(1'b0), .btnc(1'b0),
        .sw(8'h0), .led(),
        .phy_rx_clk(phy_rx_clk), .phy_rxd(phy_rxd), .phy_rx_ctl(phy_rx_ctl),
        .phy_tx_clk(phy_tx_clk), .phy_txd(phy_txd), .phy_tx_ctl(phy_tx_ctl),
        .phy_reset_n(phy_reset_n),
        .phy_int_n(1'b1), .phy_pme_n(1'b1),
        .uart_rxd(1'b1), .uart_txd(),
        .dbg_rx_good_frame(dbg_rx_good), .dbg_rx_bad_fcs(dbg_rx_bad), .dbg_tx_axis_tvalid(dbg_tx_valid),
        .dbg_selftx_state(dbg_selftx_state), .dbg_selftx_stuck(dbg_selftx_stuck),
        .dbg_tx_fifo_overflow(dbg_tx_fifo_ovf), .dbg_rx_fifo_overflow(dbg_rx_fifo_ovf),
        .dbg_rx_bad_frame(dbg_rx_bad_frame),
        .ext_addr(ext_addr), .ext_data(ext_data),
        .csr_addr(csr_addr_w), .csr_data(csr_data_w), .csr_we(csr_we_w),
        .stream_tdata(stream_tdata), .stream_tvalid(stream_tvalid),
        .stream_tready(stream_tready)
    );

    // ---- LED status indicator ----
    // In BANDWIDTH_TEST mode trace MMCM won't lock (no trace clock), so force
    // the trace_mmcm_locked input high to show "streaming ok" on led1.
    wire trace_locked_eff = BANDWIDTH_TEST ? 1'b1 : clk90_locked;

    led_status u_leds (
        .clk(clk125), .rst(sys_rst),
        .sys_mmcm_locked(mmcm_sys_locked),
        .rx_good_frame(dbg_rx_good),
        .tx_axis_tvalid(dbg_tx_valid),
        .trace_mmcm_locked(trace_locked_eff),
        .pkt_active(pkt_active),
        .lost_cnt(lost_125),
        .led0(led0),
        .led1(led1)
    );

    assign phy_mdio = 1'bz;
    assign phy_mdc  = 1'b0;

endmodule

`default_nettype wire
