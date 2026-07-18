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
    parameter integer IN_BYTES   = 1,           // bytes accepted per cap_clk:
                                                // 1 = single-edge 200 MSPS,
                                                // 2 = IDDR dual-edge 400 MSPS
    parameter [28:0]  RING_BASE  = 29'd0,       // ring start (app word address)
    parameter [28:0]  RING_WORDS = 29'd0100000  // ring size in 128-bit words
                                                // (0x100000 = 1M words = 16MB)
) (
    // ---- capture-source side (TRACECLK domain) ----
    input  wire        cap_clk,
    input  wire        cap_rst,
    input  wire [IN_BYTES*8-1:0] cap_byte,      // IN_BYTES samples, byte 0 =
                                                // OLDEST (goes to MS end first)
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
    // ------------- AsyncFIFO: cap_clk 128-bit -> ui_clk 128-bit -------------
    // METHOD X v2 (litescope/OLS-style, WIDTH-MATCHED): the fatal flaw of v1
    // was a THROUGHPUT mismatch, not a flow-control bug. v1 fed the async FIFO
    // 8 bits/cap_clk (200 MB/s) but the ui_clk pack path could only pop 1
    // byte/ui_clk = 100 MB/s (MIG UI = 400MHz DDR3 / 4:1 PHY). A 2:1 permanent
    // overrun => ~half the bytes dropped => the "86% step=2" the canary saw.
    // Simulation (tb_la_ddr_writer) proved this: at matched 100 MB/s v1 still
    // scattered gaps because the pack path ALSO froze during each DDR3 burst.
    //
    // v2 packs 16 bytes into a 128-bit word IN THE cap_clk DOMAIN, then pushes
    // whole words through a 128-bit-wide async FIFO. Now:
    //   * FIFO write rate = 200M/16 = 12.5 Mword/s
    //   * FIFO read rate  = up to 100 Mword/s (one word/ui_clk)
    // an 8:1 drain margin, so steady state NEVER overflows. Loss can only
    // happen on a genuine DDR3 stall, and then it is flagged (sticky) and the
    // byte stream stays contiguous up to the stall point (canary monotonic).
    // Bonus: no per-byte stall gating on the FIFO write port, so the DRC
    // REQP-1839 async-control-on-BRAM warning goes away.
    reg frz0=0, frz1=0;
    always @(posedge cap_clk) begin frz0<=freeze; frz1<=frz0; end

    // cap-domain packer: shift IN_BYTES bytes/cycle into a 128-bit word,
    // big-endian (oldest byte -> MS end first). Completes one word every
    // 16/IN_BYTES cycles. cap_byte is laid out with byte 0 = oldest, so we
    // append {cap_byte} at the LS end each cycle (matching the IN_BYTES=1
    // v2 behaviour of {cap_word[119:0], cap_byte}).
    localparam integer IN_BITS   = IN_BYTES*8;
    localparam integer WORDS_PER = 16/IN_BYTES;         // cap cycles per word
    reg [127:0] cap_word = 0;
    reg [4:0]   cap_bidx = 0;      // counts 0..WORDS_PER-1
    reg         cap_word_valid = 0;   // 1-cycle strobe when a word completes
    // combinational "shift-in this cycle's bytes" result
    wire [127:0] cap_word_next = {cap_word[127-IN_BITS:0], cap_byte};
    always @(posedge cap_clk) begin
        cap_word_valid <= 1'b0;
        if (cap_rst) begin
            cap_bidx <= 0; cap_word <= 0;
        end else if (cap_valid_in & ~frz1) begin
            cap_word <= cap_word_next;
            if (cap_bidx == WORDS_PER-1) begin
                cap_bidx <= 0;
                cap_word_valid <= 1'b1;   // cap_word_next is a complete word
            end else begin
                cap_bidx <= cap_bidx + 1'b1;
            end
        end
    end
    // the completed word value (combinational, valid when cap_word_valid=1)
    wire [127:0] cap_word_full = cap_word_next;

    wire        fifo_s_ready;
    wire [127:0]fifo_out_data;
    wire        fifo_out_valid, fifo_out_ready;
    wire [8:0]  s_depth;   // word occupancy (DEPTH=256 words -> 9b)

    // Overflow = the async FIFO could not accept a completed word (s_ready low)
    // OR neared full. Sticky-latch it in cap domain so the host sees it after.
    reg  overflow_sticky = 0;
    wire near_full = (s_depth > 9'd240);   // ~15/16 of 256 words
    always @(posedge cap_clk or posedge cap_rst) begin
        if (cap_rst) begin
            overflow_sticky <= 0;
        end else if (cap_word_valid & (~fifo_s_ready | near_full)) begin
            overflow_sticky <= 1'b1;   // a word was (or nearly) lost
        end
    end

    axis_async_fifo #(
        .DEPTH(256), .DATA_WIDTH(128),
        .KEEP_ENABLE(0), .LAST_ENABLE(0), .USER_ENABLE(0), .FRAME_FIFO(0)
    ) u_afifo (
        .s_clk(cap_clk), .s_rst(cap_rst),
        .s_axis_tdata(cap_word_full), .s_axis_tkeep(1'b0),
        .s_axis_tvalid(cap_word_valid), .s_axis_tready(fifo_s_ready),
        .s_axis_tlast(1'b0), .s_axis_tid(8'h0), .s_axis_tdest(8'h0), .s_axis_tuser(1'b0),
        .m_clk(ui_clk), .m_rst(ui_rst),
        .m_axis_tdata(fifo_out_data), .m_axis_tkeep(),
        .m_axis_tvalid(fifo_out_valid), .m_axis_tready(fifo_out_ready),
        .m_axis_tlast(), .m_axis_tid(), .m_axis_tdest(), .m_axis_tuser(),
        .s_pause_req(1'b0), .s_pause_ack(), .m_pause_req(1'b0), .m_pause_ack(),
        .s_status_depth(s_depth), .s_status_depth_commit(), .s_status_overflow(),
        .s_status_bad_frame(), .s_status_good_frame(),
        .m_status_depth(), .m_status_depth_commit(), .m_status_overflow(),
        .m_status_bad_frame(), .m_status_good_frame()
    );

    // Overflow flag CDC to ui_clk; expose in wr_lost_bytes (nonzero => the
    // capture stalled at least once, i.e. record has a hard end, not gaps).
    reg ovf_s0=0, ovf_s1=0;
    always @(posedge ui_clk) begin
        ovf_s0 <= overflow_sticky; ovf_s1 <= ovf_s0;
        wr_lost_bytes <= {31'd0, ovf_s1};
    end

    // ---------------- ui_clk: stage 128-bit words into burst buffer ---------
    reg [127:0] wbuf [0:LENGTH-1]; // one burst of LENGTH words staged for DDR3
    reg [9:0]   word_idx = 0;    // 0..LENGTH-1 words staged
    reg         burst_ready = 0; // a full LENGTH-word batch is staged
    reg         burst_done = 0;  // pulse when a DDR3 burst completes (FSM below)

    // pop a word whenever we're not mid-burst-commit and a word is available
    assign fifo_out_ready = fifo_out_valid & ~burst_ready & ~ui_rst;

    always @(posedge ui_clk) begin
        if (ui_rst) begin
            word_idx <= 0; burst_ready <= 0;
        end else begin
            if (fifo_out_valid & fifo_out_ready) begin
                wbuf[word_idx] <= fifo_out_data;
                if (word_idx == LENGTH-1) begin
                    word_idx <= 0;
                    burst_ready <= 1'b1;   // batch staged; trigger DDR3 write
                end else begin
                    word_idx <= word_idx + 1'b1;
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
