// trace_mmcm_top
// ==============
// Mid-speed parallel-trace capture using MMCM 90-deg phase-shift sampling
// (proposal 22 §7.1). Standalone top to test the technique on real STM32 ETM
// at TRACECLK ~21MHz (HCLK/2 @ 42MHz) without disturbing the verified
// OVERSAMPLE trace_stream_top.
//
//   STM32 ETM 4-bit (TRACECLK 21M) -> trace_capture_mmcm (IDDR on 90-deg clk)
//        -> {trace_b,trace_a} byte per TRACECLK period (clk90 domain)
//        -> one-shot capture BRAM -> UDP :5001 paged readout (same protocol as
//           swo_stream_top, so scripts/trace_dump.py reads it unchanged)
//   Re-arm via UDP :5002 (CSR 0x02).
//
// Decode offline: same {b,a} byte = TPIU stream bytes -> etm35lib (as the
// LA-verified §14 path). TRACE_WIDTH selects traceIF width; here we capture
// RAW {b,a} bytes and deframe on the PC (CAP_RAW-equivalent).

`default_nettype none

module trace_mmcm_top #(
    parameter DEPTH = 65536,         // captured bytes (one bank)
    parameter MULT  = 40,            // MMCM mult: VCO = TRACECLK*MULT (600-1200M)
    parameter DIVID = 40,            // CLKOUT divide: VCO/DIVID = TRACECLK
    parameter CLKIN_PERIOD = 47.6,   // ns, real TRACECLK period
    parameter PHASE = 90.0,          // CLKOUT1 sample-clock phase (deg)
    parameter WIDTH = 4
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
    output wire        led1           // capture full
);
    wire rst = ~rst_n;

    // ---- system clocks (sys 50M -> 125/125@90/100) ----
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

    // ---- CSR :5002 soft re-arm (clk125) ----
    wire [7:0] csr_addr_w, csr_data_w;
    wire       csr_we_w;
    reg        rearm_125 = 1'b0;
    always @(posedge clk125) begin
        rearm_125 <= 1'b0;
        if (csr_we_w && csr_addr_w == 8'h02) rearm_125 <= 1'b1;
    end

    // ---- MMCM 90-deg phase-shift capture front-end ----
    wire        cap_clk;               // = trace_clk recovered (0-deg)
    wire        clk90;                 // 90-deg sample clock = capture domain
    wire        clk90_locked;
    wire [3:0]  trace_a, trace_b;
    wire [7:0]  cap_byte;
    wire        cap_valid;
    trace_capture_mmcm #(.MULT(MULT), .DIVID(DIVID), .CLKIN_PERIOD(CLKIN_PERIOD), .PHASE(PHASE), .WIDTH(WIDTH)) u_cap (
        .rst(sys_rst),
        .trace_clk_p(trace_clk_in), .trace_data_p(trace_data_in),
        .trace_clk(cap_clk), .clk90_out(clk90),
        .trace_a(trace_a), .trace_b(trace_b),
        .mmcm_locked(clk90_locked),
        .cap_byte(cap_byte), .cap_valid(cap_valid)
    );
    // cap_byte/cap_valid are registered in the clk90 domain inside the
    // front-end, so the capture BRAM is written on clk90 (no async CDC).

    // re-arm into the clk90 capture domain (toggle + edge detect)
    reg rearm_tgl = 1'b0;
    always @(posedge clk125) if (rearm_125) rearm_tgl <= ~rearm_tgl;
    reg [2:0] rearm_sync = 0;
    always @(posedge clk90) rearm_sync <= {rearm_sync[1:0], rearm_tgl};
    wire cap_rearm = rearm_sync[2] ^ rearm_sync[1];

    // ---- one-shot capture BRAM (write on clk90) ----
    localparam RAW_AW = $clog2(DEPTH);
    (* ram_style = "block" *)
    reg [7:0] rawmem [0:DEPTH-1];
    reg [RAW_AW:0] rwr;
    wire rfull = rwr[RAW_AW];
    always @(posedge clk90) begin
        if (cap_valid && !rfull) rawmem[rwr[RAW_AW-1:0]] <= cap_byte;
    end
    always @(posedge clk90) begin
        if (sys_rst || cap_rearm)     rwr <= 0;
        else if (cap_valid && !rfull) rwr <= rwr + 1'b1;
    end
    reg [7:0] cap_gen = 8'd0;
    always @(posedge clk90) if (cap_rearm) cap_gen <= cap_gen + 1'b1;
    reg [7:0] cgen_s0 = 0, cgen_125 = 0;
    always @(posedge clk125) begin cgen_s0 <= cap_gen; cgen_125 <= cgen_s0; end

    // ---- UDP readout (clk125), same paged protocol as swo_stream_top ----
    wire [15:0] ext_addr;
    wire [7:0]  ext_data;
    reg  [7:0]  rrd;
    always @(posedge clk125) rrd <= rawmem[ext_addr[RAW_AW-1:0]];
    localparam [31:0] NB = DEPTH;
    wire status_sel = (ext_addr >= 16'hFF00);
    wire [7:0] status_byte =
        (ext_addr == 16'hFF00) ? NB[7:0] :
        (ext_addr == 16'hFF01) ? NB[15:8] :
        (ext_addr == 16'hFF02) ? NB[23:16] :
        (ext_addr == 16'hFF03) ? NB[31:24] :
        (ext_addr == 16'hFF04) ? {6'b0, clk90_locked, rfull} :
        (ext_addr == 16'hFF05) ? cgen_125 : 8'h00;
    assign ext_data = status_sel ? status_byte : rrd;

    assign led0 = ~clk90_locked;
    assign led1 = ~rfull;

    fpga_core_net #(.TARGET("XILINX")) u_eth (
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
        .stream_tdata(8'h0), .stream_tvalid(1'b0), .stream_tready()
    );

    assign phy_mdio = 1'bz;
    assign phy_mdc  = 1'b0;

endmodule

`default_nettype wire
