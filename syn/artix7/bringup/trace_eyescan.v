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
    reg  [7:0] rx_prev;
    reg        primed;
    wire [7:0] pred = rx_prev + 8'd1;

    // per-lane mismatch this cycle (lane i owns bit i and bit 4+i)
    wire [3:0] lane_err;
    generate
        for (i = 0; i < 4; i = i + 1) begin : g_chk
            assign lane_err[i] = primed &
                ((trace_a[i] ^ pred[i]) | (trace_b[i] ^ pred[4+i]));
        end
    endgenerate

    // count_en gates accumulation to the measurement window (set by FSM)
    reg count_en;
    reg [15:0] err_cnt [0:3];
    integer L;
    always @(posedge trace_clk) begin
        if (rst) begin
            primed  <= 1'b0;
            rx_prev <= 8'd0;
        end else begin
            rx_prev <= rx_byte;
            primed  <= 1'b1;
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

    // results table: 256 bytes (32 taps * 4 lanes * 2 bytes), simple regs
    (* ram_style = "distributed" *)
    reg [7:0] table_mem [0:255];

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
                    // latch per-lane errors into the table for this tap
                    table_mem[{cur_tap,3'd0}]        <= err_cnt[0][15:8];
                    table_mem[{cur_tap,3'd0}|8'd1]   <= err_cnt[0][7:0];
                    table_mem[{cur_tap,3'd0}|8'd2]   <= err_cnt[1][15:8];
                    table_mem[{cur_tap,3'd0}|8'd3]   <= err_cnt[1][7:0];
                    table_mem[{cur_tap,3'd0}|8'd4]   <= err_cnt[2][15:8];
                    table_mem[{cur_tap,3'd0}|8'd5]   <= err_cnt[2][7:0];
                    table_mem[{cur_tap,3'd0}|8'd6]   <= err_cnt[3][15:8];
                    table_mem[{cur_tap,3'd0}|8'd7]   <= err_cnt[3][7:0];
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
    assign rd_data = scan_done ? table_mem[rd_addr] : 8'hFF;

endmodule

`default_nettype wire
