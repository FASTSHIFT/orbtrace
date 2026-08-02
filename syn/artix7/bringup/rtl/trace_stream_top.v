// trace_stream_top
// ================
// Stage-4 V3: fix the IDELAY tap (V2 eye centre) and capture a contiguous
// block of the RAW trace byte stream (the TPIU bytes that traceIF consumes:
// {trace_b, trace_a} per trace_clk) into a deep BRAM, one-shot. The PC reads
// the whole block out over UDP :5001 and saves it to a file for offline
// decode by Orbuculum (orbmortem -P ETM3.5 -e proj.axf).
//
//   STM32 ETM ── trace_capture_a7 (BUFR_IO, tap=TAP) ── {trace_b,trace_a}
//                                                             |
//                                          one-shot fill -> capture BRAM (DEPTH)
//                                                             |
//                                            UDP :5001 paged readout (16-bit addr)
//
// Capture starts after IDELAYCTRL ready + tap load, and freezes once full so
// the PC reads a stable snapshot. Re-arm by reconfiguring (reset).

`default_nettype none

module trace_stream_top #(
    parameter       CAP_METHOD = "OVERSAMPLE", // "OVERSAMPLE" (low-freq, edge+
                                      // eye) or "IDDR" (high-freq source-sync,
                                      // TRACECLK drives IDDR; per-lane IDELAY
                                      // deskew tap swept at runtime via CSR).
    parameter [4:0] TAP   = 5'd28,    // V2 eye centre / IDDR default deskew tap
    parameter       DEPTH = 61440,    // captured bytes (60 KB = 3840 frames);
                                      // keep < 65536 so 16-bit ext_addr also
                                      // reaches the status bytes at DEPTH..+2
    parameter       CAP_RAW = 0,      // 0: capture traceIF 16-byte frames;
                                      // 1: capture RAW nibble bytes
                                      // {trace_b[3:0],trace_a[3:0]} per
                                      // trace_clk (pre-traceIF) so the PC can
                                      // run orbtrace TPIUSync/TPIUDemux on the
                                      // true pin stream and settle whether the
                                      // STM32 formatter framing is present.
    parameter       EYE = 4,          // OVERSAMPLE mid-eye delay (ref_200m
                                      // cycles after a TRACECLK edge before
                                      // latching). 5 ns/cycle; half-bit at
                                      // /64 (~1.3 MHz) is ~380 ns (~76 cyc) so
                                      // ~38 is dead-centre. Swept on-board to
                                      // find the lowest bit-error point.
    parameter       SELFTEST = 0,     // 1: feed the OVERSAMPLE sampler an
                                      // FPGA-internal, asynchronous (phy_rx_clk
                                      // domain), clean edge-aligned pseudo-trace
                                      // (DDR ramp +7 mod 16 per edge) instead of
                                      // the physical pins. Isolates async
                                      // sampling-architecture faults from
                                      // physical SI (red-team r15 E1). The
                                      // captured stream must be an exact +7
                                      // mod-16 ramp; any deviation = the async
                                      // oversampling architecture itself errs.
    parameter       TRACE_WIDTH = 4,  // POWER-ON DEFAULT TPIU port width: 4, 2
                                      // or 1 bits. Runtime-switchable via CSR
                                      // 0x08 (see below), so one bitstream
                                      // covers all three widths -- upstream
                                      // traceIF takes `width` as a wire, and
                                      // making it a localparam here was what
                                      // forced a resynthesis per width.
                                      // 2-bit uses TRACED0/1, 1-bit TRACED0.
    parameter       STREAM = 0,       // 0: one-shot capture into BRAM, PC pulls
                                      // over UDP :5001 (default, keeps every
                                      // debugging feature). 1: continuous UDP
                                      // push of cap_byte to STREAM_DEST_IP:PORT
                                      // via fpga_core_net's self-TX FSM, so a
                                      // full CoreMark run fits at 2-bit. Only
                                      // supported with CAP_RAW=1 (streaming a
                                      // traceIF-framed byte stream would need a
                                      // separate frame-rate FIFO).
    parameter [31:0] STREAM_DEST_IP   = {8'd192, 8'd168, 8'd10, 8'd245},
    parameter [15:0] STREAM_DEST_PORT = 16'd5555,
    parameter [15:0] STREAM_PAYLOAD   = 16'd1024,   // UDP payload bytes/packet
                                                    // (excluding the 4-byte seq
                                                    // header we prepend).
    // BUILD_ID: Unix epoch stamped in by run_trace_stream.tcl at synth time,
    // read back over :5001 at 0xFF70..73 (LE). Lets the host PROVE which
    // bitstream is actually running -- critical because SRAM loads are volatile
    // (a power-cycle boots whatever is in QSPI instead), so the state file's
    // "last burned" record can silently diverge from reality. `td fpga-id`
    // reads this and compares against the built bit.
    parameter [31:0] BUILD_ID = 32'hDEADBEEF,
    parameter       STREAM_FIFO_DEPTH = 8192,       // clk200 -> clk125 async
                                                    // FIFO for trace bytes.
                                                    // Sized for ~80 us at the
                                                    // 100 MHz TRACECLK peak;
                                                    // grow if lost_cnt trips.
    parameter       STREAM_SELFTEST = 0             // 1: bypass the trace
                                                    // front-end and stream a
                                                    // free-running clk125 byte
                                                    // counter -- pure network
                                                    // link + UDP TX path test,
                                                    // no ETM required. The
                                                    // host verifies the ramp
                                                    // is monotone mod 256 and
                                                    // gap-free by sequence
                                                    // number, so any wire-side
                                                    // loss is unambiguous.
                                                    // Runtime CSR 0x09 also
                                                    // toggles it (data[0]=1).
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

    output wire        led0,   // TRACECLK input alive (blinks ~3 Hz; see led_diag)
    output wire        led1    // network TX alive     (blinks ~3 Hz; see led_diag)
);

    wire rst = ~rst_n;

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

    // capture front-end (BUFR_IO, fixed tap)
    wire        trace_clk;
    wire [3:0]  trace_a, trace_b;
    wire        idelayctrl_rdy;
    wire [7:0]  cap_byte;
    wire        cap_valid;
    wire [15:0] duty_hi_min, duty_hi_max, duty_lo_min, duty_lo_max;
    wire [31:0] duty_hi_sum, duty_lo_sum;
    wire [15:0] duty_hi_cnt, duty_lo_cnt;
    wire [15:0] glitch_cnt;

    // ---- SELFTEST pseudo-trace generator (async to ref_200m) ----------
    // Runs in the phy_rx_clk domain (125 MHz, recovered from the PHY — a
    // genuinely independent oscillator vs the MMCM-derived ref_200m, so the
    // TRACECLK/ref phase beats exactly like the real STM32 source). Produces a
    // clean edge-aligned DDR stream: a half-bit clock (~1 MHz after /64) and a
    // 4-bit value that advances +7 (mod 16) on EVERY clock edge. Edge-aligned
    // (data changes on the clock edge), matching the STM32 TPIU. +7 is coprime
    // to 16 so every nibble is distinct over 16 edges, and a dropped/duplicated
    // edge shows up as a +14/+0 step instead of +7 — trivially detectable
    // offline with zero cross-session alignment.
    wire        st_clk;
    wire [3:0]  st_data;
    generate
    if (SELFTEST) begin : g_selftest
        reg [6:0] st_div = 0;      // /64 of phy_rx_clk*2-edges -> ~1 MHz half-bit
        reg       st_clk_r = 0;
        reg [3:0] st_val = 0;
        always @(posedge phy_rx_clk) begin
            if (st_div == 7'd63) begin
                st_div   <= 0;
                st_clk_r <= ~st_clk_r;   // toggle => one trace edge
                st_val   <= st_val + 4'd7;  // advance on every (DDR) edge
            end else begin
                st_div <= st_div + 1'b1;
            end
        end
        assign st_clk  = st_clk_r;
        assign st_data = st_val;
    end else begin : g_nost
        assign st_clk  = 1'b0;
        assign st_data = 4'b0;
    end
    endgenerate

    reg [3:0] ld_sync = 4'h0;
    reg       loaded  = 1'b0;
    reg       tap_load = 1'b0;
    always @(posedge clk200 or posedge sys_rst) begin
        if (sys_rst) begin ld_sync <= 0; loaded <= 0; tap_load <= 0; end
        else begin
            ld_sync <= {ld_sync[2:0], idelayctrl_rdy};
            tap_load <= 1'b0;
            if (ld_sync[3] && !loaded) begin tap_load <= 1'b1; loaded <= 1'b1; end
        end
    end

    trace_capture_a7 #(.CLK_BUF("BUFR_IO"), .CAP_METHOD(CAP_METHOD),
                       .EYE_DELAY(EYE)) u_capture (
        .rst(sys_rst), .ref_200m(clk200),
        .trace_clk_p(trace_clk_in), .trace_data_p(trace_data_in),
        .tap_data0(tap0_200), .tap_data1(tap1_200),
        .tap_data2(tap2_200), .tap_data3(tap3_200),
        .tap_clk(tapc_200),
        .tap_load(tap_load | tap_load_200),
        .test_en(SELFTEST[0]), .test_clk(st_clk), .test_data(st_data),
        .eye_delay_rt(eye_rt),
        .cap_clear(cap_rearm),
        .trace_clk(trace_clk), .trace_a(trace_a), .trace_b(trace_b),
        .cap_byte(cap_byte), .cap_valid(cap_valid),
        .duty_hi_min(duty_hi_min), .duty_hi_max(duty_hi_max),
        .duty_lo_min(duty_lo_min), .duty_lo_max(duty_lo_max),
        .duty_hi_sum(duty_hi_sum), .duty_hi_cnt(duty_hi_cnt),
        .duty_lo_sum(duty_lo_sum), .duty_lo_cnt(duty_lo_cnt),
        .glitch_cnt(glitch_cnt),
        .idelayctrl_rdy(idelayctrl_rdy)
    );

    wire        fr_avail;
    wire [127:0] frame;
    // traceIF width encoding (CoreSight TPIU-Lite / upstream traceIF.v):
    //   2'b11 = 4-bit, 2'b10 = 2-bit, 2'b0x = 1-bit.
    // Power-on value from the TRACE_WIDTH parameter, overridable at runtime via
    // CSR 0x08 -- see tif_width_trace below.
    localparam [1:0] TIF_WIDTH_DEF = (TRACE_WIDTH == 2) ? 2'b10 :
                                     (TRACE_WIDTH == 1) ? 2'b00 : 2'b11;
    traceIF #(.MAXBUSWIDTH(4)) u_traceif (
        .rst(sys_rst | ~idelayctrl_rdy | width_change),
        .traceDina(trace_a), .traceDinb(trace_b), .traceClkin(trace_clk),
        .width(tif_width_trace), .edgeOutput(),
        .FrAvail(fr_avail), .Frame(frame)
    );
    // Isolate FrAvail (which has an async reset in traceIF) from the BRAM
    // write-enable path with a reset-less flop, then form the toggle strobe
    // from reset-less flops only. This keeps the BRAM ENARDEN off any
    // async-reset register (clears DRC REQP-1840).
    reg fr_iso, fr_q;
    always @(posedge trace_clk) begin
        fr_iso <= fr_avail;     // reset-less isolation
        fr_q   <= fr_iso;
    end
    wire frame_strobe = fr_iso ^ fr_q;

    wire [15:0] ext_addr;
    wire [7:0]  ext_data;
    localparam [15:0] NB = DEPTH;

    // ---- runtime CSRs (frequency sweep, doc 15), written via UDP :5002 ----
    //   addr 0x01: EYE delay (ref_200m cycles) for OVERSAMPLE mid-eye sampling
    //   addr 0x02: soft re-arm (any write re-arms the one-shot capture)
    wire [7:0] csr_addr_w, csr_data_w;
    wire       csr_we_w;
    reg  [7:0] eye_csr = 8'd0;          // 0 => use EYE parameter default
    reg        rearm_125 = 1'b0;        // 1-cycle pulse in clk125 domain
    // Per-lane IDELAY taps. CSR 0x05 sets ALL four lanes to the same value
    // (global sweep / backward compat). CSR 0x06 sets ONE lane independently:
    // data[6:5] = lane index (0..3), data[4:0] = tap (0..31) -> lets the host
    // deskew each data lane separately (proposal 33 per-lane calibration) to
    // remove inter-lane skew that a single global tap can't fix at high freq.
    reg  [4:0] tap_csr0 = TAP, tap_csr1 = TAP, tap_csr2 = TAP, tap_csr3 = TAP;
    reg  [4:0] tap_csrc = 5'd0;               // clock-lane tap (0 = no clk delay)
    reg        tap_load_125 = 1'b0;
    reg  [1:0] width_csr = TIF_WIDTH_DEF;     // TPIU port width (CSR 0x08)
    reg        selftest_csr = STREAM_SELFTEST[0]; // STREAM data source (CSR 0x09)
    always @(posedge clk125) begin
        rearm_125 <= 1'b0;
        tap_load_125 <= 1'b0;
        if (sys_rst) begin
            eye_csr <= 8'd0;
            tap_csr0 <= TAP; tap_csr1 <= TAP; tap_csr2 <= TAP; tap_csr3 <= TAP;
            tap_csrc <= 5'd0;
        end else if (csr_we_w) begin
            if (csr_addr_w == 8'h01) eye_csr <= csr_data_w;
            if (csr_addr_w == 8'h02) rearm_125 <= 1'b1;
            if (csr_addr_w == 8'h05) begin           // set all lanes
                tap_csr0 <= csr_data_w[4:0];
                tap_csr1 <= csr_data_w[4:0];
                tap_csr2 <= csr_data_w[4:0];
                tap_csr3 <= csr_data_w[4:0];
                tap_load_125 <= 1'b1;
            end
            if (csr_addr_w == 8'h06) begin            // set one lane
                case (csr_data_w[6:5])
                    2'd0: tap_csr0 <= csr_data_w[4:0];
                    2'd1: tap_csr1 <= csr_data_w[4:0];
                    2'd2: tap_csr2 <= csr_data_w[4:0];
                    2'd3: tap_csr3 <= csr_data_w[4:0];
                endcase
                tap_load_125 <= 1'b1;
            end
            if (csr_addr_w == 8'h07) begin            // clock-lane tap (>100M eye reach)
                tap_csrc <= csr_data_w[4:0];
                tap_load_125 <= 1'b1;
            end
            // TPIU port width, runtime-selectable so ONE bitstream serves 4/2/1
            // bit. data[1:0] is the raw traceIF encoding (11=4b, 10=2b, 0x=1b);
            // for convenience data may instead be the literal width 4/2/1.
            if (csr_addr_w == 8'h08) begin
                case (csr_data_w)
                    8'd4:    width_csr <= 2'b11;
                    8'd2:    width_csr <= 2'b10;
                    8'd1:    width_csr <= 2'b00;
                    default: width_csr <= csr_data_w[1:0];
                endcase
            end
            // STREAM data source select (STREAM=1 builds only):
            //   0 = real trace (cap_byte from trace_capture_a7, default)
            //   1 = FPGA-side selftest ramp (bypasses trace front-end entirely)
            // This gives us an unambiguous "is the UDP TX path healthy?" test
            // that stands on its own -- no STM32, no ETM, no TRACECLK involved.
            if (csr_addr_w == 8'h09) selftest_csr <= csr_data_w[0];
        end
    end

    // ---- runtime TPIU width: CSR (clk125) -> trace_clk domain -------------
    // traceIF samples `width` combinationally inside its trace_clk process, so
    // the value must be stable in that domain. It is quasi-static (set between
    // captures), so a 2-FF sync is sufficient. Changing width invalidates any
    // partially assembled frame and the sync-edge latch, so pulse traceIF's
    // reset on every change to force a clean re-sync rather than letting it
    // carry a half-built packet across the switch.
    reg [1:0] width_s0 = TIF_WIDTH_DEF, tif_width_trace = TIF_WIDTH_DEF;
    reg [1:0] width_prev = TIF_WIDTH_DEF;
    reg [3:0] width_chg_cnt = 4'd0;
    always @(posedge trace_clk) begin
        width_s0        <= width_csr;
        tif_width_trace <= width_s0;
        width_prev      <= tif_width_trace;
        // stretch the reset a few trace_clks so traceIF definitely sees it
        if (tif_width_trace != width_prev) width_chg_cnt <= 4'hf;
        else if (width_chg_cnt)            width_chg_cnt <= width_chg_cnt - 1'b1;
    end
    wire width_change = (width_chg_cnt != 4'd0);

    // Readback for the host (status byte). Report the CSR value, not the
    // trace_clk-domain copy: trace_clk can be absent (target not tracing) in
    // which case the synced copy never updates, and reading it from clk125
    // would be an unsynchronised cross-domain grab anyway.
    wire [7:0] width_rb = (width_csr == 2'b11) ? 8'd4 :
                          (width_csr == 2'b10) ? 8'd2 : 8'd1;
    // CDC the tap values + load pulse into clk200 (IDELAY C domain).
    reg [4:0] tap0_s0 = TAP, tap0_200 = TAP;
    reg [4:0] tap1_s0 = TAP, tap1_200 = TAP;
    reg [4:0] tap2_s0 = TAP, tap2_200 = TAP;
    reg [4:0] tap3_s0 = TAP, tap3_200 = TAP;
    reg [4:0] tapc_s0 = 5'd0, tapc_200 = 5'd0;
    reg       tapld_tgl125 = 1'b0;
    always @(posedge clk125) if (tap_load_125) tapld_tgl125 <= ~tapld_tgl125;
    reg [2:0] tapld_sync200 = 3'b0;
    always @(posedge clk200) begin
        tap0_s0 <= tap_csr0; tap0_200 <= tap0_s0;
        tap1_s0 <= tap_csr1; tap1_200 <= tap1_s0;
        tap2_s0 <= tap_csr2; tap2_200 <= tap2_s0;
        tapc_s0 <= tap_csrc; tapc_200 <= tapc_s0;
        tap3_s0 <= tap_csr3; tap3_200 <= tap3_s0;
        tapld_sync200 <= {tapld_sync200[1:0], tapld_tgl125};
    end
    wire tap_load_200 = tapld_sync200[2] ^ tapld_sync200[1];

    // eye_csr is quasi-static (set between captures) — sample it into the
    // clk200 domain with a 2-FF sync for clean use by trace_capture_a7.
    reg [7:0] eye_s0 = 0, eye_rt = 0;
    always @(posedge clk200) begin
        eye_s0 <= eye_csr;
        eye_rt <= eye_s0;
    end

    // Soft re-arm: cross the clk125 rearm pulse into clk200 (capture domain)
    // as a one-cycle pulse via a toggle + edge-detect synchroniser.
    reg        rearm_tgl125 = 1'b0;
    always @(posedge clk125) if (rearm_125) rearm_tgl125 <= ~rearm_tgl125;
    reg [2:0]  rearm_sync200 = 3'b0;
    always @(posedge clk200) rearm_sync200 <= {rearm_sync200[1:0], rearm_tgl125};
    wire cap_rearm = rearm_sync200[2] ^ rearm_sync200[1];   // 1-cyc pulse in clk200

    generate
    if (CAP_RAW) begin : g_raw
        // ---- RAW nibble capture: one byte {trace_b,trace_a} per trace_clk ----
        localparam RAW_AW = $clog2(DEPTH);
        (* ram_style = "block" *)
        reg [7:0] rawmem [0:DEPTH-1];
        reg [RAW_AW:0] rwr;
        wire rfull = rwr[RAW_AW];
        // Glitch-free capture: write the ref_200m-domain byte on its valid
        // strobe, entirely in the clk200 domain. This replaces the previous
        // capture on the async BUFR_IO `trace_clk`, which tore bytes when its
        // edge raced the ref-domain a/b registers (doc 14 §27 root cause).
        always @(posedge clk200) begin
            if (cap_valid && !rfull) rawmem[rwr[RAW_AW-1:0]] <= cap_byte;
        end
        always @(posedge clk200) begin
            if (sys_rst || cap_rearm)  rwr <= 0;   // soft re-arm via CSR :5002
            else if (cap_valid && !rfull)  rwr <= rwr + 1'b1;
        end
        // Capture-generation counter: increments on every soft re-arm so the
        // PC can confirm it is reading a FRESH capture (poll until gen changed
        // AND full=1) rather than a stale buffer. Crucial at high TRACECLK
        // where a naive re-arm+read races (doc 15 §7/§8). Synced to clk125 for
        // the readout-byte mux.
        reg [7:0] cap_gen200 = 8'd0;
        always @(posedge clk200) if (cap_rearm) cap_gen200 <= cap_gen200 + 1'b1;
        reg [7:0] cap_gen_s0 = 0, cap_gen_125 = 0;
        always @(posedge clk125) begin
            cap_gen_s0  <= cap_gen200;
            cap_gen_125 <= cap_gen_s0;
        end

        // ---- FPGA capture-time base (doc 15 §24.2) ----------------------
        // F429 ETM has no usable wall-clock (no TSGEN, no cycle-accurate;
        // §22/§24). So WE provide the authoritative time base on the capture
        // side: a free-running ref_200m counter (5 ns/tick) snapshotted into a
        // small table every TS_STRIDE captured bytes. This is real wall-clock,
        // INDEPENDENT of the target TRACECLK, so it:
        //   * adapts to any trace frequency automatically (we time the bytes,
        //     not assume a byte rate), and
        //   * records TRACECLK idle pauses as genuine time gaps (the all-zero
        //     "long-0" regions), instead of smearing time linearly across them.
        // The PC maps captured-byte-index -> wall-clock by interpolating
        // between adjacent table entries, then carries that through deframing.
        localparam TS_STRIDE_LOG2 = 8;                       // snapshot / 256 bytes
        localparam TS_N           = (DEPTH >> TS_STRIDE_LOG2) + 1;
        localparam TS_IW          = $clog2(TS_N);
        localparam [15:0] TS_BYTES = 4*TS_N;                 // 4 bytes/entry
        localparam [7:0]  TS_N_LO  = TS_N[7:0];
        localparam [7:0]  TS_N_HI  = TS_N[15:8];
        reg [31:0] cap_clk_cnt = 32'd0;                      // free-run ref_200m ticks
        always @(posedge clk200) begin
            if (sys_rst || cap_rearm) cap_clk_cnt <= 32'd0;
            else                      cap_clk_cnt <= cap_clk_cnt + 1'b1;
        end
        (* ram_style = "distributed" *)
        reg [31:0] tsmem [0:TS_N-1];
        wire             ts_snap = cap_valid && !rfull &&
                                   (rwr[TS_STRIDE_LOG2-1:0] == 0);
        wire [TS_IW-1:0] ts_widx = rwr[RAW_AW-1:TS_STRIDE_LOG2];
        always @(posedge clk200) if (ts_snap) tsmem[ts_widx] <= cap_clk_cnt;
        // last captured-byte time (latched each accepted byte) for the tail
        reg [31:0] cap_clk_last = 32'd0;
        always @(posedge clk200) begin
            if (sys_rst || cap_rearm)      cap_clk_last <= 32'd0;
            else if (cap_valid && !rfull)  cap_clk_last <= cap_clk_cnt;
        end
        // ts table readout (clk125, registered like rrd: 1-cycle latency).
        // tsrd is the word read for the PREVIOUS presented address; the byte-
        // lane selector must therefore also use the previous address's low
        // bits, or the lanes scramble across words. Register ts_off[1:0] to
        // align the lane with the latched word (mirrors the rrd +1/drop-first
        // contract used by trace_dump).
        localparam [15:0] TS_BASE = NB + 16'd64;
        wire [15:0]      ts_off  = ext_addr - TS_BASE;
        wire [TS_IW-1:0] ts_ridx = ts_off[TS_IW+1:2];        // /4 (4 bytes/entry)
        reg  [31:0]      tsrd;
        reg  [1:0]       ts_lane_d;
        always @(posedge clk125) begin
            tsrd      <= tsmem[ts_ridx];
            ts_lane_d <= ts_off[1:0];
        end
        wire             ts_win  = (ext_addr >= TS_BASE) &&
                                   (ext_addr <  TS_BASE + TS_BYTES);
        wire [7:0]       ts_byte = tsrd[8*ts_lane_d +: 8];
        // sync cap_clk_last into clk125 for the status read
        reg [31:0] cclast_s0 = 0, cclast_125 = 0;
        always @(posedge clk125) begin
            cclast_s0  <= cap_clk_last;
            cclast_125 <= cclast_s0;
        end

        reg [7:0] rrd;
        always @(posedge clk125) rrd <= rawmem[ext_addr[RAW_AW-1:0]];
        assign ext_data = (ext_addr < NB)        ? rrd :
                          (ext_addr == NB+0)     ? NB[7:0] :
                          (ext_addr == NB+1)     ? NB[15:8] :
                          (ext_addr == NB+2)     ? {7'b0, rfull} :
                          (ext_addr == NB+3)     ? cap_gen_125 :
                          // E3 duty stats (clk200-domain, async-read OK: quasi-static)
                          (ext_addr == NB+4)     ? duty_hi_min[7:0] :
                          (ext_addr == NB+5)     ? duty_hi_min[15:8] :
                          (ext_addr == NB+6)     ? duty_hi_max[7:0] :
                          (ext_addr == NB+7)     ? duty_hi_max[15:8] :
                          (ext_addr == NB+8)     ? duty_lo_min[7:0] :
                          (ext_addr == NB+9)     ? duty_lo_min[15:8] :
                          (ext_addr == NB+10)    ? duty_lo_max[7:0] :
                          (ext_addr == NB+11)    ? duty_lo_max[15:8] :
                          (ext_addr == NB+12)    ? duty_hi_sum[7:0] :
                          (ext_addr == NB+13)    ? duty_hi_sum[15:8] :
                          (ext_addr == NB+14)    ? duty_hi_sum[23:16] :
                          (ext_addr == NB+15)    ? duty_hi_sum[31:24] :
                          (ext_addr == NB+16)    ? duty_hi_cnt[7:0] :
                          (ext_addr == NB+17)    ? duty_hi_cnt[15:8] :
                          (ext_addr == NB+18)    ? duty_lo_sum[7:0] :
                          (ext_addr == NB+19)    ? duty_lo_sum[15:8] :
                          (ext_addr == NB+20)    ? duty_lo_sum[23:16] :
                          (ext_addr == NB+21)    ? duty_lo_sum[31:24] :
                          (ext_addr == NB+22)    ? duty_lo_cnt[7:0] :
                          (ext_addr == NB+23)    ? duty_lo_cnt[15:8] :
                          (ext_addr == NB+24)    ? glitch_cnt[7:0] :
                          (ext_addr == NB+25)    ? glitch_cnt[15:8] :
                          // FPGA capture-time base metadata (doc 15 §24.2)
                          (ext_addr == NB+26)    ? TS_STRIDE_LOG2[7:0] :  // stride = 1<<this
                          (ext_addr == NB+27)    ? TS_N_LO :            // table entry count
                          (ext_addr == NB+28)    ? TS_N_HI :
                          (ext_addr == NB+29)    ? cclast_125[7:0] :      // last byte's tick
                          (ext_addr == NB+30)    ? cclast_125[15:8] :
                          (ext_addr == NB+31)    ? cclast_125[23:16] :
                          (ext_addr == NB+32)    ? cclast_125[31:24] :
                          // active TPIU port width (4/2/1), CSR 0x08
                          (ext_addr == NB+33)    ? width_rb :
                          // stream mode: bytes dropped by the clk200->clk125
                          // async FIFO because the network path lagged the
                          // capture. Any nonzero value is diagnostic.
                          (ext_addr == NB+34)    ? stream_lost_cnt[7:0] :
                          (ext_addr == NB+35)    ? stream_lost_cnt[15:8] :
                          (ext_addr == NB+36)    ? stream_lost_cnt[23:16] :
                          (ext_addr == NB+37)    ? stream_lost_cnt[31:24] :
                          // STREAM selftest mode readback (CSR 0x09)
                          (ext_addr == NB+38)    ? {7'b0, selftest_csr} :
                          // BUILD_ID (compile Unix epoch) -- proves running bit
                          // identity; survives power-cycle-from-QSPI reads.
                          (ext_addr == 16'hFF70) ? BUILD_ID[7:0] :
                          (ext_addr == 16'hFF71) ? BUILD_ID[15:8] :
                          (ext_addr == 16'hFF72) ? BUILD_ID[23:16] :
                          (ext_addr == 16'hFF73) ? BUILD_ID[31:24] :
                          // ts table window: NB+64 .. NB+64+4*TS_N (LE u32/entry)
                          ts_win                 ? ts_byte : 8'h00;
        // (led1 is the TX-liveness beacon driven by led_diag; the capture-full
        //  state is available to the host via the NB+2 status byte instead.)
    end else begin : g_frame
        // ---- traceIF 16-byte frame capture (default) ----
        localparam NFR = DEPTH/16;
        localparam FAW = $clog2(NFR);
        (* ram_style = "block" *)
        reg [127:0] capmem [0:NFR-1];
        reg [FAW:0] wr_ptr;
        wire full = wr_ptr[FAW];
        wire wr_en = frame_strobe && !full;
        always @(posedge trace_clk) begin
            if (wr_en) capmem[wr_ptr[FAW-1:0]] <= frame;
        end
        always @(posedge trace_clk) begin
            if (sys_rst)      wr_ptr <= 0;
            else if (wr_en)   wr_ptr <= wr_ptr + 1'b1;
        end
        reg [127:0] frd;
        always @(posedge clk125) frd <= capmem[ext_addr[FAW+3:4]];
        wire [3:0] bsel = ext_addr[3:0];
        wire [7:0] cap_byte = frd[8*(15 - bsel) +: 8];
        assign ext_data = (ext_addr < NB)        ? cap_byte :
                          (ext_addr == NB+0)     ? NB[7:0] :
                          (ext_addr == NB+1)     ? NB[15:8] :
                          (ext_addr == NB+2)     ? {7'b0, full} :
                          (ext_addr == NB+33)    ? width_rb : 8'h00;
        // (led1 driven by led_diag as TX-liveness beacon; full flag is at NB+2.)
    end
    endgenerate

    // ==================================================================
    // Continuous UDP streaming path (STREAM=1)
    // ==================================================================
    // cap_byte / cap_valid come out of trace_capture_a7 in the clk200 domain
    // (see the IDDR generate's small trace_clk->clk200 CDC FIFO). Cross into
    // clk125 for the packetiser and fpga_core_net's self-TX FSM, prepend a
    // 32-bit BE sequence per packet so the host can spot any lost UDP frame.
    // Reuse of the fpga_core_net STREAM contract that trace_mmcm_stream_top
    // already validated; only the source of cap_byte changes.
    //
    // Byte rates for context (TRACECLK=100 MHz, cap_byte is 1 B / TRACECLK
    // regardless of port width; unused lanes are just static levels):
    //   4-bit   100 MB/s   (would swamp a 125 MB/s GigE budget)
    //   2-bit    50 MB/s   (product-target width; comfortably < 100 MB/s)
    //   1-bit    25 MB/s
    // At 2-bit half the bits are dead lanes, but streaming those alongside is
    // free and lets the host distinguish "silent because of dead lane" from
    // "silent because of no trace".
    wire [7:0] stream_tdata;
    wire       stream_tvalid;
    wire       stream_tready;
    wire [31:0] stream_lost_cnt;
    wire        stream_active_led;
    generate
    if (STREAM && CAP_RAW) begin : g_stream
        // ---- selftest ramp source (CSR 0x09) --------------------------------
        // Free-running byte counter in clk200 (same domain as cap_byte, so the
        // downstream async FIFO / packetiser doesn't care which one is live).
        // Advances every clk200 cycle -> 200 MB/s, way above the 100 MB/s trace
        // rate, so if the network path is healthy it also exercises it beyond
        // real workload. Any received byte that isn't (prev+1) mod 256 is a
        // capture-side drop -- but note the async FIFO already applies
        // backpressure, so the correct expectation is "monotone mod 256 with
        // possible steps > 1 where the FIFO stalled the counter's producer"
        // ... we sidestep that by only advancing the counter when the FIFO
        // accepts a byte, i.e. treat it as a normal AXIS source.
        wire selftest_active;
        reg [7:0] bw_cnt = 8'd0;
        wire       bw_valid = selftest_active;   // always has data
        wire       bw_ready;                     // driven by u_cdc.s_axis_tready
        always @(posedge clk200) begin
            if (sys_rst)             bw_cnt <= 8'd0;
            else if (bw_valid && bw_ready) bw_cnt <= bw_cnt + 8'd1;
        end

        // Sync selftest_csr (clk125) into clk200 (source domain).
        reg selftest_s0 = 0, selftest_200 = 0;
        always @(posedge clk200) begin selftest_s0 <= selftest_csr; selftest_200 <= selftest_s0; end
        assign selftest_active = selftest_200;

        // Mux into the FIFO input.
        wire [7:0] src_data  = selftest_active ? bw_cnt   : cap_byte;
        wire       src_valid = selftest_active ? bw_valid : cap_valid;
        assign     bw_ready  = fifo_in_ready & selftest_active;

        // clk200 -> clk125 async FIFO
        wire [7:0] fifo_out_data;
        wire       fifo_out_valid;
        wire       fifo_out_ready;
        wire       fifo_in_ready;
        wire [$clog2(STREAM_FIFO_DEPTH):0] m_depth;

        axis_async_fifo #(
            .DEPTH(STREAM_FIFO_DEPTH), .DATA_WIDTH(8),
            .KEEP_ENABLE(0), .LAST_ENABLE(0), .USER_ENABLE(0), .FRAME_FIFO(0)
        ) u_cdc (
            .s_clk(clk200), .s_rst(sys_rst),
            .s_axis_tdata(src_data), .s_axis_tkeep(1'b0),
            .s_axis_tvalid(src_valid), .s_axis_tready(fifo_in_ready),
            .s_axis_tlast(1'b0), .s_axis_tid(8'h0), .s_axis_tdest(8'h0),
            .s_axis_tuser(1'b0),
            .m_clk(clk125), .m_rst(sys_rst),
            .m_axis_tdata(fifo_out_data), .m_axis_tkeep(),
            .m_axis_tvalid(fifo_out_valid), .m_axis_tready(fifo_out_ready),
            .m_axis_tlast(), .m_axis_tid(), .m_axis_tdest(), .m_axis_tuser(),
            .s_pause_req(1'b0), .s_pause_ack(),
            .m_pause_req(1'b0), .m_pause_ack(),
            .s_status_depth(), .s_status_depth_commit(), .s_status_overflow(),
            .s_status_bad_frame(), .s_status_good_frame(),
            .m_status_depth(m_depth), .m_status_depth_commit(),
            .m_status_overflow(),
            .m_status_bad_frame(), .m_status_good_frame()
        );

        // Drop counter (clk200): every src_valid the FIFO cannot accept means
        // the network/packetiser lags the source. Any nonzero value is a
        // diagnostic. In selftest mode the counter self-throttles (bw_ready
        // gates its advance), so this reports drops only in real-trace mode --
        // which is exactly what we care about.
        reg [31:0] lost200 = 32'd0;
        wire       drop = cap_valid & ~fifo_in_ready & ~selftest_active;
        always @(posedge clk200) begin
            if (sys_rst)    lost200 <= 32'd0;
            else if (drop)  lost200 <= lost200 + 1'b1;
        end
        // CDC to clk125 for CSR readback (quasi-static -> 2FF sync is fine)
        reg [31:0] lost_s0 = 0, lost_125 = 0;
        always @(posedge clk125) begin lost_s0 <= lost200; lost_125 <= lost_s0; end
        assign stream_lost_cnt = lost_125;

        // Packetiser: [4-byte BE seq][STREAM_PAYLOAD trace bytes] per UDP frame.
        // Same shape as trace_mmcm_stream_top, minus the heartbeat/startup
        // machinery (we assume the host is up before enabling trace here).
        localparam integer PKT = STREAM_PAYLOAD + 4;
        reg [31:0] seq = 0;
        reg [15:0] pos = 0;
        reg        pkt_active = 0;
        wire       in_header = (pos < 16'd4);
        // Only start a packet once the FIFO has at least a full payload buffered
        // (or the FSM will underrun and pad with 0x00, wasting bandwidth).
        wire       can_start = (m_depth >= STREAM_PAYLOAD[$clog2(STREAM_FIFO_DEPTH):0]);

        wire [7:0] seq_byte = (pos == 16'd0) ? seq[31:24] :
                              (pos == 16'd1) ? seq[23:16] :
                              (pos == 16'd2) ? seq[15:8]  :
                                               seq[7:0];
        assign stream_tvalid  = pkt_active & (in_header | fifo_out_valid);
        assign stream_tdata   = in_header ? seq_byte : fifo_out_data;
        assign fifo_out_ready = pkt_active & ~in_header & stream_tready;

        always @(posedge clk125) begin
            if (sys_rst) begin
                pos <= 0; seq <= 0; pkt_active <= 0;
            end else if (!pkt_active) begin
                if (can_start) pkt_active <= 1'b1;
                pos <= 0;
            end else if (stream_tvalid && stream_tready) begin
                if (pos == PKT-1) begin
                    pos <= 0;
                    seq <= seq + 1'b1;
                    pkt_active <= 1'b0;
                end else begin
                    pos <= pos + 1'b1;
                end
            end
        end
        assign stream_active_led = pkt_active;
    end else begin : g_no_stream
        assign stream_tdata      = 8'h00;
        assign stream_tvalid     = 1'b0;
        assign stream_lost_cnt   = 32'd0;
        assign stream_active_led = 1'b0;
    end
    endgenerate

    fpga_core_net #(
        .TARGET("XILINX"),
        .STREAM((STREAM && CAP_RAW) ? 1 : 0),
        .UDP_CHECKSUM_GEN_ENABLE(0),  // stalls a continuous self-TX; per fpga_core_net
        .STREAM_DEST_IP(STREAM_DEST_IP),
        .STREAM_DEST_PORT(STREAM_DEST_PORT),
        .STREAM_PKT_BYTES((STREAM && CAP_RAW) ? (STREAM_PAYLOAD + 16'd4) : 16'd1024)
    ) u_eth (
        .clk(clk125), .clk90(clk125_90), .rst(sys_rst),
        .btnu(1'b0), .btnl(1'b0), .btnd(1'b0), .btnr(1'b0), .btnc(1'b0),
        .sw(8'h0), .led(),
        .phy_rx_clk(phy_rx_clk), .phy_rxd(phy_rxd), .phy_rx_ctl(phy_rx_ctl),
        .phy_tx_clk(phy_tx_clk), .phy_txd(phy_txd), .phy_tx_ctl(phy_tx_ctl),
        .phy_reset_n(phy_reset_n),
        .phy_int_n(1'b1), .phy_pme_n(1'b1),
        .uart_rxd(1'b1), .uart_txd(),
        .dbg_rx_good_frame(), .dbg_rx_bad_fcs(),
        .dbg_tx_axis_tvalid(dbg_tx_axis_tvalid),
        .ext_addr(ext_addr), .ext_data(ext_data),
        .csr_addr(csr_addr_w), .csr_data(csr_data_w), .csr_we(csr_we_w),
        .stream_tdata(stream_tdata), .stream_tvalid(stream_tvalid),
        .stream_tready(stream_tready)
    );

    assign phy_mdio = 1'bz;
    assign phy_mdc  = 1'b0;

    // ---- diagnostic LEDs (led_diag) ----
    // led0 = TRACECLK input alive (blinks ~3 Hz while the recovered trace clock
    //        toggles; dark = no TRACECLK from the STM32).
    // led1 = network TX alive (blinks ~3 Hz while the MAC transmits any frame;
    //        dark = FPGA emits nothing -> if PC also sees nothing, fault is on
    //        the FPGA side, not the cable/hub/PC).
    // These two INTERNAL observations split the "PC sees no packets" ambiguity
    // without touching the network path. NB: the old ~full/rfull "capture full"
    // meaning of led1 moved into the CSR status bytes (NB+2 full flag), which
    // the host already reads -- the LED is more useful as a TX liveness beacon.
    wire dbg_tx_axis_tvalid;
    led_diag u_led_diag (
        .clk125(clk125), .rst(sys_rst),
        .trace_clk(trace_clk),
        .tx_active(dbg_tx_axis_tvalid),
        .led0(led0), .led1(led1)
    );

endmodule

`default_nettype wire
