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
    parameter integer FIFO_DEPTH = 8192       // CDC FIFO bytes (abosrb TX bursts)
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
    // only push real captured bytes once the trace MMCM has locked
    wire        fifo_in_valid = cap_valid & clk90_locked;

    axis_async_fifo #(
        .DEPTH(FIFO_DEPTH), .DATA_WIDTH(8),
        .KEEP_ENABLE(0), .LAST_ENABLE(0), .USER_ENABLE(0), .FRAME_FIFO(0)
    ) u_cdc (
        .s_clk(clk90), .s_rst(sys_rst),
        .s_axis_tdata(cap_byte), .s_axis_tkeep(1'b0),
        .s_axis_tvalid(fifo_in_valid), .s_axis_tready(fifo_in_ready),
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

    // capture-side drop: a byte arrived but the FIFO could not take it
    wire drop_evt = fifo_in_valid & ~fifo_in_ready;
    reg [31:0] lost_cnt = 0;
    always @(posedge clk90) begin
        if (sys_rst) lost_cnt <= 0;
        else if (drop_evt) lost_cnt <= lost_cnt + 1'b1;
    end

    // ---- packetiser (clk125): prepend a 32-bit big-endian sequence number to
    //      each PAYLOAD-byte UDP packet so the host can detect any gap. The
    //      self-TX FSM in fpga_core_net counts STREAM_PKT_BYTES per packet and
    //      pulls a byte whenever stream_tready is high; we track that position
    //      and emit seq[0..3] for the first 4, then FIFO bytes. ----
    localparam integer PKT = PAYLOAD + 4;
    reg [31:0] seq = 0;
    reg [15:0] pos = 0;                 // byte index within current packet
    reg        pkt_active = 0;          // a packet is in flight (no underrun)
    wire       stream_tready;
    wire       in_header = (pos < 16'd4);

    // Start a packet only when the FIFO holds a full PAYLOAD, so once started
    // the payload phase never underruns (the self-TX FSM would otherwise stall
    // the MAC mid-packet). While the header (4 seq bytes) goes out the FIFO
    // keeps filling, so by payload time there is >= PAYLOAD buffered.
    wire       can_start = (m_depth >= PAYLOAD[$clog2(FIFO_DEPTH):0]);
    // stream is "valid" to the core only while a packet is active
    wire       stream_tvalid = pkt_active & (in_header | fifo_out_valid);
    wire [7:0] seq_byte = (pos == 16'd0) ? seq[31:24] :
                          (pos == 16'd1) ? seq[23:16] :
                          (pos == 16'd2) ? seq[15:8]  : seq[7:0];
    wire [7:0] stream_tdata = in_header ? seq_byte : fifo_out_data;
    // pop the FIFO only on accepted payload (non-header) beats
    assign fifo_out_ready = pkt_active & (~in_header) & stream_tready;

    always @(posedge clk125) begin
        if (sys_rst) begin
            pos <= 0; seq <= 0; pkt_active <= 0;
        end else if (!pkt_active) begin
            if (can_start) pkt_active <= 1'b1;  // begin a packet
            pos <= 0;
        end else if (stream_tvalid && stream_tready) begin
            if (pos == PKT-1) begin
                pos <= 0;
                seq <= seq + 1'b1;
                pkt_active <= 1'b0;             // packet done; re-gate on depth
            end else begin
                pos <= pos + 1'b1;
            end
        end
    end

    // ---- CSR :5002 readback of lost_cnt (CDC clk90 -> clk125) ----
    reg [31:0] lost_s0 = 0, lost_125 = 0;
    always @(posedge clk125) begin lost_s0 <= lost_cnt; lost_125 <= lost_s0; end

    wire [7:0]  csr_addr_w, csr_data_w;
    wire        csr_we_w;
    wire [15:0] ext_addr;
    wire [7:0]  ext_data;
    // status readout (paged :5001 like the one-shot top): lost_cnt + locked
    wire [7:0] status_byte =
        (ext_addr == 16'hFF00) ? lost_125[7:0]   :
        (ext_addr == 16'hFF01) ? lost_125[15:8]  :
        (ext_addr == 16'hFF02) ? lost_125[23:16] :
        (ext_addr == 16'hFF03) ? lost_125[31:24] :
        (ext_addr == 16'hFF04) ? {7'b0, clk90_locked} : 8'h00;
    assign ext_data = status_byte;

    assign led0 = ~clk90_locked;
    assign led1 = ~fifo_out_valid;     // lit when streaming (FIFO has data)

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
        .dbg_rx_good_frame(), .dbg_rx_bad_fcs(), .dbg_tx_axis_tvalid(),
        .ext_addr(ext_addr), .ext_data(ext_data),
        .csr_addr(csr_addr_w), .csr_data(csr_data_w), .csr_we(csr_we_w),
        .stream_tdata(stream_tdata), .stream_tvalid(stream_tvalid),
        .stream_tready(stream_tready)
    );

    assign phy_mdio = 1'bz;
    assign phy_mdc  = 1'b0;

endmodule

`default_nettype wire
