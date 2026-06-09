// blink.v
// =======
// Stage-3 board bring-up smoke test for the MicroPhase A7-Lite (XC7A35T).
// The very first thing to run on a freshly-arrived board: proves power,
// the 50 MHz oscillator (J19), the reset button (L18), the bitstream load
// path (SPIx4 flash), and that the two on-board LEDs (M18/N18) are alive.
//
// The A7-Lite only has TWO user LEDs, so a true "marquee" isn't possible;
// instead we run a small counter-driven pattern that alternates and
// blinks the two LEDs at a visible rate, which is unambiguous to the eye.
//
// LEDs are ACTIVE-LOW on this board (0 = lit, 1 = off) — see vendor
// 01_led demo. rst_n is active-low (button on L18).
//
// Pins (from vendor A7_lite.xdc / 01_led/top_pin.xdc):
//   clk    J19  50 MHz
//   rst_n  L18  active-low button
//   led[0] M18  active-low
//   led[1] N18  active-low

`default_nettype none

module blink #(
    // ~50 MHz clock; toggle every 2^BIT cycles. BIT=24 -> ~0.34 s,
    // giving a clearly visible blink without being too slow.
    parameter integer BIT = 24
) (
    input  wire       clk,
    input  wire       rst_n,
    output reg  [1:0] led
);

    reg [BIT:0] cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt <= {(BIT+1){1'b0}};
            led <= 2'b10;            // start: led[0] lit (active-low 0), led[1] off
        end else begin
            cnt <= cnt + 1'b1;
            if (cnt[BIT]) begin      // tick at the top bit
                cnt <= {(BIT+1){1'b0}};
                led <= ~led;         // alternate the two LEDs back and forth
            end
        end
    end

endmodule

`default_nettype wire
