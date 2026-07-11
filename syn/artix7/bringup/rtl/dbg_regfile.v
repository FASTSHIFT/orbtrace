// dbg_regfile.v
// =============
// Observability register file (proposal 30, P1). Aggregates internal FSM
// state, error pulses and counters into a byte-addressable read-only register
// bank, exposed to the host over the existing :5001 readout path (which is
// independent of the self-TX data stream -- it survives the very deadlock we
// need to diagnose).
//
// Design principles (industry practice):
//   * STICKY FIRST-ERROR: latch the FIRST error code seen and the free-running
//     cycle count at that moment. Root cause is usually the first fault; later
//     faults are avalanche. Cleared only by reset or an explicit clear pulse.
//   * FREE-RUNNING CYCLE COUNTER as a timestamp base.
//   * PER-SOURCE COUNTERS so intermittent faults are still visible after the
//     event.
//   * LIVE STATE readout (FSM state, FIFO occupancy, lock/activity) for
//     "what's happening right now".
//
// 16-bit error codes: [15:12]=module id, [11:0]=error number (proposal 30 3.2)
//   0x101 no TRACECLK edges     0x102 trace MMCM unlocked
//   0x301 capture FIFO overflow
//   0x401 self-TX HDR stuck (ARP deadlock)
//   0x501 RX bad frame          0x502 TX FIFO overflow   0x503 RX FIFO overflow
//
// All inputs are level/pulse signals in `clk` (125 MHz) domain. Callers must
// CDC anything from other clocks before wiring here (e.g. lost_cnt).

