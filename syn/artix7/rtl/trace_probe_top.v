// trace_probe_top
// =================
// Minimal Stage-2 T4 integration top for the Artix-7 trace probe.
// Brings together all three OOC-validated blocks into a single design with
// real board pins and real clock constraints, so we can get post-implement
// utilization and timing slack — the authoritative "fits on 35T?" answer.
//
// Datapath (intentionally minimal; full plumbing is Stage-3 on-board PoC):
//
//   board pins ──► trace_capture_a7 ──► traceIF ──► tpiu_demux
//                  (T2 skeleton)        (T3)        (T3)
//                                                       │
//                                                       ▼
//                                                checksum_appender
//                                                       │
//                                                       ▼
//                                                cobs_encoder
//                                                       │
//                                                       ▼
//                                                super_framer
//                                                       │
//                                                       ▼ (8b stream sink)
//                                                  network out
//
// The gigabit Ethernet stack (verilog-ethernet's NexysVideo fpga_core, T1)
// is instantiated in parallel; its UDP RX/TX is left "tied off" with simple
// pass-through so the synthesis is real (not optimized away to nothing) but
// the actual UDP-to-trace bridging is left for Stage-3.
//
// Clocks:
//   sys_clk_50  : 50 MHz from board crystal (CLK_50M @J19 on A7-Lite)
//   clk125      : RGMII gigabit clock, derived from MMCM
//   clk200      : IDELAYCTRL reference, derived from MMCM
//   trace_clk   : recovered from TRACECLK (via trace_capture_a7)

