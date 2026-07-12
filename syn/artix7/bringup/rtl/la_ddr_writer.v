// la_ddr_writer
// =============
// Proposal 32 P2b (method X): on-chip logic-analyzer BLACK BOX writer. Takes
// the raw trace bytes tapped DIRECTLY at the capture source (trace_capture_
// direct.cap_byte, in the TRACECLK domain) and records them into DDR3 through
// an INDEPENDENT AsyncFIFO — separate from the real-time UDP path — so the
// black box is an untainted ground-truth copy for decoder cross-check.
//
//   cap_byte/cap_valid (TRACECLK)                          ui_clk (50MHz, MIG)
//        │                                                      │
//        └─► AsyncFIFO (8-bit, TRACECLK→ui_clk) ─► pack 16 bytes ─► 128-bit
//            words ─► on every 64 words (=1KB), issue one ddr3_wr_start burst
//            to a ring address; wrap at RING_WORDS.
//
// Byte packing: cap_byte[k] is placed big-endian into the 128-bit word, byte 0
// = MS byte, so the host reads back a contiguous byte stream identical to the
// tapped order. Loss accounting: if the AsyncFIFO fills (DDR3 write can't keep
// up — should never happen at 12.8MB/s in vs 800MB/s DDR3, but we count it),
// wr_lost increments.
//
// This module does NOT read back; la_ddr_reader (P2b-2) streams the ring out
// over :5556. Here we expose write pointer + byte count + overflow for :5001.

