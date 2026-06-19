// swo_nrz_decode
// ==============
// Convert a {level, count} pulse stream (from swo_pulse_capture) into UART bit
// strobes, given the bit length in ref_200m cycles. Verilog equivalent of
// ORBTrace upstream's amaranth `NRZDecoder` (orbtrace/trace/swo.py), simplified
// to a one-way strobe chain (no valid/ready back-pressure) because our ref
// domain is far faster than SWO: a pulse arrives at most every ~bitlen cycles,
// and draining a pulse into its bits takes only as many cycles as it has bits,
// so the accumulator is always emptied before the next edge.
//
// SWO NRZ == async UART: a pulse of duration `count` ref cycles at a level is
// round(count/bitlen) consecutive bits of that level. We add a half-bit bias
// so the rounding lands mid-bit. bitlen = ref_freq/baud (200 MHz / 2 Mbaud =
// 100), supplied at runtime from a CSR so baud changes need no resynth.
//
// A 12-bit-per-pulse cap (matches upstream cnt<12) bounds an idle 'high' pulse:
// a UART frame is 10 bits, 12 lets the stop/idle bits flush without emitting an
// endless run of ones for a long idle.

`default_nettype none

module swo_nrz_decode #(
    parameter CW = 16
) (
    input  wire            clk,
    input  wire            rst,

    // pulse input (1-cycle strobe from swo_pulse_capture)
    input  wire            pulse_valid,
    input  wire            pulse_level,
    input  wire [CW-1:0]   pulse_count,

    // UART bit output (1-cycle strobe)
    output reg             bit_valid,
    output reg             bit_value,

    // bit length in ref cycles (= ref_freq / baud). Quasi-static (CSR).
    input  wire [CW-1:0]   bitlen
);

    // acc counts down in plain ref-cycle units (no fixed-point needed: at
    // 200 MHz a ref cycle is fine resolution). On load, seed with the pulse
    // duration plus a half-bit bias so emitted bits land mid-bit.
    localparam AW = CW + 1;        // +1 guard for the +bitlen/2 bias
    reg  [AW-1:0] acc;
    reg  [3:0]    cnt;
    reg           cur_level;

    wire have_bit = (acc >= {1'b0, bitlen}) && (cnt < 4'd12);

    always @(posedge clk) begin
        if (rst) begin
            acc       <= 0;
            cnt       <= 0;
            cur_level <= 1'b0;
            bit_valid <= 1'b0;
            bit_value <= 1'b0;
        end else begin
            bit_valid <= 1'b0;
            if (pulse_valid) begin
                // load: acc = count + bitlen/2
                acc       <= {1'b0, pulse_count} + {2'b0, bitlen[CW-1:1]};
                cur_level <= pulse_level;
                cnt       <= 0;
            end else if (have_bit) begin
                // emit one bit of the current level and consume one bit length
                bit_valid <= 1'b1;
                bit_value <= cur_level;
                acc       <= acc - {1'b0, bitlen};
                cnt       <= cnt + 1'b1;
            end
        end
    end

endmodule

`default_nettype wire
