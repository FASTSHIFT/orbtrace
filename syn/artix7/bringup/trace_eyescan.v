// trace_eyescan
// =============
// Stage-4 V1: FPGA self-loopback eye-scan of the source-synchronous DDR
// trace capture path, with ZERO dependency on the STM32. The FPGA drives a
// known DDR pattern out 5 pins (1 clock + 4 data), the board jumpers loop
// them back into the trace input pins, trace_capture_a7 samples them, and
// this module checks correctness while sweeping the per-lane IDELAY tap
// across all 32 settings. The resulting per-tap / per-lane error table is
// the eye: taps with zero errors are inside the data eye.
//
// Pattern (self-aligning, no frame lock needed):
//   every clk_tx cycle emit a free-running byte cnt; cnt++ each cycle.
//   lane i rising-edge bit = cnt[i], falling-edge bit = cnt[4+i].
//   So the recovered byte {trace_b,trace_a} == cnt, and consecutive cycles
//   differ by exactly +1. The checker only verifies the +1 increment
//   relationship, so it self-synchronises regardless of loop latency.
//
// Domains:
//   clk_tx     : pattern launch (= the recovered-clock's source; MMCM clk100)
//   trace_clk  : recovered clock from the looped-back TXCLK (checker + FSM)
//   clk_rd     : results-table read port (fpga_core_net's clk)
// clk_tx and trace_clk are the same physical clock routed through the board
// jumper; Vivado treats them as separate (async) clocks.

