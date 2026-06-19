// swo_iddr_capture
// ================
// IDDR double-edge oversampling front-end for SWO (提案 17, 榨干 SWO 带宽).
// Samples the asynchronous single-wire SWO line on BOTH edges of a free-running
// fast clock, giving 2 oversamples per clock cycle = 2x the effective sample
// rate of the single-edge swo_pulse_capture. With a 250 MHz sample clock this
// is 500 MSa/s — matching ORBTrace's ECP5 front-end (swo2x=250MHz, IDDR In(2)).
//
// This is the OVERSAMPLE use of IDDR (not the source-synchronous use in
// trace_capture_a7): the IDDR clock is a free-running MMCM output, NOT a
// recovered trace clock, and there is no IDELAY eye-centering (an async line
// has no fixed phase to center on). It is a brand-new instantiation, distinct
// from the parallel-port capture (red-team r18 Q2).
//
// Pipeline: SWO pin -> IBUF -> IDDR (Q1=rising-edge sample, Q2=falling-edge
// sample of the SAME cycle) -> pulse-length quantiser (2 samples/cycle) ->
// {level, count} pulse stream (count in HALF-clock units = 500 MSa/s ticks).
// Feeds swo_nrz_decode exactly like swo_pulse_capture does, but bitlen is now
// in 500 MSa/s ticks (= sample_clk_freq*2 / baud).
//
// Pulse quantiser (mirrors ORBTrace PulseLengthCapture's 3-state Switch table):
// keep a 3-bit history = {prev_level, s_rising, s_falling} of the last sample
// and the two new ones, and per cycle either extend the current run by 2, or
// emit a pulse and restart, with single-sample glitches folded in.

`default_nettype none

module swo_iddr_capture #(
    parameter CW = 16,         // pulse-count width (in 500 MSa/s half-cycles)
    parameter [15:0] IDLE_FLUSH = 16'd8000
) (
    input  wire           sample_clk,  // free-running fast clock (e.g. 250 MHz)
    input  wire           rst,

    // IDDR-sampled pair for THIS cycle (provided by the top via an IDDR prim):
    //   s_d1 = sample at the rising edge, s_d2 = sample at the falling edge.
    // (Kept as inputs so the IDDR primitive lives in the top, which is the
    //  Vivado-friendly place for device primitives; sim drives them directly.)
    input  wire           s_d1,        // rising-edge oversample (earlier in time)
    input  wire           s_d2,        // falling-edge oversample (later in time)

    output reg            pulse_valid,
    output reg            pulse_level, // the level that just ended
    output reg  [CW-1:0]  pulse_count  // duration in 500 MSa/s half-cycles
);

    // history: prev = last cycle's falling sample; the two new samples are
    // s_d1 (earlier) then s_d2 (later). Per ORBTrace's table, classify the
    // 3-bit pattern {prev, s_d1, s_d2}.
    reg prev;
    always @(posedge sample_clk) if (!rst) prev <= s_d2;

    wire [2:0] pat = {prev, s_d1, s_d2};

    // Decode actions (mirror swo.py PulseLengthCapture Switch):
    //   000 / 111            : two more samples equal to prev      -> add 2
    //   011 / 100            : two samples opposite of prev        -> emit, restart count=2
    //   001 / 110            : one equal + one opposite            -> emit at count+1, restart=1
    //   010 / 101            : lone glitch                         -> add 2 (ignore)
    reg add2, emit0, emit1;
    always @(*) begin
        add2 = 1'b0; emit0 = 1'b0; emit1 = 1'b0;
        case (pat)
            3'b000, 3'b111: add2  = 1'b1;
            3'b011, 3'b100: emit0 = 1'b1;   // edge between the two new samples
            3'b001, 3'b110: emit1 = 1'b1;   // edge between prev and first new
            3'b010, 3'b101: add2  = 1'b1;   // glitch fold
        endcase
    end

    reg [CW-1:0] count;
    wire idle_flush = (count >= IDLE_FLUSH);

    always @(posedge sample_clk) begin
        if (rst) begin
            count       <= 0;
            pulse_valid <= 1'b0;
            pulse_level <= 1'b0;
            pulse_count <= 0;
        end else begin
            pulse_valid <= 1'b0;
            if (emit0) begin
                // level `prev` ran until between the two new samples: count+? 
                // The two new samples are opposite of prev, so prev ended right
                // at the cycle boundary; its length = current count (in halves).
                pulse_level <= prev;
                pulse_count <= count;
                pulse_valid <= 1'b1;
                count       <= 2;            // the two new (opposite) samples
            end else if (emit1) begin
                // prev held for one more half then flipped: length = count+1.
                pulse_level <= prev;
                pulse_count <= count + 1'b1;
                pulse_valid <= 1'b1;
                count       <= 1;            // one sample of the new level so far
            end else if (idle_flush) begin
                pulse_level <= prev;
                pulse_count <= count;
                pulse_valid <= 1'b1;
                count       <= 0;
            end else begin
                // add2 (run continues): two more half-cycles of the same level
                count <= count + 2'd2;
            end
        end
    end

endmodule

`default_nettype wire
