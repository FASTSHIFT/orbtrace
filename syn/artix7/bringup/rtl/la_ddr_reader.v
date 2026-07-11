// la_ddr_reader
// =============
// Proposal 32 P2b-2: read the DDR3 black-box ring back out to the host. On an
// arm pulse (CSR), read N 128-bit words starting at RING_BASE via the vendor
// ddr3_rd_ctrl, unpack big-endian to a byte stream, cross into clk125 through
// an AsyncFIFO, and present it on an AXIS-style byte source for the
// fpga_core_net self-TX path (-> UDP). One-shot per arm.
//
//   arm(clk125) --sync--> ui_clk: issue ddr3_rd_start bursts (LENGTH words)
//   until total_words read; each 128-bit word -> 16 bytes (byte0=MS) -> FIFO
//   (ui_clk -> clk125) -> stream_tdata/stream_tvalid (host pulls at tready).
//
// Kept independent from la_ddr_writer (separate rd path of ddr3_ctrl); the
// host arms readback after stopping the trace source, so the ring is static
// during read (clean snapshot).

`default_nettype none

module la_ddr_reader #(
    parameter integer LENGTH    = 64,
    parameter [28:0]  RING_BASE = 29'd0
) (
    // ---- control (clk125) ----
    input  wire        clk125,
    input  wire        sys_rst,
    input  wire        arm,             // 1-cyc pulse: start a readback
    input  wire [31:0] read_words,      // number of 128-bit words to read back

    // ---- DDR3 read interface (ui_clk), drives ddr3_ctrl ----
    input  wire        ui_clk,
    input  wire        ui_rst,
    output reg         ddr3_rd_start,
    input  wire        ddr3_rd_addr_req,
    output reg  [28:0] ddr3_rd_addr,
    input  wire        ddr3_rd_data_vld,
    input  wire [127:0]ddr3_rd_data,
    input  wire        ddr3_rd_done,

    // ---- byte stream out (clk125) to fpga_core_net self-TX ----
    output wire [7:0]  stream_tdata,
    output wire        stream_tvalid,
    input  wire        stream_tready,
    output reg         busy,           // high while a readback is in flight
    // observability (clk125): reader FSM state + words remaining + total done
    output reg  [1:0]  dbg_state,
    output reg  [31:0] dbg_words_left,
    output reg  [31:0] dbg_words_done
);
    // ---- arm pulse CDC clk125 -> ui_clk ----
    reg arm_tog = 0;
    always @(posedge clk125) if (arm) arm_tog <= ~arm_tog;
    reg a0=0,a1=0,a2=0;
    always @(posedge ui_clk) begin a0<=arm_tog; a1<=a0; a2<=a1; end
    wire arm_ui = a1 ^ a2;
    // read_words CDC: latched stable well before arm edge (host writes it first)
    reg [31:0] rw_s0=0, rw_ui=0;
    always @(posedge ui_clk) begin rw_s0<=read_words; rw_ui<=rw_s0; end

    // ---- ui_clk read FSM: issue LENGTH-word bursts until rw_ui words read ----
    localparam R_IDLE=0, R_START=1, R_RUN=2, R_NEXT=3;
    reg [1:0]  rst_state = R_IDLE;
    reg [31:0] words_left = 0;

    // Each ddr3_rd_data_vld delivers ONE 128-bit word, back-to-back within a
    // burst. We must NOT spend 16 cycles unpacking (that drops 15 of every 16
    // words). Instead push the full 128-bit word into a WIDE AsyncFIFO in one
    // cycle; the clk125 read side gears it down to bytes. DDR3 read bandwidth
    // (one 128-bit word / ui_clk) >> the byte egress, and the wide FIFO (2K
    // words deep) + burst pacing absorb it.
    wire        f_wr_ready;
    reg         f_wr_valid;
    reg  [127:0]f_wr_data;

    always @(posedge ui_clk) begin
        if (ui_rst) begin
            rst_state <= R_IDLE; ddr3_rd_start <= 0; ddr3_rd_addr <= RING_BASE;
            words_left <= 0; f_wr_valid <= 0;
        end else begin
            ddr3_rd_start <= 1'b0;
            f_wr_valid    <= 1'b0;
            case (rst_state)
                R_IDLE:
                    if (arm_ui) begin
                        ddr3_rd_addr <= RING_BASE;
                        words_left   <= rw_ui;
                        rst_state    <= R_START;
                    end
                R_START:
                    // Launch a burst only when the FIFO has room for a WHOLE
                    // unpauseable LENGTH-word MIG burst (2*LENGTH margin). This
                    // throttles the reader to the (slow) network egress so the
                    // FIFO never overflows — the fix for the ~590-packet cap.
                    if (fifo_has_room) begin
                        ddr3_rd_start <= 1'b1;
                        rst_state <= R_RUN;
                    end
                R_RUN: begin
                    if (ddr3_rd_data_vld) begin
                        f_wr_data  <= ddr3_rd_data;   // whole word, one cycle
                        f_wr_valid <= 1'b1;
                    end
                    if (ddr3_rd_done) rst_state <= R_NEXT;
                end
                R_NEXT: begin
                    if (words_left <= LENGTH) begin
                        rst_state <= R_IDLE;    // done
                    end else begin
                        words_left <= words_left - LENGTH;
                        ddr3_rd_addr <= ddr3_rd_addr + LENGTH;
                        rst_state <= R_START;
                    end
                end
            endcase
        end
    end

    // words actually delivered into the FIFO (ui_clk)
    reg [31:0] words_done = 0;
    always @(posedge ui_clk) begin
        if (ui_rst) words_done <= 0;
        else if (arm_ui) words_done <= 0;
        else if (f_wr_valid) words_done <= words_done + 1'b1;
    end

    // busy flag + observability (ui_clk) synced to clk125
    reg busy_ui;
    always @(posedge ui_clk) busy_ui <= (rst_state != R_IDLE);
    reg b0=0,b1=0;
    reg [1:0]  st_s0=0;
    reg [31:0] wl_s0=0, wd_s0=0;
    always @(posedge clk125) begin
        b0<=busy_ui; b1<=b0; busy<=b1;
        st_s0 <= rst_state;      dbg_state      <= st_s0;
        wl_s0 <= words_left;     dbg_words_left <= wl_s0;
        wd_s0 <= words_done;     dbg_words_done <= wd_s0;
    end

    // ---- AsyncFIFO ui_clk -> clk125 (128-bit wide) ----
    // DEPTH is in BYTES; 128-bit words = 16 bytes each. 512 words = 8KB holds
    // 8 read bursts (64 words) — plenty, and fits BRAM budget alongside the
    // writer's staging + Ethernet FIFOs.
    localparam integer FIFO_WORDS = 512;
    wire [127:0] m_word;
    wire         m_valid, m_ready;
    wire [$clog2(FIFO_WORDS):0] s_depth;
    // free space for a whole burst? gate the reader so a 64-word MIG burst
    // (unpauseable) never overflows the FIFO — the earlier version read at
    // DDR3 speed (800MB/s) into a FIFO drained at 1Gb/s (~12.5MB/s), so it
    // overflowed and only the first ~590 packets survived.
    wire        fifo_has_room = (s_depth < (FIFO_WORDS - 2*LENGTH));
    axis_async_fifo #(
        .DEPTH(FIFO_WORDS), .DATA_WIDTH(128),
        .KEEP_ENABLE(0), .LAST_ENABLE(0), .USER_ENABLE(0), .FRAME_FIFO(0)
    ) u_rfifo (
        .s_clk(ui_clk), .s_rst(ui_rst),
        .s_axis_tdata(f_wr_data), .s_axis_tkeep(16'h0),
        .s_axis_tvalid(f_wr_valid), .s_axis_tready(f_wr_ready),
        .s_axis_tlast(1'b0), .s_axis_tid(8'h0), .s_axis_tdest(8'h0), .s_axis_tuser(1'b0),
        .m_clk(clk125), .m_rst(sys_rst),
        .m_axis_tdata(m_word), .m_axis_tkeep(),
        .m_axis_tvalid(m_valid), .m_axis_tready(m_ready),
        .m_axis_tlast(), .m_axis_tid(), .m_axis_tdest(), .m_axis_tuser(),
        .s_pause_req(1'b0), .s_pause_ack(), .m_pause_req(1'b0), .m_pause_ack(),
        .s_status_depth(s_depth), .s_status_depth_commit(), .s_status_overflow(),
        .s_status_bad_frame(), .s_status_good_frame(),
        .m_status_depth(), .m_status_depth_commit(), .m_status_overflow(),
        .m_status_bad_frame(), .m_status_good_frame()
    );

    // ---- clk125 gearbox: 128-bit word -> 16 bytes (big-endian, byte0=MS) ----
    reg  [127:0] gb_word = 0;
    reg  [4:0]   gb_cnt  = 0;      // 16 -> empty, else bytes remaining
    wire         gb_empty = (gb_cnt == 0);
    assign m_ready       = gb_empty;                 // load next word when empty
    assign stream_tvalid = ~gb_empty;
    assign stream_tdata  = gb_word[127:120];
    always @(posedge clk125) begin
        if (sys_rst) begin
            gb_cnt <= 0; gb_word <= 0;
        end else if (gb_empty) begin
            if (m_valid) begin gb_word <= m_word; gb_cnt <= 5'd16; end
        end else if (stream_tready) begin
            gb_word <= {gb_word[119:0], 8'h00};
            gb_cnt  <= gb_cnt - 1'b1;
        end
    end

endmodule

`default_nettype wire