`default_nettype none

module la_ddr_writer #(
    parameter integer LENGTH     = 64,          // 128-bit words per DDR3 burst
                                                // (must match ddr3_wr_ctrl)
    parameter [28:0]  RING_BASE  = 29'd0,       // ring start (app word address)
    parameter [28:0]  RING_WORDS = 29'd0100000  // ring size in 128-bit words
                                                // (0x100000 = 1M words = 16MB)
) (
    // ---- capture-source side (TRACECLK domain) ----
    input  wire        cap_clk,
    input  wire        cap_rst,
    input  wire [7:0]  cap_byte,
    input  wire        cap_valid_in,    // raw capture valid
    input  wire        freeze,          // when 1, stop accepting new bytes
                                        // (clk125-domain level; static ring for
                                        // a clean readback snapshot)

    // ---- DDR3 side (ui_clk domain), drives ddr3_ctrl write interface ----
    input  wire        ui_clk,
    input  wire        ui_rst,
    input  wire        ddr3_busy,       // arbiter busy (from ddr3_ctrl)
    output reg         ddr3_wr_start,
    input  wire        ddr3_wr_data_req,
    output wire [127:0]ddr3_wr_data,
    input  wire        ddr3_wr_addr_req,
    output reg  [28:0] ddr3_wr_addr,
    input  wire        ddr3_wr_done,

    // ---- status (ui_clk domain) ----
    output reg  [28:0] wr_ptr_words,    // current ring write pointer (words)
    output reg  [31:0] words_written,   // total 128-bit words committed
    output reg  [31:0] wr_lost_bytes    // bytes dropped (AsyncFIFO full)
);
    // ---------------- AsyncFIFO: cap_clk 8-bit -> ui_clk 8-bit ----------------
    // Independent CDC FIFO (method X): the black box taps cap_byte at the
    // source, never sharing the real-time path's FIFO. Depth 4096 absorbs DDR3
    // arbitration latency. Loss = a cap_valid byte arriving while the FIFO is
    // not ready (should not happen: 12.8MB/s in vs 800MB/s DDR3 out).
    // freeze (clk125 level) synced into cap_clk; gate capture bytes off while a
    // readback is in flight so the ring is a static snapshot.
    reg frz0=0, frz1=0;
    always @(posedge cap_clk) begin frz0<=freeze; frz1<=frz0; end
    wire cap_valid = cap_valid_in & ~frz1;

    wire       fifo_s_ready;
    wire [7:0] fifo_out_data;
    wire       fifo_out_valid, fifo_out_ready;
    axis_async_fifo #(
        .DEPTH(4096), .DATA_WIDTH(8),
        .KEEP_ENABLE(0), .LAST_ENABLE(0), .USER_ENABLE(0), .FRAME_FIFO(0)
    ) u_afifo (
        .s_clk(cap_clk), .s_rst(cap_rst),
        .s_axis_tdata(cap_byte), .s_axis_tkeep(1'b0),
        .s_axis_tvalid(cap_valid), .s_axis_tready(fifo_s_ready),
        .s_axis_tlast(1'b0), .s_axis_tid(8'h0), .s_axis_tdest(8'h0), .s_axis_tuser(1'b0),
        .m_clk(ui_clk), .m_rst(ui_rst),
        .m_axis_tdata(fifo_out_data), .m_axis_tkeep(),
        .m_axis_tvalid(fifo_out_valid), .m_axis_tready(fifo_out_ready),
        .m_axis_tlast(), .m_axis_tid(), .m_axis_tdest(), .m_axis_tuser(),
        .s_pause_req(1'b0), .s_pause_ack(), .m_pause_req(1'b0), .m_pause_ack(),
        .s_status_depth(), .s_status_depth_commit(), .s_status_overflow(),
        .s_status_bad_frame(), .s_status_good_frame(),
        .m_status_depth(), .m_status_depth_commit(), .m_status_overflow(),
        .m_status_bad_frame(), .m_status_good_frame()
    );

    // capture-domain loss counter (cap_valid while FIFO can't accept), CDC'd up
    reg [31:0] lost_cap = 0;
    always @(posedge cap_clk or posedge cap_rst) begin
        if (cap_rst) lost_cap <= 0;
        else if (cap_valid & ~fifo_s_ready) lost_cap <= lost_cap + 1'b1;
    end
    reg [31:0] lost_s0=0, lost_s1=0;
    always @(posedge ui_clk) begin
        lost_s0 <= lost_cap; lost_s1 <= lost_s0; wr_lost_bytes <= lost_s1;
    end

    // ---------------- ui_clk: pack 16 bytes -> 128-bit word ----------------
    reg [127:0] word_sr = 0;     // shift register building the 128-bit word
    reg [3:0]   byte_idx = 0;    // 0..15 within the current word
    reg [127:0] wbuf [0:LENGTH-1]; // one burst of 64 words staged for DDR3
    reg [9:0]   word_idx = 0;    // 0..LENGTH-1 words staged
    reg         burst_ready = 0; // a full LENGTH-word batch is staged
    reg         burst_done = 0;  // pulse when a DDR3 burst completes (FSM below)

    // pop the FIFO whenever we're not mid-burst-commit and a byte is available
    assign fifo_out_ready = fifo_out_valid & ~burst_ready & ~ui_rst;

    always @(posedge ui_clk) begin
        if (ui_rst) begin
            byte_idx <= 0; word_idx <= 0; burst_ready <= 0; word_sr <= 0;
        end else begin
            if (fifo_out_valid & fifo_out_ready) begin
                // big-endian byte pack: first byte -> MS byte
                word_sr <= {word_sr[119:0], fifo_out_data};
                if (byte_idx == 4'd15) begin
                    byte_idx <= 0;
                    wbuf[word_idx] <= {word_sr[119:0], fifo_out_data};
                    if (word_idx == LENGTH-1) begin
                        word_idx <= 0;
                        burst_ready <= 1'b1;   // batch staged; trigger DDR3 write
                    end else begin
                        word_idx <= word_idx + 1'b1;
                    end
                end else begin
                    byte_idx <= byte_idx + 1'b1;
                end
            end
            if (burst_done) burst_ready <= 1'b0;   // clear once written
        end
    end

    // ---------------- ui_clk: DDR3 write-burst FSM ----------------
    // On burst_ready, pulse ddr3_wr_start; feed wbuf[] words on ddr3_wr_data_req;
    // advance ring address on wr_done.
    localparam W_IDLE=0, W_START=1, W_RUN=2, W_DONE=3;
    reg [1:0] wst = W_IDLE;
    reg [9:0] out_idx = 0;

    assign ddr3_wr_data = wbuf[out_idx];

    always @(posedge ui_clk) begin
        if (ui_rst) begin
            wst <= W_IDLE; ddr3_wr_start <= 0; out_idx <= 0; burst_done <= 0;
            ddr3_wr_addr <= RING_BASE; wr_ptr_words <= RING_BASE;
            words_written <= 0;
        end else begin
            ddr3_wr_start <= 1'b0;
            burst_done    <= 1'b0;
            case (wst)
                W_IDLE:
                    if (burst_ready) begin
                        ddr3_wr_addr <= wr_ptr_words;
                        ddr3_wr_start <= 1'b1;
                        out_idx <= 0;
                        wst <= W_START;
                    end
                W_START: wst <= W_RUN;   // let wr_ctrl accept the start
                W_RUN: begin
                    if (ddr3_wr_data_req) begin
                        if (out_idx == LENGTH-1) out_idx <= 0;
                        else out_idx <= out_idx + 1'b1;
                    end
                    // CRITICAL: the vendor ddr3_wr_ctrl passes app_addr =
                    // ddr3_wr_addr through unchanged and issues LENGTH commands;
                    // the DATA SOURCE must advance the address +8 per app
                    // command (4:1 PHY, one 128-bit UI word = 8 DDR3 column
                    // addrs) like ddr3_generate_data. Holding it constant made
                    // all 64 words of a burst hit the SAME address -> readback
                    // was the last word repeated 64x (period-16 duplication).
                    if (ddr3_wr_addr_req)
                        ddr3_wr_addr <= ddr3_wr_addr + 29'd8;
                    if (ddr3_wr_done) wst <= W_DONE;
                end
                W_DONE: begin
                    words_written <= words_written + LENGTH;
                    // app address advances +8 per 128-bit word, so a burst
                    // spans LENGTH*8 in app-address units. Advance the ring
                    // write pointer by the SAME amount so bursts are contiguous
                    // and don't overlap.
                    if (wr_ptr_words + (LENGTH<<3) >= RING_BASE + RING_WORDS)
                        wr_ptr_words <= RING_BASE;
                    else
                        wr_ptr_words <= wr_ptr_words + (LENGTH<<3);
                    burst_done <= 1'b1;
                    wst <= W_IDLE;
                end
            endcase
        end
    end

endmodule

`default_nettype wire
