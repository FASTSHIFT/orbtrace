// trace_ddr_selftest_top
// =======================
// Proposal 32 P2a: prove the DDR3 MIG can COEXIST with the Ethernet stack +
// dbg_regfile readout, and expose DDR3 self-test status over the EXISTING
// :5001 readout path (reusing proposal 30's debug channel + fpga_health.py),
// NOT a throwaway JTAG/VIO channel.
//
// This is the integration skeleton for the on-chip logic-analyzer black box
// (proposal 32). P2a intentionally does NOT yet tap the trace capture into
// DDR3 -- it runs the P1 write/readback self-test continuously and surfaces
// calib/err/pass via a new dbg readout page (0xFF5x). Once P2a confirms MIG +
// Ethernet coexist and calibrate on a cold boot, P2b adds the source-tap black
// box (method X: independent AsyncFIFO from cap_byte -> ui_clk -> DDR3).
//
// Clocks (all from the 50MHz board oscillator):
//   sys MMCM  : 50 -> 125 / 125@90 / 100   (Ethernet + dbg, clk125 domain)
//   clock IP  : 50 -> 200                  (MIG sys_clk_i; MIG makes ui_clk=50)
// The MIG ui_clk (50MHz) domain runs the DDR3 self-test; its status is CDC'd
// into clk125 for the dbg_regfile / :5001 readout.

