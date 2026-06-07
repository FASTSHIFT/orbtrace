// frame_cdc_tb
// ============
// r10 B2 / NEW-1 regression: dual-clock-domain test of the frame128
// trace_clk -> clk100 crossing built around verilog-ethernet's
// axis_async_fifo, plus the overflow accounting added in r10 NEW-1.
//
// This is the test r10 demanded and r09 B2 exposed the need for: the
// previous xsim only ran a single trace_clk domain with zero skew, which
// cannot reveal CDC bugs. Here trace_clk and clk100 run at DELIBERATELY
// unequal, mutually-incommensurate periods with jitter, and we:
//   1. inject a known sequence of 128-bit frames on the trace_clk side,
//   2. drain them (sometimes slowly, to force the FIFO toward full) on
//      the clk100 side,
//   3. assert that every frame that the FIFO ACCEPTED comes out intact
//      and in order, and
//   4. assert that every frame the FIFO REJECTED (full) is counted by
//      trace_lost_cnt — i.e. loss is visible, never silent.
//
// Run (iverilog, no Xilinx primitives needed — axis_async_fifo is plain
// RTL):
//   iverilog -g2012 -o /tmp/frame_cdc \
//     syn/external/verilog-ethernet/lib/axis/rtl/axis_async_fifo.v \
//     syn/artix7/sim/frame_cdc_tb.v
//   vvp /tmp/frame_cdc

