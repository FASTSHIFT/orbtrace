// swo_stream_top
// ==============
// MINIMAL on-board verification of the SWO single-wire trace front-end
// (提案 15). Captures the SWO byte stream (decoded in-fabric by
// swo_pulse_capture -> swo_nrz_decode -> swo_uart_decode) into a one-shot BRAM
// and serves it over UDP :5001 with the SAME paged readout protocol as
// trace_stream_top's CAP_RAW path, so the existing scripts/trace_dump.py reads
// it unchanged. No IDELAY, no traceIF, no timebase — just: SWO pin -> bytes ->
// BRAM -> UDP. Decode offline with decode/swo_csv_decode.py-equivalent
// (etm35lib TPIU+ETM3.5).
//
//   STM32 PB3 (SWO NRZ 2 MHz) --1 wire--> swo_in (B22 / GPIO1_21N)
//        -> oversample @ ref_200m -> UART bytes -> capture BRAM (DEPTH)
//        -> UDP :5001 paged readout (16-bit base addr) -> PC file
//
// Re-arm via UDP :5002 (CSR 0x02), identical to the parallel top.

`default_nettype none

module swo_stream_top #(
    parameter DEPTH  = 61440,        // captured bytes (< 65536 for 16-bit addr)
    parameter BITLEN = 16'd100       // ref_200m cycles/UART bit (200MHz/2Mbaud)
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

    input  wire        swo_in,       // SWO single wire from STM32 PB3

    output wire        led0,         // heartbeat-ish (mmcm locked)
    output wire        led1          // capture full (steady) / filling (off)
);

    wire rst = ~rst_n;

    // ---- clocks: reuse the parallel top's MMCM recipe -------------------
    wire clkfb, clk125_u, clk125_90_u, clk200_u, clk100_u, mmcm_locked;
    MMCME2_BASE #(
        .CLKIN1_PERIOD(20.0), .CLKFBOUT_MULT_F(20.0), .DIVCLK_DIVIDE(1),
        .CLKOUT0_DIVIDE_F(8.0),
        .CLKOUT1_DIVIDE(8), .CLKOUT1_PHASE(90.0),
        .CLKOUT2_DIVIDE(5), .CLKOUT3_DIVIDE(10),
        .CLKOUT0_PHASE(0.0), .CLKOUT2_PHASE(0.0), .CLKOUT3_PHASE(0.0)
    ) u_mmcm (
        .CLKIN1(sys_clk_50), .CLKFBIN(clkfb), .CLKFBOUT(clkfb),
        .CLKOUT0(clk125_u), .CLKOUT1(clk125_90_u),
        .CLKOUT2(clk200_u), .CLKOUT3(clk100_u),
        .LOCKED(mmcm_locked), .RST(rst), .PWRDWN(1'b0)
    );
    wire clk125, clk125_90, clk200, clk100;
    BUFG b0(.I(clk125_u), .O(clk125));
    BUFG b1(.I(clk125_90_u), .O(clk125_90));
    BUFG b2(.I(clk200_u), .O(clk200));
    BUFG b3(.I(clk100_u), .O(clk100));

    reg [3:0] rst_sync = 4'hf;
    always @(posedge clk100 or posedge rst)
        if (rst) rst_sync <= 4'hf;
        else     rst_sync <= {rst_sync[2:0], ~mmcm_locked};
    wire sys_rst = rst_sync[3];

    // ---- CSR :5002 soft re-arm (same as parallel top) -------------------
    wire [7:0] csr_addr_w, csr_data_w;
    wire       csr_we_w;
    reg        rearm_125 = 1'b0;
    always @(posedge clk125) begin
        rearm_125 <= 1'b0;
        if (sys_rst) ;
        else if (csr_we_w && csr_addr_w == 8'h02) rearm_125 <= 1'b1;
    end
    reg        rearm_tgl125 = 1'b0;
    always @(posedge clk125) if (rearm_125) rearm_tgl125 <= ~rearm_tgl125;
    reg [2:0]  rearm_sync200 = 3'b0;
    always @(posedge clk200) rearm_sync200 <= {rearm_sync200[1:0], rearm_tgl125};
    wire cap_rearm = rearm_sync200[2] ^ rearm_sync200[1];

    // ---- SWO front-end: pin -> bytes (all in clk200) --------------------
    wire        p_valid, p_level;
    wire [15:0] p_count;
    swo_pulse_capture #(.CW(16), .IDLE_FLUSH(16'd4000)) u_cap (
        .clk(clk200), .rst(sys_rst), .swo_in(swo_in),
        .pulse_valid(p_valid), .pulse_level(p_level), .pulse_count(p_count)
    );
    wire        bvld, bval;
    swo_nrz_decode #(.CW(16)) u_nrz (
        .clk(clk200), .rst(sys_rst),
        .pulse_valid(p_valid), .pulse_level(p_level), .pulse_count(p_count),
        .bit_valid(bvld), .bit_value(bval), .bitlen(BITLEN)
    );
    wire [7:0]  cap_byte;
    wire        cap_valid;
    swo_uart_decode u_uart (
        .clk(clk200), .rst(sys_rst),
        .bit_valid(bvld), .bit_value(bval),
        .byte_valid(cap_valid), .byte_data(cap_byte)
    );

    // ---- capture BRAM + paged readout (mirrors CAP_RAW path) ------------
    wire [15:0] ext_addr;
    wire [7:0]  ext_data;
    localparam [15:0] NB = DEPTH;
    localparam RAW_AW = $clog2(DEPTH);

    (* ram_style = "block" *)
    reg [7:0] rawmem [0:DEPTH-1];
    reg [RAW_AW:0] rwr;
    wire rfull = rwr[RAW_AW];
    always @(posedge clk200) begin
        if (cap_valid && !rfull) rawmem[rwr[RAW_AW-1:0]] <= cap_byte;
    end
    always @(posedge clk200) begin
        if (sys_rst || cap_rearm)     rwr <= 0;
        else if (cap_valid && !rfull) rwr <= rwr + 1'b1;
    end

    reg [7:0] cap_gen200 = 8'd0;
    always @(posedge clk200) if (cap_rearm) cap_gen200 <= cap_gen200 + 1'b1;
    reg [7:0] cap_gen_s0 = 0, cap_gen_125 = 0;
    always @(posedge clk125) begin
        cap_gen_s0  <= cap_gen200;
        cap_gen_125 <= cap_gen_s0;
    end

    reg [7:0] rrd;
    always @(posedge clk125) rrd <= rawmem[ext_addr[RAW_AW-1:0]];
    assign ext_data = (ext_addr < NB)    ? rrd :
                      (ext_addr == NB+0) ? NB[7:0] :
                      (ext_addr == NB+1) ? NB[15:8] :
                      (ext_addr == NB+2) ? {7'b0, rfull} :
                      (ext_addr == NB+3) ? cap_gen_125 : 8'h00;
    assign led1 = ~rfull;

    // ---- Ethernet UDP readout (same core as the parallel top) -----------
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
        .csr_addr(csr_addr_w), .csr_data(csr_data_w), .csr_we(csr_we_w)
    );

    assign phy_mdio = 1'bz;
    assign phy_mdc  = 1'b0;
    assign led0     = ~mmcm_locked;

endmodule

`default_nettype wire