`default_nettype none

module trace_ddr_selftest_top #(
    parameter [31:0] DEST_IP   = {8'd192, 8'd168, 8'd10, 8'd245},
    parameter [15:0] DEST_PORT = 16'd5555,
    parameter integer LENGTH   = 64          // 128-bit words per DDR3 burst
) (
    input  wire        sys_clk_50,
    input  wire        rst_n,

    // RGMII (RTL8211E)
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
    output wire        led1           // DDR3 self-test PASS heartbeat
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

    // sys reset synchroniser in the clk125 domain (most consumers, incl. the
    // Ethernet MAC FIFOs, are clk125 — generating sys_rst here keeps the
    // reset-recovery path intra-clk125 instead of a failing clk100->clk125
    // crossing with huge reset fanout).
    reg [3:0] rst_sync = 4'hf;
    always @(posedge clk125 or posedge rst)
        if (rst) rst_sync <= 4'hf;
        else     rst_sync <= {rst_sync[2:0], ~mmcm_sys_locked};
    wire sys_rst = rst_sync[3];

    // ---- MIG reference clock (50 -> 200MHz) ----
    wire sys_clk_200, clk200_locked;
    clock u_clock (
        .clk_out1(sys_clk_200),
        .resetn  (rst_n),
        .locked  (clk200_locked),
        .clk_in1 (sys_clk_50)
    );

    // ================= DDR3 controller + self-test (ui_clk domain) =========
    wire        ui_clk, ui_rst, ddr3_busy;
    wire         wr_start, wr_data_req, wr_addr_req, wr_done;
    reg  [127:0] wr_data;
    reg  [28:0]  wr_addr;
    wire         rd_start, rd_addr_req, rd_data_vld, rd_done;
    reg  [28:0]  rd_addr;
    wire [127:0] rd_data;

    ddr3_ctrl u_ddr3 (
        .sys_clk    (sys_clk_200),
        .sys_rst_n  (clk200_locked),
        .ui_clk     (ui_clk),
        .ui_rst     (ui_rst),
        .ddr3_busy  (ddr3_busy),
        .ddr3_wr_start(wr_start), .ddr3_wr_data_req(wr_data_req),
        .ddr3_wr_data(wr_data), .ddr3_wr_addr_req(wr_addr_req),
        .ddr3_wr_addr(wr_addr), .ddr3_wr_done(wr_done),
        .ddr3_rd_start(rd_start), .ddr3_rd_addr_req(rd_addr_req),
        .ddr3_rd_addr(rd_addr), .ddr3_rd_data_vld(rd_data_vld),
        .ddr3_rd_data(rd_data), .ddr3_rd_done(rd_done),
        .ddr3_addr(ddr3_addr), .ddr3_ba(ddr3_ba), .ddr3_cas_n(ddr3_cas_n),
        .ddr3_ck_n(ddr3_ck_n), .ddr3_ck_p(ddr3_ck_p), .ddr3_cke(ddr3_cke),
        .ddr3_ras_n(ddr3_ras_n), .ddr3_reset_n(ddr3_reset_n), .ddr3_we_n(ddr3_we_n),
        .ddr3_dq(ddr3_dq), .ddr3_dqs_n(ddr3_dqs_n), .ddr3_dqs_p(ddr3_dqs_p),
        .ddr3_dm(ddr3_dm), .ddr3_odt(ddr3_odt)
    );

    reg calib_done = 0;
    always @(posedge ui_clk) if (!ui_rst) calib_done <= 1'b1;

    // self-test FSM (same as ddr3_selftest_top, board-proven)
    localparam S_ARBIT=0, S_WRITE=1, S_READ=2;
    reg [1:0]  st = S_ARBIT;
    reg        wr_rd_flag = 0;
    reg [9:0]  wr_cnt = 0, rd_cnt = 0;
    reg        err_sticky = 0;
    reg [31:0] err_count = 0, pass_bursts = 0;
    localparam [9:0] MAX_NUM = LENGTH-1;

    function [127:0] patgen(input [9:0] w);
        patgen = {16{w[7:0]}} ^ {4{32'hA5A5_0000 | w}};
    endfunction

    assign wr_start = (wr_rd_flag == 1'b0) && (st == S_ARBIT) && calib_done;
    assign rd_start = (wr_rd_flag == 1'b1) && (st == S_ARBIT) && calib_done;

    always @(posedge ui_clk) begin
        if (ui_rst) wr_addr <= 29'd0;
        else if (wr_addr_req) wr_addr <= wr_addr + 29'd8;
    end
    always @(posedge ui_clk) begin
        if (ui_rst) rd_addr <= 29'd0;
        else if (rd_addr_req) rd_addr <= rd_addr + 29'd8;
    end

    always @(posedge ui_clk) begin
        if (ui_rst) begin st <= S_ARBIT; wr_rd_flag <= 0; end
        else case (st)
            S_ARBIT: if (calib_done) st <= wr_rd_flag ? S_READ : S_WRITE;
            S_WRITE: if (wr_done) begin st <= S_ARBIT; wr_rd_flag <= 1'b1; end
            S_READ:  if (rd_done) begin st <= S_ARBIT; wr_rd_flag <= 1'b0; end
            default: st <= S_ARBIT;
        endcase
    end

    always @(posedge ui_clk) begin
        if (ui_rst) wr_cnt <= 0;
        else if (wr_data_req) begin
            wr_data <= patgen(wr_cnt);
            wr_cnt  <= (wr_cnt == MAX_NUM) ? 10'd0 : wr_cnt + 1'b1;
        end
    end

    always @(posedge ui_clk) begin
        if (ui_rst) begin
            rd_cnt <= 0; err_sticky <= 0; err_count <= 0; pass_bursts <= 0;
        end else if (rd_data_vld) begin
            if (rd_data !== patgen(rd_cnt)) begin
                err_sticky <= 1'b1; err_count <= err_count + 1'b1;
            end
            if (rd_cnt == MAX_NUM) begin
                rd_cnt <= 10'd0;
                if (!err_sticky) pass_bursts <= pass_bursts + 1'b1;
            end else rd_cnt <= rd_cnt + 1'b1;
        end
    end

    // ---- CDC ui_clk-domain DDR3 status -> clk125 for the :5001 readout ----
    // Slow-moving status; double-flop each field. err_count/pass_bursts are
    // multi-bit but change slowly relative to clk125, and we only need
    // approximate values for a health check, so a plain 2-FF sync is adequate
    // (a gray-coded handshake is overkill for human-read diagnostics).
    reg        calib_s0=0, calib_125=0;
    reg        errs_s0=0,  errs_125=0;
    reg [31:0] errc_s0=0,  errc_125=0;
    reg [31:0] passb_s0=0, passb_125=0;
    reg [1:0]  ddst_s0=0,  ddst_125=0;
    always @(posedge clk125) begin
        calib_s0 <= calib_done;  calib_125 <= calib_s0;
        errs_s0  <= err_sticky;  errs_125  <= errs_s0;
        errc_s0  <= err_count;   errc_125  <= errc_s0;
        passb_s0 <= pass_bursts; passb_125 <= passb_s0;
        ddst_s0  <= st;          ddst_125  <= ddst_s0;
    end

    // ================= Ethernet + dbg_regfile (clk125 domain) ==============
    wire [7:0]  csr_addr_w, csr_data_w;
    wire        csr_we_w;
    wire [15:0] ext_addr;
    wire [7:0]  ext_data;
    wire        dbg_rx_good, dbg_rx_bad, dbg_tx_valid;
    wire [1:0]  dbg_selftx_state;
    wire        dbg_selftx_stuck;
    wire        dbg_tx_fifo_ovf, dbg_rx_fifo_ovf, dbg_rx_bad_frame;

    wire [7:0] dbg_rdata;
    dbg_regfile u_dbg (
        .clk(clk125), .rst(sys_rst), .clr(1'b0),
        .e_no_traceclk(1'b0), .e_mmcm_unlock(1'b0), .e_cap_overflow(1'b0),
        .e_selftx_stuck(dbg_selftx_stuck), .e_rx_bad_frame(dbg_rx_bad_frame),
        .e_tx_fifo_ovf(dbg_tx_fifo_ovf), .e_rx_fifo_ovf(dbg_rx_fifo_ovf),
        .sys_mmcm_locked(mmcm_sys_locked),
        .trace_mmcm_locked(calib_125),          // reuse field: DDR3 calibrated
        .traceclk_active(1'b0),
        .selftx_state(dbg_selftx_state), .pkt_active(1'b0),
        .lost_cnt(errc_125),
        .gpio_clk_level(1'b0), .gpio_data_level(4'd0),
        .gpio_clk_edge(1'b0), .gpio_data_edge(4'd0),
        .addr(ext_addr[7:0]), .rdata(dbg_rdata)
    );

    // ---- readout page mux: dbg_regfile at 0xFF1x..0xFF4x (proposal 30),
    //      DDR3 self-test status at 0xFF50..0xFF5B (proposal 32 P2a) ----
    wire dbg_page = (ext_addr[15:8] == 8'hFF) &&
                    (ext_addr[7:4] >= 4'h1) && (ext_addr[7:4] <= 4'h4);
    wire [7:0] ddr3_status =
        (ext_addr == 16'hFF50) ? 8'hD3               :  // MAGIC: DDR3 page
        (ext_addr == 16'hFF51) ? {6'b0, errs_125, calib_125} :
        (ext_addr == 16'hFF52) ? errc_125[7:0]       :
        (ext_addr == 16'hFF53) ? errc_125[15:8]      :
        (ext_addr == 16'hFF54) ? errc_125[23:16]     :
        (ext_addr == 16'hFF55) ? errc_125[31:24]     :
        (ext_addr == 16'hFF56) ? passb_125[7:0]      :
        (ext_addr == 16'hFF57) ? passb_125[15:8]     :
        (ext_addr == 16'hFF58) ? passb_125[23:16]    :
        (ext_addr == 16'hFF59) ? passb_125[31:24]    :
        (ext_addr == 16'hFF5A) ? {6'b0, ddst_125}    :
        8'h00;
    wire ddr3_page = (ext_addr[15:4] == 12'hFF5);
    assign ext_data = dbg_page  ? dbg_rdata   :
                      ddr3_page ? ddr3_status : 8'h00;

    fpga_core_net #(
        .TARGET("XILINX"), .STREAM(0)
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
        .stream_tdata(8'h0), .stream_tvalid(1'b0), .stream_tready()
    );

    // ---- LED ----
    reg [24:0] hb = 0;
    always @(posedge ui_clk) hb <= hb + 1'b1;
    wire pass = (pass_bursts != 0) && !err_sticky;
    assign led0 = mmcm_sys_locked;
    assign led1 = pass ? hb[24] : 1'b0;

    assign phy_mdio = 1'bz;
    assign phy_mdc  = 1'b0;

endmodule

`default_nettype wire