`default_nettype none

module dbg_regfile (
    input  wire        clk,          // 125 MHz
    input  wire        rst,

    // ---- clear (optional): pulse to clear sticky error + counters ----
    input  wire        clr,

    // ---- error pulse inputs (1-cycle strobes, clk domain) ----
    input  wire        e_no_traceclk,     // 0x101
    input  wire        e_mmcm_unlock,     // 0x102
    input  wire        e_cap_overflow,    // 0x301
    input  wire        e_selftx_stuck,    // 0x401
    input  wire        e_rx_bad_frame,    // 0x501
    input  wire        e_tx_fifo_ovf,     // 0x502
    input  wire        e_rx_fifo_ovf,     // 0x503

    // ---- live state inputs ----
    input  wire        sys_mmcm_locked,
    input  wire        trace_mmcm_locked,
    input  wire        traceclk_active,   // TRACECLK had edges recently
    input  wire [1:0]  selftx_state,      // 0=IDLE 1=HDR 2=SEND 3=BACKOFF
    input  wire        pkt_active,
    input  wire [31:0] lost_cnt,          // capture FIFO drop counter (CDC'd)

    // ---- byte read port (drives the :5001 status_byte mux) ----
    input  wire [7:0]  addr,              // low byte of ext_addr (page 0xFFxx)
    output reg  [7:0]  rdata
);

    // ---- free-running cycle counter (timestamp base) ----
    reg [31:0] cyc;
    always @(posedge clk) begin
        if (rst) cyc <= 32'd0;
        else     cyc <= cyc + 32'd1;
    end

    // ---- combine error pulses into a prioritised current code ----
    // Priority: first listed wins if several fire same cycle (root-cause order:
    // physical-in -> capture -> egress).
    reg [15:0] cur_code;
    reg        cur_any;
    always @(*) begin
        cur_any  = 1'b1;
        if      (e_no_traceclk)  cur_code = 16'h0101;
        else if (e_mmcm_unlock)  cur_code = 16'h0102;
        else if (e_cap_overflow) cur_code = 16'h0301;
        else if (e_selftx_stuck) cur_code = 16'h0401;
        else if (e_rx_bad_frame) cur_code = 16'h0501;
        else if (e_tx_fifo_ovf)  cur_code = 16'h0502;
        else if (e_rx_fifo_ovf)  cur_code = 16'h0503;
        else begin cur_code = 16'h0000; cur_any = 1'b0; end
    end

    // ---- sticky first-error latch + timestamp + context ----
    reg [15:0] first_code;
    reg [31:0] first_time;
    reg [7:0]  first_ctx;      // context snapshot at first error
    reg        have_first;
    always @(posedge clk) begin
        if (rst || clr) begin
            first_code <= 16'h0000;
            first_time <= 32'd0;
            first_ctx  <= 8'd0;
            have_first <= 1'b0;
        end else if (cur_any && !have_first) begin
            have_first <= 1'b1;
            first_code <= cur_code;
            first_time <= cyc;
            // context: selftx state + lock bits at the moment of first fault
            first_ctx  <= {trace_mmcm_locked, sys_mmcm_locked, traceclk_active,
                           pkt_active, 2'b00, selftx_state};
        end
    end

    // ---- per-source saturating counters (8-bit each) ----
    reg [7:0] c_no_traceclk, c_mmcm_unlock, c_cap_overflow, c_selftx_stuck;
    reg [7:0] c_rx_bad_frame, c_tx_fifo_ovf, c_rx_fifo_ovf;
    task automatic inc; inout [7:0] c; input p; begin
        if (p && !(&c)) c = c + 8'd1;
    end endtask
    always @(posedge clk) begin
        if (rst || clr) begin
            c_no_traceclk<=0; c_mmcm_unlock<=0; c_cap_overflow<=0; c_selftx_stuck<=0;
            c_rx_bad_frame<=0; c_tx_fifo_ovf<=0; c_rx_fifo_ovf<=0;
        end else begin
            inc(c_no_traceclk,  e_no_traceclk);
            inc(c_mmcm_unlock,  e_mmcm_unlock);
            inc(c_cap_overflow, e_cap_overflow);
            inc(c_selftx_stuck, e_selftx_stuck);
            inc(c_rx_bad_frame, e_rx_bad_frame);
            inc(c_tx_fifo_ovf,  e_tx_fifo_ovf);
            inc(c_rx_fifo_ovf,  e_rx_fifo_ovf);
        end
    end

    // ---- live status byte ----
    wire [7:0] live_status = {have_first, pkt_active, traceclk_active,
                              trace_mmcm_locked, sys_mmcm_locked, 1'b0,
                              selftx_state};

    // ---- register read mux (addr = low byte of ext_addr, page 0xFF1x..0xFF3x)
    // 0x10 DBG_MAGIC   0x11 live_status
    // 0x12 cyc[7:0] .. 0x15 cyc[31:24]
    // 0x16 first_code[7:0] 0x17 first_code[15:8]
    // 0x18 first_time[7:0]..0x1B first_time[31:24]
    // 0x1C first_ctx
    // 0x20..0x26 per-source counters
    always @(*) begin
        case (addr)
            8'h10: rdata = 8'hDB;                 // MAGIC: debug regfile v1
            8'h11: rdata = live_status;
            8'h12: rdata = cyc[7:0];
            8'h13: rdata = cyc[15:8];
            8'h14: rdata = cyc[23:16];
            8'h15: rdata = cyc[31:24];
            8'h16: rdata = first_code[7:0];
            8'h17: rdata = first_code[15:8];
            8'h18: rdata = first_time[7:0];
            8'h19: rdata = first_time[15:8];
            8'h1A: rdata = first_time[23:16];
            8'h1B: rdata = first_time[31:24];
            8'h1C: rdata = first_ctx;
            8'h20: rdata = c_no_traceclk;
            8'h21: rdata = c_mmcm_unlock;
            8'h22: rdata = c_cap_overflow;
            8'h23: rdata = c_selftx_stuck;
            8'h24: rdata = c_rx_bad_frame;
            8'h25: rdata = c_tx_fifo_ovf;
            8'h26: rdata = c_rx_fifo_ovf;
            default: rdata = 8'h00;
        endcase
    end

endmodule

`default_nettype wire