`default_nettype none

module trace_eyescan #(
    parameter WIN_BITS = 20   // error-count window = 2^WIN_BITS trace_clk cycles
) (
    input  wire        rst,

    // pattern launch clock
    input  wire        clk_tx,

    // loopback OUTPUT pins (jumper these to the trace_*_in pins on GPIO1)
    output wire        txclk_out,
    output wire [3:0]  txd_out,

    // captured samples from trace_capture_a7 (trace_clk domain)
    input  wire        trace_clk,
    input  wire [3:0]  trace_a,    // rising-edge nibble  -> cnt[3:0]
    input  wire [3:0]  trace_b,    // falling-edge nibble -> cnt[7:4]
    input  wire        idelayctrl_rdy,

    // per-lane IDELAY tap control to trace_capture_a7 (one common tap swept)
    output reg  [4:0]  tap,
    output reg         tap_load,

    // results-table read port. 256 bytes:
    //   addr = tap*8 + lane*2 + {hi,lo}  -> 16-bit saturating error count
    // Combinational read (distributed RAM), no clk needed.
    input  wire [7:0]  rd_addr,
    output wire [7:0]  rd_data,

    // status
    output reg         scan_done,
    output reg  [4:0]  best_tap,
    output reg         eye_found     // any tap had 0 errors on all 4 lanes
);

    // ==================================================================
    // Pattern generator (clk_tx). ODDR launches clock copy + 4 data lanes.
    // ==================================================================
    reg [7:0] cnt;
    always @(posedge clk_tx)
        if (rst) cnt <= 8'd0;
        else     cnt <= cnt + 8'd1;

    // clock copy: D1=1 (rising), D2=0 (falling) -> a replica of clk_tx
    ODDR #(.DDR_CLK_EDGE("SAME_EDGE"), .SRTYPE("ASYNC"))
    u_oddr_clk (.Q(txclk_out), .C(clk_tx), .CE(1'b1),
                .D1(1'b1), .D2(1'b0), .R(1'b0), .S(1'b0));

    genvar i;
    generate
        for (i = 0; i < 4; i = i + 1) begin : g_txd
            ODDR #(.DDR_CLK_EDGE("SAME_EDGE"), .SRTYPE("ASYNC"))
            u_oddr_d (.Q(txd_out[i]), .C(clk_tx), .CE(1'b1),
                      .D1(cnt[i]), .D2(cnt[4+i]), .R(1'b0), .S(1'b0));
        end
    endgenerate

    // ==================================================================
    // Checker (trace_clk). rx_byte must equal prev+1; attribute per lane.
    // ==================================================================
    wire [7:0] rx_byte = {trace_b, trace_a};
    reg        primed;

    // Fully-registered checker (removes any combinational skew between the
    // sample and its predecessor): capture rx_byte into two pipeline stages
    // and compare stage1 == stage2 + 1, attributing mismatches per lane.
    reg [7:0]  rx_d1, rx_d2;
    wire [7:0] pred = rx_d2 + 8'd1;

    // per-lane mismatch this cycle (lane i owns bit i (rising) and 4+i (falling))
    wire [3:0] lane_err;
    generate
        for (i = 0; i < 4; i = i + 1) begin : g_chk
            assign lane_err[i] = primed &
                ((rx_d1[i] ^ pred[i]) | (rx_d1[4+i] ^ pred[4+i]));
        end
    endgenerate

    // count_en gates accumulation to the measurement window (set by FSM)
    reg count_en;
    reg [15:0] err_cnt [0:3];
    integer L;
    always @(posedge trace_clk) begin
        if (rst) begin
            primed <= 1'b0;
            rx_d1  <= 8'd0;
            rx_d2  <= 8'd0;
        end else begin
            rx_d1 <= rx_byte;
            rx_d2 <= rx_d1;
            primed <= 1'b1;
        end
    end

    // ------------------------------------------------------------------
    // Raw-sample capture: after scan_done (IDELAY parked at best_tap),
    // record 32 CONSECUTIVE rx_byte samples so the PC can SEE what the link
    // actually delivers (vs guessing). Frozen once full.
    // ------------------------------------------------------------------
    reg [7:0] raw_buf [0:31];
    reg [5:0] raw_idx;       // counts 0..32, stops at 32
    reg       raw_full;
    always @(posedge trace_clk) begin
        if (rst) begin
            raw_idx  <= 6'd0;
            raw_full <= 1'b0;
        end else if (scan_done && !raw_full) begin
            raw_buf[raw_idx[4:0]] <= rx_byte;
            if (raw_idx == 6'd31) raw_full <= 1'b1;
            else                  raw_idx  <= raw_idx + 6'd1;
        end
    end

    // saturating per-lane error accumulators
    always @(posedge trace_clk) begin
        if (clr_cnt) begin
            err_cnt[0] <= 16'd0; err_cnt[1] <= 16'd0;
            err_cnt[2] <= 16'd0; err_cnt[3] <= 16'd0;
        end else if (count_en) begin
            for (L = 0; L < 4; L = L + 1)
                if (lane_err[L] && err_cnt[L] != 16'hFFFF)
                    err_cnt[L] <= err_cnt[L] + 16'd1;
        end
    end

    // ==================================================================
    // Scan FSM (trace_clk). For each tap 0..31: load tap, settle, clear,
    // count over 2^WIN_BITS cycles, latch per-lane errors into the table.
    // ==================================================================
    localparam S_IDLE=0, S_LOAD=1, S_SETTLE=2, S_CLR=3, S_COUNT=4, S_STORE=5, S_NEXT=6, S_DONE=7;
    reg [2:0]  st;
    reg [4:0]  cur_tap;
    reg [WIN_BITS-1:0] win;
    reg [9:0]  settle;
    reg        clr_cnt;

    // results table: 128 bytes (32 taps * 4 lanes * 1 byte, error count
    // saturating at 255) + diagnostics at 128..131:
    //   128 = live raw rx_byte (last sample)
    //   129 = per-bit "ever toggled" activity mask over the whole scan
    //         (bit n set => trace bit n changed at least once)
    //   130 = best_tap, 131 = {eye_found, scan_done, 6'b0}
    (* ram_style = "distributed" *)
    reg [7:0] table_mem [0:131];

    // per-tap sample snapshots (ground truth): snap_d2[t]/snap_d1[t] are two
    // consecutive sampled bytes captured at tap t during the sweep.
    reg [7:0] snap_d2 [0:31];
    reg [7:0] snap_d1 [0:31];

    // diagnostics: activity mask (trace_clk domain)
    reg [7:0] act_mask;
    always @(posedge trace_clk) begin
        if (rst) begin
            act_mask <= 8'd0;
        end else if (primed) begin
            act_mask <= act_mask | (rx_d1 ^ rx_d2); // bits that changed
        end
    end

    // track best tap = the one with the smallest summed error (prefer 0)
    reg [17:0] best_sum;
    wire [17:0] cur_sum = err_cnt[0] + err_cnt[1] + err_cnt[2] + err_cnt[3];

    always @(posedge trace_clk) begin
        if (rst) begin
            st        <= S_IDLE;
            cur_tap   <= 5'd0;
            tap       <= 5'd0;
            tap_load  <= 1'b0;
            count_en  <= 1'b0;
            clr_cnt   <= 1'b0;
            scan_done <= 1'b0;
            best_tap  <= 5'd0;
            best_sum  <= 18'h3FFFF;
            eye_found <= 1'b0;
            win       <= {WIN_BITS{1'b0}};
            settle    <= 10'd0;
        end else begin
            tap_load <= 1'b0;
            clr_cnt  <= 1'b0;
            case (st)
                S_IDLE: begin
                    // wait for IDELAYCTRL ready, then start the sweep
                    if (idelayctrl_rdy) begin
                        cur_tap   <= 5'd0;
                        tap       <= 5'd0;
                        best_sum  <= 18'h3FFFF;
                        eye_found <= 1'b0;
                        scan_done <= 1'b0;
                        st        <= S_LOAD;
                    end
                end
                S_LOAD: begin
                    tap      <= cur_tap;
                    tap_load <= 1'b1;        // pulse (held 1 trace_clk; ref_200m sees it)
                    settle   <= 10'd0;
                    st       <= S_SETTLE;
                end
                S_SETTLE: begin
                    settle <= settle + 10'd1;
                    if (settle == 10'd511) begin
                        clr_cnt <= 1'b1;     // clear counters before window
                        win     <= {WIN_BITS{1'b0}};
                        st      <= S_CLR;
                    end
                end
                S_CLR: begin
                    count_en <= 1'b1;        // open measurement window
                    st       <= S_COUNT;
                end
                S_COUNT: begin
                    win <= win + 1'b1;
                    if (win == {WIN_BITS{1'b1}}) begin
                        count_en <= 1'b0;
                        st       <= S_STORE;
                    end
                end
                S_STORE: begin
                    // latch per-lane errors (saturate to 255) into the table
                    table_mem[{cur_tap,2'd0}]      <= (err_cnt[0]==16'd0) ? 8'd0 : (err_cnt[0][15:8]!=0 ? 8'd255 : err_cnt[0][7:0]);
                    table_mem[{cur_tap,2'd0}|8'd1] <= (err_cnt[1]==16'd0) ? 8'd0 : (err_cnt[1][15:8]!=0 ? 8'd255 : err_cnt[1][7:0]);
                    table_mem[{cur_tap,2'd0}|8'd2] <= (err_cnt[2]==16'd0) ? 8'd0 : (err_cnt[2][15:8]!=0 ? 8'd255 : err_cnt[2][7:0]);
                    table_mem[{cur_tap,2'd0}|8'd3] <= (err_cnt[3]==16'd0) ? 8'd0 : (err_cnt[3][15:8]!=0 ? 8'd255 : err_cnt[3][7:0]);
                    // per-tap sample snapshot (ground truth): the two pipeline
                    // bytes at this tap, so the PC can see directly whether the
                    // sampled data at this tap is a clean +1 ramp.
                    snap_d2[cur_tap] <= rx_d2;
                    snap_d1[cur_tap] <= rx_d1;
                    if (cur_sum < best_sum) begin
                        best_sum <= cur_sum;
                        best_tap <= cur_tap;
                    end
                    if (cur_sum == 18'd0) eye_found <= 1'b1;
                    st <= S_NEXT;
                end
                S_NEXT: begin
                    if (cur_tap == 5'd31) begin
                        st <= S_DONE;
                    end else begin
                        cur_tap <= cur_tap + 5'd1;
                        st      <= S_LOAD;
                    end
                end
                S_DONE: begin
                    scan_done <= 1'b1;
                    // diagnostics
                    table_mem[128] <= rx_byte;
                    table_mem[129] <= act_mask;
                    table_mem[130] <= {3'b0, best_tap};
                    table_mem[131] <= {eye_found, scan_done, 6'b0};
                    // park IDELAY at the best tap so the link is usable
                    tap      <= best_tap;
                    tap_load <= 1'b1;
                    st       <= S_DONE;   // latch; rescan via rst
                end
            endcase
        end
    end

    // ------------------------------------------------------------------
    // Results read port. table_mem is static after scan_done; PC reads it
    // after triggering. Combinational (async) read so the byte at rd_addr
    // is presented with no latency.
    //
    // IMPORTANT: until the sweep COMPLETES (scan_done), return 0xFF — a
    // not-yet-run table is all-zero, which would otherwise read as a
    // perfect (all-clean) eye. 0xFF -> error count 0xFFFF -> renders as
    // "closed", and the PC flags an all-0xFF table as "scan never ran"
    // (e.g. loopback jumpers missing so trace_clk is dead and the FSM,
    // clocked by trace_clk, never advances).
    // ------------------------------------------------------------------
    assign rd_data = ~scan_done           ? 8'hFF :
                     (rd_addr >= 8'd132 && rd_addr <= 8'd163) ? raw_buf[rd_addr - 8'd132] :
                     (rd_addr >= 8'd164 && rd_addr <= 8'd195) ? snap_d2[rd_addr - 8'd164] :
                     (rd_addr >= 8'd196 && rd_addr <= 8'd227) ? snap_d1[rd_addr - 8'd196] :
                     (rd_addr <= 8'd131)  ? table_mem[rd_addr] :
                                            8'h00;

endmodule

`default_nettype wire