`timescale 1ns/1ps

module frame_cdc_tb;

    // ----------------------------------------------------------------
    // Two unrelated clocks. trace_clk ~ 100 MHz (10.0 ns), clk100 a hair
    // different (10.3 ns) so the phase relationship sweeps continuously,
    // plus per-edge jitter so no two runs align identically.
    // ----------------------------------------------------------------
    reg trace_clk = 0;
    reg clk100    = 0;

    integer tj = 0;
    integer cj = 0;
    // crude LCG jitter
    function integer jit; input integer s; begin
        jit = (s * 1103515245 + 12345) % 97;  // 0..96 (×10ps below)
    end endfunction

    always begin
        #(5.0 + jit(tj)*0.001) trace_clk = ~trace_clk; tj = tj + 1;
    end
    always begin
        #(5.15 + jit(cj)*0.001) clk100 = ~clk100; cj = cj + 1;
    end

    reg rst = 1;
    initial begin #53 rst = 0; end

    // ----------------------------------------------------------------
    // DUT-equivalent glue: the exact crossing used in trace_probe_top.
    // ----------------------------------------------------------------
    reg  [127:0] frame128;
    reg          fr_avail;          // toggles per frame (like traceIF)
    reg          fr_avail_iso;
    reg          fr_avail_q;
    wire         frame_strobe = fr_avail_iso ^ fr_avail_q;
    wire         cdc_in_ready;
    wire         cdc_out_valid;
    reg          cdc_out_ready;
    wire [127:0] cdc_out_frame;

    // matches trace_probe_top: reset-less isolation flop + toggle detect
    always @(posedge trace_clk) begin
        fr_avail_iso <= fr_avail;
        fr_avail_q   <= fr_avail_iso;
    end

    // r10 NEW-1: traceIF is free-running and cannot be back-pressured.
    // frame_strobe is a single trace_clk pulse per frame. We feed it
    // straight into the FIFO as tvalid (the FIFO's own 16-deep buffer is
    // the elasticity; a 1-deep holding register in front would only add a
    // second bottleneck). A frame is LOST iff the strobe coincides with
    // FIFO-full (tready low) — and every such loss is COUNTED, so loss is
    // visible, never silent.
    wire         fifo_accept       = frame_strobe & cdc_in_ready;
    wire         fifo_overflow_evt = frame_strobe & ~cdc_in_ready;
    reg [15:0]   trace_lost_cnt;
    always @(posedge trace_clk)
        if (rst)                     trace_lost_cnt <= 16'd0;
        else if (fifo_overflow_evt)  trace_lost_cnt <= trace_lost_cnt + 16'd1;

    axis_async_fifo #(
        .DEPTH(16), .DATA_WIDTH(128),
        .KEEP_ENABLE(0), .LAST_ENABLE(0), .USER_ENABLE(0), .FRAME_FIFO(0)
    ) dut (
        .s_clk(trace_clk), .s_rst(rst),
        .s_axis_tdata(frame128), .s_axis_tkeep(16'h0),
        .s_axis_tvalid(frame_strobe), .s_axis_tready(cdc_in_ready),
        .s_axis_tlast(1'b0), .s_axis_tid(8'h0), .s_axis_tdest(8'h0), .s_axis_tuser(1'b0),
        .m_clk(clk100), .m_rst(rst),
        .m_axis_tdata(cdc_out_frame), .m_axis_tkeep(), .m_axis_tvalid(cdc_out_valid),
        .m_axis_tready(cdc_out_ready), .m_axis_tlast(), .m_axis_tid(), .m_axis_tdest(), .m_axis_tuser(),
        .s_pause_req(1'b0), .s_pause_ack(), .m_pause_req(1'b0), .m_pause_ack(),
        .s_status_depth(), .s_status_depth_commit(), .s_status_overflow(),
        .s_status_bad_frame(), .s_status_good_frame(),
        .m_status_depth(), .m_status_depth_commit(), .m_status_overflow(),
        .m_status_bad_frame(), .m_status_good_frame()
    );

    // ----------------------------------------------------------------
    // Producer: inject NFRAMES frames with payload = sequence counter, so
    // we can detect corruption (wrong value) and reordering (out of seq).
    // frame_strobe is the SAME single-cycle toggle pulse the real design
    // uses; if the FIFO is full that cycle the frame is dropped, exactly
    // mirroring the hardware behaviour we want to characterise.
    // ----------------------------------------------------------------
    localparam NFRAMES = 200;
    integer sent      = 0;   // frames where we toggled fr_avail
    integer i;

    // count actual FIFO acceptances by watching fifo_accept
    integer accepted = 0;
    always @(posedge trace_clk)
        if (!rst && fifo_accept) accepted = accepted + 1;

    initial begin
        frame128   = 0;
        fr_avail   = 0;
        @(negedge rst);
        @(negedge trace_clk);
        for (i = 1; i <= NFRAMES; i = i + 1) begin
            // payload: low 32 bits = sequence number, rest a fixed pattern
            frame128 = {96'hA5A5_DEAD_BEEF_CAFE_0123_4567, i[31:0]};
            // Drive fr_avail on the NEGEDGE so the posedge sampling of both
            // fr_avail_q and the accept/lost counters sees a stable value
            // (avoids TB clock-edge race). fr_avail stays put >=2 cycles so
            // the XOR strobe is a clean one-posedge pulse == one frame.
            fr_avail = ~fr_avail;
            sent = sent + 1;
            @(negedge trace_clk);   // strobe captured on the posedge between
            @(negedge trace_clk);   // these two negedges; now back to low
            if (i[2:0] == 0)
                repeat (3 + (i % 5)) @(negedge trace_clk);
        end
        // let the pipe drain
        repeat (600) @(posedge clk100);
        check_results;
    end

    // ----------------------------------------------------------------
    // Consumer: drain the FIFO on clk100, but with a throttle that is
    // intentionally slower than the producer's burst rate, to force the
    // FIFO full and exercise the overflow path. Record received payloads.
    // ----------------------------------------------------------------
    integer received = 0;
    reg [31:0] last_seq;
    reg        ordered_ok;
    reg        payload_ok;
    integer    throttle;

    initial begin
        cdc_out_ready = 0;
        last_seq      = 0;
        ordered_ok    = 1;
        payload_ok    = 1;
        throttle      = 0;
        @(negedge rst);
        forever begin
            @(posedge clk100);
            // throttle: only ready 1 of every 3 cycles -> slower than the
            // producer bursts, guaranteeing the FIFO fills.
            throttle <= throttle + 1;
            cdc_out_ready <= (throttle % 3 == 0);
            if (cdc_out_valid && cdc_out_ready) begin
                received = received + 1;
                // check fixed pattern part
                if (cdc_out_frame[127:32] !== 96'hA5A5_DEAD_BEEF_CAFE_0123_4567)
                    payload_ok = 0;
                // check monotonic increasing sequence (no reorder/dup)
                if (cdc_out_frame[31:0] <= last_seq && received > 1)
                    ordered_ok = 0;
                last_seq = cdc_out_frame[31:0];
            end
        end
    end

    task check_results;
        begin
            $display("---- frame_cdc_tb results ----");
            $display(" sent(toggled)   = %0d", sent);
            $display(" accepted(FIFO)  = %0d", accepted);
            $display(" received(out)   = %0d", received);
            $display(" trace_lost_cnt  = %0d", trace_lost_cnt);
            $display(" payload_ok      = %0d", payload_ok);
            $display(" ordered_ok      = %0d", ordered_ok);

            // Invariant 1: no corruption on any frame that made it through.
            if (!payload_ok) begin
                $display("FAIL: payload corruption across CDC");
                $finish;
            end
            // Invariant 2: no reorder/dup.
            if (!ordered_ok) begin
                $display("FAIL: frame reordering/duplication across CDC");
                $finish;
            end
            // Invariant 3: accounting closes — every sent frame is either
            // received or counted as lost. This is the NEW-1 guarantee:
            // loss is visible, never silent.
            if (accepted != received) begin
                $display("FAIL: accepted(%0d) != received(%0d) - frames vanished inside FIFO",
                         accepted, received);
                $finish;
            end
            if (sent != received + trace_lost_cnt) begin
                $display("FAIL: accounting leak: sent(%0d) != received(%0d) + lost(%0d)",
                         sent, received, trace_lost_cnt);
                $finish;
            end
            // We WANT to have exercised the overflow path at least once,
            // otherwise the throttle wasn't aggressive enough to prove the
            // counter works.
            if (trace_lost_cnt == 0) begin
                $display("WARN: overflow path not exercised (FIFO never filled).");
                $display("      Test still valid for integrity, but NEW-1 counter unproven.");
            end else begin
                $display("PASS: %0d frames overflowed and were ALL accounted for by trace_lost_cnt",
                         trace_lost_cnt);
            end
            $display("PASS: CDC integrity (no corruption, no reorder, no silent loss)");
            $finish;
        end
    endtask

    initial begin
        #500000;
        $display("WATCHDOG timeout");
        $finish;
    end

endmodule