`default_nettype none

module trace_probe_top (
    // Board oscillator + reset
    input  wire        sys_clk_50,
    input  wire        rst_n,

    // ARM trace pins (via GPIO1 / Bank 16, see PLAN_STAGE2 §T5)
    input  wire        trace_clk_in,    // GPIO1_4P / D17 (MRCC)
    input  wire [3:0]  trace_data_in,   // 4 lanes from GPIO1 Bank 16

    // RGMII gigabit Ethernet (RTL8211, on-board)
    input  wire        phy_rx_clk,
    input  wire [3:0]  phy_rxd,
    input  wire        phy_rx_ctl,
    output wire        phy_tx_clk,
    output wire [3:0]  phy_txd,
    output wire        phy_tx_ctl,
    output wire        phy_reset_n,
    inout  wire        phy_mdio,
    output wire        phy_mdc,

    // LEDs (sanity)
    output wire        led0,
    output wire        led1,

    // Trace pipeline observability bus (Stage-2 sizing only).
    // r09 A1: without these output ports Vivado's opt_design propagates
    // dead-code through the entire trace post-pipeline because their final
    // sink (fpga_core.sw) has no observable effect. Exposing the SF byte
    // stream + intermediate valid signals to a real top-level output
    // forces the synthesiser to keep the modules in the routed netlist,
    // giving truthful T4 utilization. Stage-3 will replace these probe
    // pins with the real UDP-trace bridge into udp_complete's s_udp_*.
    output wire [7:0]  trace_dbg_data,    // sf_data
    output wire        trace_dbg_valid,   // sf_out_valid
    output wire        trace_dbg_last,    // sf_out_last
    output wire [3:0]  trace_dbg_inter,   // {dmux,chk,cobs,fr_pulse} valids
    output wire        trace_dbg_lost     // r10 NEW-1: FIFO overflow seen (OR of lost counter)
);

    wire rst = ~rst_n;

    // ------------------------------------------------------------------
    // MMCM: 50MHz -> { 125MHz (RGMII clk), 125MHz @90° (RGMII clk90),
    //                  200MHz (IDELAYCTRL), 100MHz (sys) }
    // The 90° offset clk125 is required by ssio_ddr_out for the RGMII TX
    // clock to be source-synchronous-correct (data clocked on clk, clock
    // pin driven by clk90 so the centre-aligned eye lands at the PHY).
    // ------------------------------------------------------------------
    wire clkfb;
    wire clk125_unbuf, clk125_90_unbuf, clk200_unbuf, clk100_unbuf;
    wire mmcm_locked;

    MMCME2_BASE #(
        .CLKIN1_PERIOD(20.0),     // 50MHz -> 20ns
        .CLKFBOUT_MULT_F(20.0),   // VCO = 1000MHz
        .DIVCLK_DIVIDE(1),
        .CLKOUT0_DIVIDE_F(8.0),   // 125MHz, 0°
        .CLKOUT1_DIVIDE(8),       // 125MHz, 90° (RGMII TX)
        .CLKOUT1_PHASE(90.0),
        .CLKOUT2_DIVIDE(5),       // 200MHz (IDELAYCTRL)
        .CLKOUT3_DIVIDE(10),      // 100MHz sys
        .CLKOUT0_PHASE(0.0),
        .CLKOUT2_PHASE(0.0),
        .CLKOUT3_PHASE(0.0)
    ) u_mmcm (
        .CLKIN1   (sys_clk_50),
        .CLKFBIN  (clkfb),
        .CLKFBOUT (clkfb),
        .CLKOUT0  (clk125_unbuf),
        .CLKOUT1  (clk125_90_unbuf),
        .CLKOUT2  (clk200_unbuf),
        .CLKOUT3  (clk100_unbuf),
        .LOCKED   (mmcm_locked),
        .RST      (rst),
        .PWRDWN   (1'b0)
    );

    wire clk125, clk125_90, clk200, clk100;
    BUFG u_bg125   (.I(clk125_unbuf),    .O(clk125));
    BUFG u_bg125_90(.I(clk125_90_unbuf), .O(clk125_90));
    BUFG u_bg200   (.I(clk200_unbuf),    .O(clk200));
    BUFG u_bg100   (.I(clk100_unbuf),    .O(clk100));

    // Reset stretching: hold rst high until MMCM locks.
    reg [3:0] rst_sync;
    always @(posedge clk100 or posedge rst)
        if (rst) rst_sync <= 4'hf;
        else     rst_sync <= {rst_sync[2:0], ~mmcm_locked};
    wire sys_rst = rst_sync[3];

    // ------------------------------------------------------------------
    // T2: trace capture front-end (IDDR + IDELAYE2 + IDELAYCTRL)
    //
    // r09 A1 fix: DONT_TOUCH protects the entire trace pipeline from
    // being pruned during opt_design when the downstream UDP-trace
    // bridge doesn't yet exist. Without this Vivado infers the trace
    // inputs as unconstrained-equivalent-constant and dead-code
    // propagates through the entire pipeline, yielding a misleadingly
    // small utilization. Stage-3 replaces these attributes with a real
    // data sink into udp_complete.s_udp_payload_axis_t* + AsyncFIFO.
    // ------------------------------------------------------------------
    wire        trace_clk;
    wire [3:0]  trace_a, trace_b;
    wire        idelayctrl_rdy;

    (* DONT_TOUCH = "true" *)
    trace_capture_a7 u_capture (
        .rst           (sys_rst),
        .ref_200m      (clk200),
        .trace_clk_p   (trace_clk_in),
        .trace_data_p  (trace_data_in),
        .tap_data0     (5'd16),
        .tap_data1     (5'd16),
        .tap_data2     (5'd16),
        .tap_data3     (5'd16),
        .tap_load      (1'b0),
        .trace_clk     (trace_clk),
        .trace_a       (trace_a),
        .trace_b       (trace_b),
        .idelayctrl_rdy(idelayctrl_rdy)
    );

    // ------------------------------------------------------------------
    // T3 - traceIF: combine rising/falling nibble samples into TPIU frames
    // ------------------------------------------------------------------
    wire        fr_avail;
    wire [127:0] frame128;
    wire         tif_rst = sys_rst | ~idelayctrl_rdy;

    (* DONT_TOUCH = "true" *)
    traceIF #(.MAXBUSWIDTH(4)) u_traceif (
        .rst        (tif_rst),
        .traceDina  (trace_a),
        .traceDinb  (trace_b),
        .traceClkin (trace_clk),
        .width      (2'b11),         // 4-bit
        .edgeOutput (),
        .FrAvail    (fr_avail),
        .Frame      (frame128)
    );

    // ------------------------------------------------------------------
    // Cross from trace_clk domain to clk100 (sys) using a real AsyncFIFO
    // (r09 P0-2 fix). The previous 2-FF synchroniser + frame_lat handshake
    // was a textbook CDC bug: a single-bit toggle synchroniser cannot
    // protect the 128-bit frame128 payload, since the 128 wires propagate
    // with independent skew across the trace_clk -> clk100 boundary.
    // xsim missed this because all wires arrive in the same simulator
    // picosecond; on real hardware Vivado would not have flagged it
    // either, because set_clock_groups -asynchronous explicitly suppresses
    // CDC checks on these paths. Using verilog-ethernet's axis_async_fifo
    // fixes this with a Gray-coded pointer crossing + true single-port
    // BRAM, the same primitive the rest of the gigabit Ethernet stack
    // already trusts. Depth 16 frames * 16 bytes = 256 byte buffer,
    // sized to absorb a few frames of 100 MHz trace_clk to 100 MHz sys
    // schedule slip without dropping.
    // ------------------------------------------------------------------
    wire        cdc_in_valid = 1'b1;       // traceIF emits a frame every
                                           // few trace_clk cycles; we let
                                           // the FIFO pace itself via
                                           // s_tready/back-pressure when
                                           // frame128 is replicated.
    wire        cdc_in_ready;
    wire        cdc_out_valid;
    wire        cdc_out_ready = 1'b1;      // dmux always ready in skeleton
    wire [127:0] cdc_out_frame;

    // We need a one-shot trigger when frame128 changes (FrAvail toggles in
    // trace_clk domain). Detect rising edge of fr_avail in trace_clk and
    // pulse axis_tvalid for one trace_clk cycle.
    //
    // Reset is intentionally not propagated into this register (no async
    // reset and no synchronous reset on the toggle detector itself): the
    // BRAM-backed AsyncFIFO write-enable would otherwise be driven by a
    // register with an asynchronous reset, triggering Vivado DRC
    // REQP-1839 (potential RAMB content corruption on reset assertion).
    // The FIFO consumes its own m_rst/s_rst paths; this stage only needs
    // to debounce the toggle.
    //
    // fr_avail comes from traceIF.FrAvail, which HAS an async reset. Feed
    // it through one reset-less isolation flop first so the toggle XOR
    // (and hence the FIFO write-enable) is no longer combinationally tied
    // to an async-reset register — this clears the residual REQP-1839 on
    // u_traceif/FrAvail_reg.
    reg fr_avail_iso, fr_avail_q;
    always @(posedge trace_clk) begin
        fr_avail_iso <= fr_avail;        // reset-less isolation
        fr_avail_q   <= fr_avail_iso;
    end
    wire frame_strobe = fr_avail_iso ^ fr_avail_q;   // toggle detect

    // ------------------------------------------------------------------
    // r10 NEW-1 fix: overflow accounting. traceIF is free-running and
    // cannot be back-pressured (it samples on every trace_clk edge), so a
    // single-cycle frame_strobe that lands while the FIFO is full would
    // silently drop a frame. Rather than pretend back-pressure exists, we
    // make the loss VISIBLE: count every frame_strobe that is not accepted
    // (tvalid & !tready), the same approach orbtrace upstream uses with
    // util.Monitor.lost. The PC-side decoder can then attribute a
    // resync to a known FIFO overflow instead of misdiagnosing it as a
    // sampling / signal-integrity fault. (Real fix in Stage-3: deeper
    // FIFO + DDR3 spill; for Stage-2 sizing the counter quantifies the
    // problem.)
    wire fifo_overflow_evt = frame_strobe & ~cdc_in_ready;
    reg [15:0] trace_lost_cnt;
    always @(posedge trace_clk)
        if (sys_rst)               trace_lost_cnt <= 16'd0;
        else if (fifo_overflow_evt) trace_lost_cnt <= trace_lost_cnt + 16'd1;

    axis_async_fifo #(
        .DEPTH       (16),
        .DATA_WIDTH  (128),
        .KEEP_ENABLE (0),
        .LAST_ENABLE (0),
        .USER_ENABLE (0),
        .FRAME_FIFO  (0)
    ) u_frame_cdc (
        // s side: trace_clk
        .s_clk           (trace_clk),
        .s_rst           (sys_rst),
        .s_axis_tdata    (frame128),
        .s_axis_tkeep    (16'h0),
        .s_axis_tvalid   (frame_strobe),
        .s_axis_tready   (cdc_in_ready),
        .s_axis_tlast    (1'b0),
        .s_axis_tid      (8'h0),
        .s_axis_tdest    (8'h0),
        .s_axis_tuser    (1'b0),
        // m side: clk100
        .m_clk           (clk100),
        .m_rst           (sys_rst),
        .m_axis_tdata    (cdc_out_frame),
        .m_axis_tkeep    (),
        .m_axis_tvalid   (cdc_out_valid),
        .m_axis_tready   (cdc_out_ready),
        .m_axis_tlast    (),
        .m_axis_tid      (),
        .m_axis_tdest    (),
        .m_axis_tuser    (),
        // unused ctrl
        .s_pause_req     (1'b0),
        .s_pause_ack     (),
        .m_pause_req     (1'b0),
        .m_pause_ack     (),
        .s_status_depth  (),
        .s_status_depth_commit (),
        .s_status_overflow     (),
        .s_status_bad_frame    (),
        .s_status_good_frame   (),
        .m_status_depth        (),
        .m_status_depth_commit (),
        .m_status_overflow     (),
        .m_status_bad_frame    (),
        .m_status_good_frame   ()
    );

    wire        fr_pulse = cdc_out_valid;       // 1 sys-clk pulse per frame
    wire [127:0] frame_lat = cdc_out_frame;     // synchronous to clk100

    // ------------------------------------------------------------------
    // T3 - TPIU demux + checksum + COBS + super-framer (clk100 domain)
    // ------------------------------------------------------------------
    wire dmux_in_ready;
    wire dmux_out_valid; wire dmux_out_data_8 = 1'b0; // unused vars retained for synthesis
    wire dmux_out_data_b; wire dmux_out_last;
    wire [7:0] dmux_data;

    // For sizing: drive in_valid from fr_pulse; in_frame from frame_lat.
    // (Production handshaking is more careful; sizing isn't sensitive.)
    (* DONT_TOUCH = "true" *)
    tpiu_demux u_dmux (
        .clk        (clk100),
        .rst        (sys_rst),
        .in_valid   (fr_pulse),
        .in_ready   (dmux_in_ready),
        .in_frame   (frame_lat),
        .bp_valid   (1'b0),
        .bp_ready   (),
        .bp_data    (8'd0),
        .bypass_sel (1'b0),
        .out_valid  (dmux_out_valid),
        .out_ready  (1'b1),
        .out_data   (dmux_data),
        .out_last   (dmux_out_last)
    );

    wire chk_out_valid; wire [7:0] chk_data; wire chk_out_last;
    (* DONT_TOUCH = "true" *)
    checksum_appender u_chk (
        .clk        (clk100),
        .rst        (sys_rst),
        .in_valid   (dmux_out_valid),
        .in_ready   (),
        .in_data    (dmux_data),
        .in_last    (dmux_out_last),
        .out_valid  (chk_out_valid),
        .out_ready  (1'b1),
        .out_data   (chk_data),
        .out_last   (chk_out_last)
    );

    wire cobs_out_valid; wire [7:0] cobs_data; wire cobs_out_last;
    (* DONT_TOUCH = "true" *)
    cobs_encoder u_cobs (
        .clk        (clk100),
        .rst        (sys_rst),
        .in_valid   (chk_out_valid),
        .in_ready   (),
        .in_data    (chk_data),
        .in_last    (chk_out_last),
        .out_valid  (cobs_out_valid),
        .out_ready  (1'b1),
        .out_data   (cobs_data),
        .out_last   (cobs_out_last)
    );

    wire sf_out_valid; wire [7:0] sf_data; wire sf_out_last;
    (* DONT_TOUCH = "true" *)
    super_framer u_sf (
        .clk        (clk100),
        .rst        (sys_rst),
        .in_valid   (cobs_out_valid),
        .in_ready   (),
        .in_data    (cobs_data),
        .in_last    (cobs_out_last),
        .out_valid  (sf_out_valid),
        .out_ready  (1'b1),
        .out_data   (sf_data),
        .out_last   (sf_out_last)
    );

    // ------------------------------------------------------------------
    // T1: gigabit Ethernet stack (verilog-ethernet NexysVideo fpga_core).
    // For T4 sizing we instantiate fpga_core with the SF byte stream gated
    // into the sw input so the synthesizer cannot prune it. Real UDP-trace
    // bridging is Stage-3 work.
    //
    // TARGET="XILINX" is required: oddr.v / iddr.v default to a "GENERIC"
    // behavioural model that uses two always blocks driving the same reg,
    // which Vivado flags as a multiple-driver DRC. Setting TARGET="XILINX"
    // selects the proper ODDR/IDDR primitive instantiation.
    // ------------------------------------------------------------------
    fpga_core #(
        .TARGET("XILINX")
    ) u_eth (
        .clk         (clk125),
        .clk90       (clk125_90),
        .rst         (sys_rst),
        .btnu(1'b0), .btnl(1'b0), .btnd(1'b0), .btnr(1'b0), .btnc(1'b0),
        .sw          ({3'b0, sf_out_valid, sf_data[3:0]}),
        .led         (),
        .phy_rx_clk  (phy_rx_clk),
        .phy_rxd     (phy_rxd),
        .phy_rx_ctl  (phy_rx_ctl),
        .phy_tx_clk  (phy_tx_clk),
        .phy_txd     (phy_txd),
        .phy_tx_ctl  (phy_tx_ctl),
        .phy_reset_n (phy_reset_n),
        .phy_int_n   (1'b1),
        .phy_pme_n   (1'b1),
        .uart_rxd    (1'b1),
        .uart_txd    ()
    );

    // ------------------------------------------------------------------
    // PHY management (MDIO) master interface — r10 NEW-2.
    // r09/r10 P0-1: if the RTL8211E strap pins default to RGMII RX/TX
    // internal delay enabled, the only software remedy is to reconfigure
    // the PHY's RGMII delay register (page 0xa43, reg 0x0d) over MDIO at
    // boot. The previous version drove phy_mdio = 1'bz / phy_mdc = 1'b0,
    // i.e. no MDIO master at all — which meant that even if the vendor
    // confirmed "strap is bad but you can fix it via MDIO", this design
    // physically could not. We now expose a proper tri-stated MDIO master
    // interface so a boot-time register-write sequence can be dropped in.
    //
    // The actual register-write FSM is a Stage-3 deliverable (it needs the
    // confirmed strap value to know WHAT to write); here we provide the
    // tri-state plumbing + a parameter-gated idle so the pins are driven
    // correctly and the interface exists. mdio_oe=0 => high-Z (PHY drives
    // / bus idle), matching MDIO open-drain-ish convention.
    // ------------------------------------------------------------------
    wire mdio_mst_o;     // master output data (to be driven by Stage-3 FSM)
    wire mdio_mst_oe;    // master output enable (1 = drive, 0 = release)
    wire mdio_mst_i;     // master input data (read from PHY)
    wire mdio_mst_clk;   // MDC from master

    // Stage-2 stub: bus idle, master FSM not yet implemented. Stage-3
    // replaces these two assigns with the register-write sequencer.
    assign mdio_mst_o   = 1'b0;
    assign mdio_mst_oe  = 1'b0;   // released (high-Z) until Stage-3 FSM
    assign mdio_mst_clk = 1'b0;

    assign phy_mdio   = mdio_mst_oe ? mdio_mst_o : 1'bz;  // real tri-state
    assign mdio_mst_i = phy_mdio;                          // readback path
    assign phy_mdc    = mdio_mst_clk;

    assign led0 = idelayctrl_rdy;
    assign led1 = sf_out_valid;

    // r09 A1 fix: expose trace pipeline outputs as real top-level ports so
    // opt_design cannot prune them. Stage-3 replaces this with a proper
    // UDP-trace bridge into u_eth's s_udp_payload_axis_t* inputs.
    assign trace_dbg_data  = sf_data;
    assign trace_dbg_valid = sf_out_valid;
    assign trace_dbg_last  = sf_out_last;
    assign trace_dbg_inter = {dmux_out_valid, chk_out_valid, cobs_out_valid, fr_pulse};
    assign trace_dbg_lost  = |trace_lost_cnt;   // r10 NEW-1: any FIFO overflow ever seen

endmodule

`default_nettype wire
