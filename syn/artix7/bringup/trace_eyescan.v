// trace_eyescan  (V1, orbtrace-aligned)
// =====================================
// Stage-4 V1: FPGA self-loopback eye-scan of the source-synchronous DDR
// trace capture path, NO STM32. Unlike the first cut (a home-grown +1-ramp
// bit checker that tripped over DDR rising/falling phase), this version uses
// orbtrace's OWN alignment mechanism as the validity judge:
//
//   pattern gen emits a real TPIU frame  (FF FF FF 7F sync + 16 payload bytes)
//        |  DDR-serialized over 4 lanes (low nibble on rising, high on falling)
//        v
//   txclk_out/txd_out --(board jumper)--> trace_clk_in/trace_data_in
//        v
//   trace_capture_a7 (IDELAYE2 + IDDR)  -> trace_a/trace_b
//        v
//   traceIF.v (UPSTREAM, sim-proven)    -> FrAvail toggles + Frame
//
// traceIF locks onto the 0x7FFF_FFFF sync word and tracks rising/falling
// edge alignment itself (its isREsync flag), so we do NOT have to reason
// about IDDR Q1/Q2 phase. A tap is "in the eye" iff, at that IDELAY tap,
// traceIF produces frames whose value == the known golden frame.
//
// This module: pattern generator + tap-sweep FSM + per-tap good/bad frame
// tally (judged from the traceIF FrAvail/Frame brought in from the top) +
// results table read out over UDP.
//
// Domains: clk_tx launches the pattern; trace_clk is the recovered clock
// (traceIF + this FSM run on it). Same physical clock through the jumper.

