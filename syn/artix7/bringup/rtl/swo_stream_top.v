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
    parameter DEPTH  = 98304,        // captured bytes (96 KB, ~22 RAMB36; fits
                                     // 35T's 30 with the eth core). Read in 64K
                                     // banks via the bank CSR (0x05) since the
                                     // readout address is 16-bit. Larger DEPTH =
                                     // longer capture time window so a (time-
                                     // periodic) TPIU sync always lands even at
                                     // high baud.
    parameter BITLEN  = 16'd100,     // sample-ticks/UART bit (default 2 Mbaud)
    parameter SWO_MODE = 0,          // 0: single-edge oversample @clk200 (200MSa/s)
                                     // 1: IDDR double-edge (400 or 500 MSa/s)
                                     //    2x sample rate, toward ORBTrace 500MSa/s
                                     //    (proposal 17). bitlen is then in
                                     //    sample-tick units.
    parameter CAP500 = 0,            // IDDR sample clock: 0=clk200(400MSa/s,
                                     // timing-clean), 1=clk250(500MSa/s)
    parameter TIMEBASE = 1           // 1: snapshot a free-running cap_clk counter
                                     // into a table every TS_STRIDE captured bytes
                                     // so the PC can put a real wall-clock on each
                                     // byte (doc 15 §24.2 / proposal 18 §9.3). The
                                     // F429 ETM has NO usable time (TRM: ts count
                                     // is an unconnected SoC input), so the FPGA
                                     // is the authoritative time source.
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

    // ---- clocks: MMCM (VCO=1000MHz). clk250 added for the IDDR 500MSa/s
    // sample clock (proposal 17 §4: 250MHz IDDR double-edge = 500 MSa/s, the
    // ORBTrace-matching rate). IDELAYCTRL is unused here (oversample SWO needs
    // no eye-centering), so clk250 is free to drive the IDDR C pin.
    wire clkfb, clk125_u, clk125_90_u, clk200_u, clk100_u, clk250_u, mmcm_locked;
    MMCME2_BASE #(
        .CLKIN1_PERIOD(20.0), .CLKFBOUT_MULT_F(20.0), .DIVCLK_DIVIDE(1),
        .CLKOUT0_DIVIDE_F(8.0),
        .CLKOUT1_DIVIDE(8), .CLKOUT1_PHASE(90.0),
        .CLKOUT2_DIVIDE(5), .CLKOUT3_DIVIDE(10),
        .CLKOUT4_DIVIDE(4),                       // 1000/4 = 250 MHz
        .CLKOUT0_PHASE(0.0), .CLKOUT2_PHASE(0.0), .CLKOUT3_PHASE(0.0),
        .CLKOUT4_PHASE(0.0)
    ) u_mmcm (
        .CLKIN1(sys_clk_50), .CLKFBIN(clkfb), .CLKFBOUT(clkfb),
        .CLKOUT0(clk125_u), .CLKOUT1(clk125_90_u),
        .CLKOUT2(clk200_u), .CLKOUT3(clk100_u), .CLKOUT4(clk250_u),
        .LOCKED(mmcm_locked), .RST(rst), .PWRDWN(1'b0)
    );
    wire clk125, clk125_90, clk200, clk100, clk250;
    BUFG b0(.I(clk125_u), .O(clk125));
    BUFG b1(.I(clk125_90_u), .O(clk125_90));
    BUFG b2(.I(clk200_u), .O(clk200));
    BUFG b3(.I(clk100_u), .O(clk100));
    BUFG b4(.I(clk250_u), .O(clk250));

    // capture-domain clock. SWO_MODE=1 (IDDR) can run on clk200 (400 MSa/s,
    // timing-clean) or clk250 (500 MSa/s, ORBTrace-matching but the nrz acc
    // feedback path is marginal at 250 MHz — WNS ~-0.2ns). CAP500 selects:
    //   CAP500=0 -> clk200 (400 MSa/s, default, closes timing)
    //   CAP500=1 -> clk250 (500 MSa/s)
    // Single-edge mode always uses clk200.
    wire cap_clk = (SWO_MODE == 1 && CAP500 == 1) ? clk250 : clk200;

    reg [3:0] rst_sync = 4'hf;
    always @(posedge clk100 or posedge rst)
        if (rst) rst_sync <= 4'hf;
        else     rst_sync <= {rst_sync[2:0], ~mmcm_locked};
    wire sys_rst = rst_sync[3];

    // ---- CSR :5002 soft re-arm (same as parallel top) -------------------
    wire [7:0] csr_addr_w, csr_data_w;
    wire       csr_we_w;
    reg        rearm_125 = 1'b0;
    // Runtime bitlen (ref_200m cycles/UART bit) so the baud can be raised
    // without re-synthesis (frequency sweep): CSR 0x03=low byte, 0x04=high byte.
    // 0 (default) => use the BITLEN parameter. Set it to match the STM32 TPIU
    // ACPR baud, then re-arm (CSR 0x02).
    reg [15:0] bitlen_csr = 16'd0;
    // Bank select (CSR 0x05): which 64 KB page of the capture buffer the 16-bit
    // readout address indexes into. clk125 domain (readout side).
    reg [7:0]  bank_csr = 8'd0;
    always @(posedge clk125) begin
        rearm_125 <= 1'b0;
        if (sys_rst) begin
            bitlen_csr <= 16'd0;
        end else if (csr_we_w) begin
            if (csr_addr_w == 8'h02) rearm_125 <= 1'b1;
            if (csr_addr_w == 8'h03) bitlen_csr[7:0]  <= csr_data_w;
            if (csr_addr_w == 8'h04) bitlen_csr[15:8] <= csr_data_w;
            if (csr_addr_w == 8'h05) bank_csr <= csr_data_w;
        end
    end
    // sync quasi-static bitlen into the capture domain
    reg [15:0] bitlen_s0 = 0, bitlen_200 = 0;
    always @(posedge cap_clk) begin
        bitlen_s0  <= bitlen_csr;
        bitlen_200 <= bitlen_s0;
    end
    wire [15:0] bitlen_use = (bitlen_200 != 16'd0) ? bitlen_200 : BITLEN;
    reg        rearm_tgl125 = 1'b0;
    always @(posedge clk125) if (rearm_125) rearm_tgl125 <= ~rearm_tgl125;
    reg [2:0]  rearm_sync200 = 3'b0;
    always @(posedge cap_clk) rearm_sync200 <= {rearm_sync200[1:0], rearm_tgl125};
    wire cap_rearm = rearm_sync200[2] ^ rearm_sync200[1];

    // ---- SWO front-end: pin -> bytes (all on cap_clk) -------------------
    // SWO_MODE=0: single-edge oversample @ clk200 (200 MSa/s).
    // SWO_MODE=1: IDDR double-edge @ clk250 (500 MSa/s) — 2 samples/cycle.
    wire        p_valid, p_level;
    wire [15:0] p_count;

    generate
    if (SWO_MODE == 1) begin : g_iddr
        // IDDR samples swo_in on BOTH edges of clk250 -> 2 oversamples/cycle
        // = 500 MSa/s (matches ORBTrace). SAME_EDGE_PIPELINED: Q1/Q2 presented
        // together one cycle after the sampling edges; Q1=rising, Q2=falling.
        wire swo_ibuf;
        IBUF u_swo_ibuf (.I(swo_in), .O(swo_ibuf));
        wire q1, q2;
        IDDR #(
            .DDR_CLK_EDGE("SAME_EDGE_PIPELINED"),
            .INIT_Q1(1'b1), .INIT_Q2(1'b1), .SRTYPE("ASYNC")
        ) u_swo_iddr (
            .Q1(q1), .Q2(q2), .C(cap_clk), .CE(1'b1),
            .D(swo_ibuf), .R(sys_rst), .S(1'b0)
        );
        swo_iddr_capture #(.CW(16), .IDLE_FLUSH(16'd8000)) u_cap (
            .sample_clk(cap_clk), .rst(sys_rst),
            .s_d1(q1), .s_d2(q2),
            .pulse_valid(p_valid), .pulse_level(p_level), .pulse_count(p_count)
        );
    end else begin : g_single
        swo_pulse_capture #(.CW(16), .IDLE_FLUSH(16'd4000)) u_cap (
            .clk(cap_clk), .rst(sys_rst), .swo_in(swo_in),
            .pulse_valid(p_valid), .pulse_level(p_level), .pulse_count(p_count)
        );
    end
    endgenerate

    wire        bvld, bval;
    swo_nrz_decode #(.CW(16)) u_nrz (
        .clk(cap_clk), .rst(sys_rst),
        .pulse_valid(p_valid), .pulse_level(p_level), .pulse_count(p_count),
        .bit_valid(bvld), .bit_value(bval), .bitlen(bitlen_use)
    );
    wire [7:0]  cap_byte;
    wire        cap_valid;
    swo_uart_decode u_uart (
        .clk(cap_clk), .rst(sys_rst),
        .bit_valid(bvld), .bit_value(bval),
        .byte_valid(cap_valid), .byte_data(cap_byte)
    );

    // ---- capture BRAM + paged readout (mirrors CAP_RAW path) ------------
    wire [15:0] ext_addr;
    wire [7:0]  ext_data;
    localparam RAW_AW = $clog2(DEPTH);

    (* ram_style = "block" *)
    reg [7:0] rawmem [0:DEPTH-1];
    reg [RAW_AW:0] rwr;
    wire rfull = rwr[RAW_AW];
    always @(posedge cap_clk) begin
        if (cap_valid && !rfull) rawmem[rwr[RAW_AW-1:0]] <= cap_byte;
    end
    always @(posedge cap_clk) begin
        if (sys_rst || cap_rearm)     rwr <= 0;
        else if (cap_valid && !rfull) rwr <= rwr + 1'b1;
    end

    reg [7:0] cap_gen200 = 8'd0;
    always @(posedge cap_clk) if (cap_rearm) cap_gen200 <= cap_gen200 + 1'b1;
    reg [7:0] cap_gen_s0 = 0, cap_gen_125 = 0;
    always @(posedge clk125) begin
        cap_gen_s0  <= cap_gen200;
        cap_gen_125 <= cap_gen_s0;
    end

    // Full read address = bank*65536 + ext_addr (banked paging past 16-bit).
    wire [RAW_AW-1:0] rd_addr = {bank_csr, ext_addr}[RAW_AW-1:0];
    reg [7:0] rrd;
    always @(posedge clk125) rrd <= rawmem[rd_addr];

    // ---- FPGA capture-time base (doc 15 §24.2 / proposal 18 §9.3) --------
    // The F429 ETM emits NO usable time (ETM-M4 TRM: the 48-bit timestamp count
    // is an unconnected SoC input on this part -> ts packets read 0; cycle-acc
    // is hardwired off). So WE timestamp on the capture side: a free-running
    // cap_clk counter snapshotted into a small table every TS_STRIDE captured
    // bytes. This is real wall-clock, INDEPENDENT of the SWO baud, so it adapts
    // to any frequency and records idle gaps as genuine time gaps. The PC maps
    // captured-byte-index -> ns by interpolating the table (fpga_timebase.py).
    //
    // tick_ns: cap_clk = clk200 (5 ns) for CAP500=0, clk250 (4 ns) for CAP500=1.
    localparam TS_STRIDE_LOG2 = 8;                    // snapshot every 256 bytes
    localparam TS_N  = (DEPTH >> TS_STRIDE_LOG2) + 1; // table entries
    localparam TS_IW = $clog2(TS_N);
    localparam [15:0] TS_N16 = TS_N[15:0];

    reg  [31:0] cap_clk_cnt = 32'd0;                  // free-run cap_clk ticks
    reg  [31:0] cap_clk_last = 32'd0;                 // tick at last byte (tail)
    (* ram_style = "distributed" *)
    reg  [31:0] tsmem [0:TS_N-1];
    wire [7:0]  ts_tick_ns = (CAP500 == 1) ? 8'd4 : 8'd5;

    generate
    if (TIMEBASE == 1) begin : g_timebase
        wire             ts_snap = cap_valid && !rfull &&
                                   (rwr[TS_STRIDE_LOG2-1:0] == 0);
        wire [TS_IW-1:0] ts_widx = rwr[RAW_AW-1:TS_STRIDE_LOG2];
        always @(posedge cap_clk) begin
            if (sys_rst || cap_rearm) cap_clk_cnt <= 32'd0;
            else                      cap_clk_cnt <= cap_clk_cnt + 1'b1;
        end
        always @(posedge cap_clk) if (ts_snap) tsmem[ts_widx] <= cap_clk_cnt;
        always @(posedge cap_clk)
            if (cap_valid && !rfull) cap_clk_last <= cap_clk_cnt;
    end
    endgenerate

    // sync the tail tick into clk125 for the metadata read
    reg [31:0] cclast_s0 = 0, cclast_125 = 0;
    always @(posedge clk125) begin
        cclast_s0  <= cap_clk_last;
        cclast_125 <= cclast_s0;
    end

    // Timebase readout: the snapshot table lives in a DEDICATED readout bank
    // (TS_BANK = 0xFE), 4 bytes/entry, little-endian; metadata sits in the
    // status region (bank 0, 0xFF06..). This keeps the banked DATA path (bank
    // 0/1) untouched. PC: select bank 0xFE, read TS_N*4 bytes.
    localparam [7:0] TS_BANK = 8'hFE;
    wire             ts_bank_sel = (bank_csr == TS_BANK);
    wire [TS_IW-1:0] ts_ridx = ext_addr[TS_IW+1:2];   // /4
    reg  [31:0]      tsrd;
    reg  [1:0]       ts_lane_d;
    always @(posedge clk125) begin
        tsrd      <= tsmem[ts_ridx];
        ts_lane_d <= ext_addr[1:0];
    end
    wire [7:0] ts_byte = tsrd[8*ts_lane_d +: 8];

    // Status bytes live in bank 0 at a fixed high offset (0xFF00..), away from
    // the data, so the PC reads DEPTH/full/gen without colliding with the 128 KB
    // data region. DEPTH is reported as a 32-bit value (it exceeds 16 bits).
    localparam [31:0] NB = DEPTH;
    wire status_sel = (bank_csr == 8'd0) && (ext_addr >= 16'hFF00);
    wire [7:0] status_byte =
                      (ext_addr == 16'hFF00) ? NB[7:0] :
                      (ext_addr == 16'hFF01) ? NB[15:8] :
                      (ext_addr == 16'hFF02) ? NB[23:16] :
                      (ext_addr == 16'hFF03) ? NB[31:24] :
                      (ext_addr == 16'hFF04) ? {7'b0, rfull} :
                      (ext_addr == 16'hFF05) ? cap_gen_125 :
                      // timebase metadata: stride_log2, entry count(16b),
                      // tick_ns, tail tick(32b), timebase-present flag.
                      (ext_addr == 16'hFF06) ? TS_STRIDE_LOG2[7:0] :
                      (ext_addr == 16'hFF07) ? TS_N16[7:0] :
                      (ext_addr == 16'hFF08) ? TS_N16[15:8] :
                      (ext_addr == 16'hFF09) ? ts_tick_ns :
                      (ext_addr == 16'hFF0A) ? cclast_125[7:0] :
                      (ext_addr == 16'hFF0B) ? cclast_125[15:8] :
                      (ext_addr == 16'hFF0C) ? cclast_125[23:16] :
                      (ext_addr == 16'hFF0D) ? cclast_125[31:24] :
                      (ext_addr == 16'hFF0E) ? {7'b0, TIMEBASE[0]} : 8'h00;
    assign ext_data = status_sel  ? status_byte :
                      ts_bank_sel ? ts_byte :
                                    rrd;
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
        .csr_addr(csr_addr_w), .csr_data(csr_data_w), .csr_we(csr_we_w),
        .stream_tdata(8'h0), .stream_tvalid(1'b0), .stream_tready()
    );

    assign phy_mdio = 1'bz;
    assign phy_mdc  = 1'b0;
    assign led0     = ~mmcm_locked;

endmodule

`default_nettype wire
