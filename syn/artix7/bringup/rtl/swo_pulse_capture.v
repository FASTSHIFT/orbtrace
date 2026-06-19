// swo_pulse_capture
// =================
// SWO single-line pulse-length front-end (提案 15, NRZ path). Oversamples the
// asynchronous SWO line (STM32 PB3 / TRACESWO) in the fast ref_200m domain and
// emits a stream of {level, count} pulses: how many ref_200m cycles the line
// stayed at a given level before flipping. This is the Verilog equivalent of
// ORBTrace upstream's amaranth `PulseLengthCapture` (orbtrace/trace/swo.py),
// reworked to consume ONE oversample per clock (our ref domain is plenty fast
// for SWO <= a few MHz, so we don't need the 2-sample/cycle trick the upstream
// uses to handle its 2x SWO clock).
//
// Why single-line beats the 5-wire parallel port here: no inter-lane skew, no
// source-synchronous setup/hold, no independent TRACECLK quality issue (提案
// 15 §1.2). The only sampling concern is metastability on the async line,
// handled by a 3-FF synchroniser; at SWO 2 MHz one bit = ~100 ref cycles, so
// the eye is enormous.
//
// Output protocol: when the (synchronised) line level changes, emit one pulse
// describing the level that JUST ENDED and how many ref cycles it lasted. A
// max-length guard also force-emits a pulse if the counter saturates (a long
// idle high) so the downstream NRZ decoder can flush idle/stop bits.
//
//   level flips  -> pulse_valid=1, pulse_level=ended level, pulse_count=dwell
//   count saturates (idle) -> force a pulse so idle is bounded
//
// A 1-sample glitch (single-cycle blip opposite to neighbours) is folded into
// the surrounding level (matches upstream's 010/101 case = "ignore, add 2").

`default_nettype none

module swo_pulse_capture #(
    parameter CW = 16,         // pulse-count width (ref cycles); 16b covers
                               // ~327 us at 5 ns/cycle, far longer than any bit
    parameter IDLE_FLUSH = 16'd2000
                               // force-emit the current level after this many
                               // ref cycles with no edge, so the LAST byte of a
                               // burst (whose stop bit is followed by idle, not
                               // another edge) still flushes its stop-bit pulse.
                               // Must be >= a few bit lengths (at 2 Mbaud/200MHz
                               // one bit = 100 cyc, so 2000 = 20 bits) and well
                               // below any real inter-byte gap you care to keep
                               // distinct. Tie larger for slower SWO.
) (
    input  wire           clk,         // ref_200m (5 ns)
    input  wire           rst,
    input  wire           swo_in,      // raw async SWO line (PB3)

    output reg            pulse_valid,
    output reg            pulse_level, // the level that just ended
    output reg  [CW-1:0]  pulse_count  // ref cycles that level lasted
);

    // ---- async synchroniser + 1-sample glitch fold --------------------
    // sync[2] is the stable, metastability-filtered line level. We keep one
    // more history bit to detect and fold single-cycle glitches: if the line
    // goes a..b..a in three consecutive samples (a lone opposite sample), the
    // middle sample is a glitch -> we do NOT treat it as two edges.
    reg [2:0] sync;
    always @(posedge clk) begin
        if (rst) sync <= 3'b0;
        else     sync <= {sync[1:0], swo_in};
    end

    wire cur  = sync[1];   // current debounced sample
    wire prev = sync[2];   // previous sample (the "running level")

    // Lone-glitch detect: sync[0] != sync[1] != sync[2] with sync[0]==sync[2]
    // means sync[1] was a single-cycle blip. Treat as no-edge (fold).
    wire glitch = (sync[0] == sync[2]) && (sync[1] != sync[2]);

    reg [CW-1:0] count;
    wire         sat = count[CW-1];     // saturation guard (idle bound)
    wire         idle_flush = (count >= IDLE_FLUSH);  // bound last-byte latency

    // A real edge: the debounced level differs from the running level AND it
    // is not a lone glitch.
    wire edge_now = (cur != prev) && !glitch;

    always @(posedge clk) begin
        if (rst) begin
            count       <= 0;
            pulse_valid <= 1'b0;
            pulse_level <= 1'b0;
            pulse_count <= 0;
        end else begin
            pulse_valid <= 1'b0;
            if (edge_now) begin
                // level `prev` just ended after `count`(+1 for this cycle) ref
                // cycles; emit it, then start counting the new level.
                pulse_level <= prev;
                pulse_count <= count + 1'b1;
                pulse_valid <= 1'b1;
                count       <= 0;
            end else if (sat || idle_flush) begin
                // idle: force-emit so a long steady level (idle high between
                // UART frames, or the stop bit of the final byte in a burst)
                // is bounded and the NRZ/UART decoders can flush.
                pulse_level <= prev;
                pulse_count <= count;
                pulse_valid <= 1'b1;
                count       <= 0;
            end else begin
                count <= count + 1'b1;
            end
        end
    end

endmodule

`default_nettype wire