`default_nettype none

module trace_eyescan #(
    parameter WIN_BITS = 18,                  // frames-counting window per tap
    parameter [127:0] GOLDEN = 128'h123402030405060708090a0b0c0d0e0f
) (
    input  wire        rst,

    // pattern launch clock
    input  wire        clk_tx,

    // loopback OUTPUT pins (jumper to trace_*_in)
    output wire        txclk_out,
    output wire [3:0]  txd_out,

    // IDELAY tap control to trace_capture_a7
    output reg  [4:0]  tap,
    output reg         tap_load,
    input  wire        idelayctrl_rdy,

    // decoded frame status from the traceIF instance in the top (trace_clk)
    input  wire        trace_clk,
    input  wire        fr_avail,             // toggles once per decoded frame
    input  wire [127:0] frame,

    // results-table read port (combinational). 132 bytes:
    //   tap*4 + lane?  -> here we store per-tap: [good_lo,good_hi,bad_lo,bad_hi]
    //   addr = tap*4 + {0:good[7:0],1:good[15:8],2:bad[7:0],3:bad[15:8]}
    //   128 = best_tap, 129 = {eye_found,scan_done,..}, 130/131 = reserved
    input  wire [7:0]  rd_addr,
    output wire [7:0]  rd_data,

    output reg         scan_done,
    output reg  [4:0]  best_tap,
    output reg         eye_found
);

    // ==================================================================
    // Pattern generator (clk_tx): repeatedly send a TPIU frame as DDR bytes.
    // Byte map (matches trace_capture_a7_tb.sendByte): low nibble on rising
    // edge (ODDR D1), high nibble on falling edge (ODDR D2).
    // Frame bytes: 4 sync (ff ff ff 7f) + 16 payload, then repeat. We also
    // insert a couple of 0x00 bytes between repeats as inter-frame gap.
    // ==================================================================
    localparam NBYTES = 4 + 16 + 2;   // sync + payload + gap
    reg [7:0] pat_rom [0:NBYTES-1];
    initial begin
        pat_rom[0]=8'hff; pat_rom[1]=8'hff; pat_rom[2]=8'hff; pat_rom[3]=8'h7f;
        pat_rom[4]=8'h12;  pat_rom[5]=8'h34;  pat_rom[6]=8'h02;  pat_rom[7]=8'h03;
        pat_rom[8]=8'h04;  pat_rom[9]=8'h05;  pat_rom[10]=8'h06; pat_rom[11]=8'h07;
        pat_rom[12]=8'h08; pat_rom[13]=8'h09; pat_rom[14]=8'h0a; pat_rom[15]=8'h0b;
        pat_rom[16]=8'h0c; pat_rom[17]=8'h0d; pat_rom[18]=8'h0e; pat_rom[19]=8'h0f;
        pat_rom[20]=8'h00; pat_rom[21]=8'h00;
    end

    reg [4:0] pat_idx;
    reg [7:0] pat_byte;
    always @(posedge clk_tx) begin
        if (rst) begin
            pat_idx  <= 5'd0;
            pat_byte <= 8'hff;
        end else begin
            pat_byte <= pat_rom[pat_idx];
            if (pat_idx == NBYTES-1) pat_idx <= 5'd0;
            else                     pat_idx <= pat_idx + 5'd1;
        end
    end

    // clock copy
    ODDR #(.DDR_CLK_EDGE("SAME_EDGE"), .SRTYPE("ASYNC"))
    u_oddr_clk (.Q(txclk_out), .C(clk_tx), .CE(1'b1),
                .D1(1'b1), .D2(1'b0), .R(1'b0), .S(1'b0));

    // 4 data lanes: lane i carries byte bit i (rising/D1) and bit 4+i (falling/D2)
    genvar i;
    generate
        for (i = 0; i < 4; i = i + 1) begin : g_txd
            ODDR #(.DDR_CLK_EDGE("SAME_EDGE"), .SRTYPE("ASYNC"))
            u_oddr_d (.Q(txd_out[i]), .C(clk_tx), .CE(1'b1),
                      .D1(pat_byte[i]), .D2(pat_byte[4+i]), .R(1'b0), .S(1'b0));
        end
    endgenerate

    // ==================================================================
    // Frame validity (trace_clk): detect FrAvail toggle, compare Frame.
    // ==================================================================
    reg fr_q;
    wire frame_strobe = fr_avail ^ fr_q;
    always @(posedge trace_clk) fr_q <= fr_avail;
    wire frame_good = frame_strobe & (frame == GOLDEN);
    wire frame_bad  = frame_strobe & (frame != GOLDEN);

    // ==================================================================
    // Scan FSM (trace_clk): per tap, load, settle, count good/bad frames
    // over a window, store, pick the tap with most good (and 0 bad).
    // ==================================================================
    localparam S_IDLE=0, S_LOAD=1, S_SETTLE=2, S_COUNT=3, S_STORE=4, S_NEXT=5, S_DONE=6;
    reg [2:0]  st;
    reg [4:0]  cur_tap;
    reg [WIN_BITS-1:0] win;
    reg [9:0]  settle;
    reg [15:0] good_cnt, bad_cnt;
    reg [15:0] best_good;

    (* ram_style = "distributed" *)
    reg [7:0] table_mem [0:131];

    // capture the most-recent decoded frame so the PC can see the ACTUAL
    // golden value (the byte order through DDR+traceIF may differ from the
    // naive expectation). Stored at table addr 132..147 after scan_done.
    reg [127:0] last_frame;
    always @(posedge trace_clk)
        if (frame_strobe) last_frame <= frame;

    always @(posedge trace_clk) begin
        if (rst) begin
            st        <= S_IDLE;
            cur_tap   <= 5'd0;
            tap       <= 5'd0;
            tap_load  <= 1'b0;
            scan_done <= 1'b0;
            best_tap  <= 5'd0;
            best_good <= 16'd0;
            eye_found <= 1'b0;
            good_cnt  <= 16'd0;
            bad_cnt   <= 16'd0;
            win       <= {WIN_BITS{1'b0}};
            settle    <= 10'd0;
        end else begin
            tap_load <= 1'b0;
            case (st)
                S_IDLE: begin
                    if (idelayctrl_rdy) begin
                        cur_tap   <= 5'd0;
                        tap       <= 5'd0;
                        best_good <= 16'd0;
                        eye_found <= 1'b0;
                        scan_done <= 1'b0;
                        st        <= S_LOAD;
                    end
                end
                S_LOAD: begin
                    tap      <= cur_tap;
                    tap_load <= 1'b1;
                    settle   <= 10'd0;
                    good_cnt <= 16'd0;
                    bad_cnt  <= 16'd0;
                    st       <= S_SETTLE;
                end
                S_SETTLE: begin
                    settle <= settle + 10'd1;
                    if (settle == 10'd511) begin
                        win <= {WIN_BITS{1'b0}};
                        st  <= S_COUNT;
                    end
                end
                S_COUNT: begin
                    win <= win + 1'b1;
                    if (frame_good && good_cnt != 16'hFFFF) good_cnt <= good_cnt + 16'd1;
                    if (frame_bad  && bad_cnt  != 16'hFFFF) bad_cnt  <= bad_cnt  + 16'd1;
                    if (win == {WIN_BITS{1'b1}}) st <= S_STORE;
                end
                S_STORE: begin
                    table_mem[{cur_tap,2'd0}]      <= good_cnt[7:0];
                    table_mem[{cur_tap,2'd0}|8'd1] <= good_cnt[15:8];
                    table_mem[{cur_tap,2'd0}|8'd2] <= bad_cnt[7:0];
                    table_mem[{cur_tap,2'd0}|8'd3] <= bad_cnt[15:8];
                    // best tap = most good frames with zero bad frames
                    if (bad_cnt == 16'd0 && good_cnt > best_good) begin
                        best_good <= good_cnt;
                        best_tap  <= cur_tap;
                        eye_found <= 1'b1;
                    end
                    st <= S_NEXT;
                end
                S_NEXT: begin
                    if (cur_tap == 5'd31) st <= S_DONE;
                    else begin cur_tap <= cur_tap + 5'd1; st <= S_LOAD; end
                end
                S_DONE: begin
                    scan_done      <= 1'b1;
                    table_mem[128] <= {3'b0, best_tap};
                    table_mem[129] <= {eye_found, scan_done, 6'b0};
                    tap            <= best_tap;   // park at best
                    tap_load       <= 1'b1;
                    st             <= S_DONE;
                end
            endcase
        end
    end

    assign rd_data = ~scan_done ? 8'hFF :
                     (rd_addr <= 8'd131) ? table_mem[rd_addr] :
                     (rd_addr >= 8'd132 && rd_addr <= 8'd147) ?
                         last_frame[8*(8'd147 - rd_addr) +: 8] : 8'h00;

endmodule

`default_nettype wire
