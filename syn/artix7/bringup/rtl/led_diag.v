// led_diag.v
// ==========
// Dead-simple two-LED diagnostic for the A7-Lite trace-stream bitstream.
// Purpose: split the "PC sees no packets" ambiguity into two INTERNAL,
// network-independent observations, so we can tell "FPGA never produced trace
// clock" and "FPGA never transmitted" apart from "the cable/hub/PC dropped it".
//
// This deliberately replaces the older multi-state led_status.v priority
// encoder (off/slow/fast/steady with alarms) -- that was hard to read on the
// bench. Here each LED answers exactly ONE yes/no question by BLINKING at a
// human-visible rate whenever its signal is active, and sitting dark when it is
// not. No priority, no latches, no ambiguity.
//
//   led0  = TRACECLK INPUT alive.
//           Blinks ~3 Hz whenever the recovered trace clock is toggling
//           (STM32 TPIU is clocking data into the FPGA). Dark = no TRACECLK
//           (target not tracing / ETM off / wiring dead).
//
//   led1  = NETWORK TX alive.
//           Blinks ~3 Hz whenever the MAC is transmitting to the PHY
//           (any frame: ARP reply, self-TX stream, heartbeat). Dark = the
//           FPGA is emitting NOTHING on the wire -> if the PC also sees
//           nothing, the fault is inside the FPGA, not the link.
//
// LED polarity on A7-Lite is ACTIVE-LOW (0 = lit, 1 = dark).
//
// Design note -- why "activity gated blink" and not "divide the clock":
//   trace_clk is a genuine asynchronous, possibly-STOPPED clock. If we simply
//   routed a divided trace_clk to the pin, a stopped trace_clk would freeze the
//   LED at whatever level it last held (could read as dim-on), which is
//   ambiguous. Instead we detect *activity* in the stable clk125 domain and
//   only then let a clk125-based blink run. Both LEDs therefore share one clean
//   ~3 Hz timebase off clk125 and just gate it on their activity flag.

`default_nettype none

module led_diag #(
    // ~67 ms activity window: if the watched signal produced no event in this
    // long, treat it as idle and go dark. 2^23 / 125e6 ~= 67 ms.
    parameter integer ACT_WINDOW_BITS = 23
) (
    input  wire clk125,          // stable system clock (125 MHz)
    input  wire rst,

    // TRACECLK activity: a 1-clk125 pulse each time the recovered trace clock
    // is seen toggling. Produced here from trace_clk via a small synchroniser
    // (the parent passes the raw async trace_clk in on trace_clk).
    input  wire trace_clk,       // async recovered TRACECLK (may be stopped)

    // NETWORK TX activity: MAC->PHY transmit strobe (dbg_tx_axis_tvalid), in
    // the clk125 MAC domain already.
    input  wire tx_active,

    output wire led0,            // TRACECLK alive  (active-low)
    output wire led1             // network TX alive (active-low)
);

    // ---- shared ~3 Hz blink timebase (clk125) ----
    // 125e6 / 2^25 ~= 3.7 Hz toggle.
    reg [24:0] blink_cnt = 0;
    always @(posedge clk125) begin
        if (rst) blink_cnt <= 0;
        else     blink_cnt <= blink_cnt + 1'b1;
    end
    wire blink = blink_cnt[24];

    // ---- TRACECLK edge detector: sync the async clock into clk125 and pulse
    //      on any level change. A toggling trace_clk -> a stream of pulses; a
    //      stopped trace_clk -> no pulses. ----
    reg [2:0] tclk_sync = 0;
    always @(posedge clk125) begin
        if (rst) tclk_sync <= 0;
        else     tclk_sync <= {tclk_sync[1:0], trace_clk};
    end
    wire tclk_edge = tclk_sync[2] ^ tclk_sync[1];

    // ---- generic activity latch: high while an event was seen within the
    //      last ACT_WINDOW_BITS window; decays to 0 when the source goes idle.

    // TRACECLK activity window
    reg [ACT_WINDOW_BITS-1:0] tclk_timer = 0;
    reg tclk_recent = 0;
    always @(posedge clk125) begin
        if (rst) begin
            tclk_timer <= 0; tclk_recent <= 1'b0;
        end else if (tclk_edge) begin
            tclk_timer  <= {ACT_WINDOW_BITS{1'b1}};
            tclk_recent <= 1'b1;
        end else if (tclk_timer != 0) begin
            tclk_timer <= tclk_timer - 1'b1;
        end else begin
            tclk_recent <= 1'b0;
        end
    end

    // NETWORK TX activity window
    reg [ACT_WINDOW_BITS-1:0] tx_timer = 0;
    reg tx_recent = 0;
    always @(posedge clk125) begin
        if (rst) begin
            tx_timer <= 0; tx_recent <= 1'b0;
        end else if (tx_active) begin
            tx_timer  <= {ACT_WINDOW_BITS{1'b1}};
            tx_recent <= 1'b1;
        end else if (tx_timer != 0) begin
            tx_timer <= tx_timer - 1'b1;
        end else begin
            tx_recent <= 1'b0;
        end
    end

    // ---- drive LEDs: blink while active, dark while idle (active-low pads) ----
    assign led0 = tclk_recent ? ~blink : 1'b1;
    assign led1 = tx_recent   ? ~blink : 1'b1;

endmodule

`default_nettype wire
