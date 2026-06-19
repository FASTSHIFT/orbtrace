// swo_uart_decode
// ===============
// Standard 8N1 UART framing on a bit-strobe stream: wait for a start bit (0),
// shift in 8 data bits (LSB first), check the stop bit (1), emit a byte.
// Verilog equivalent of ORBTrace upstream's amaranth `UARTDecoder`
// (orbtrace/trace/swo.py).
//
// Input: 1-cycle bit strobes from swo_nrz_decode. Output: 1-cycle byte strobe.
//
// Uses a 10-bit shift register seeded with a sentinel so the frame boundary is
// detected purely by the sentinel reaching the bottom — same trick as upstream
// (sr[0] marks "10 bits collected"). On a framing slip (missing stop bit) the
// FSM returns to WAITSTART and resyncs on the next start bit; the downstream
// TPIU deframer tolerates the occasional dropped byte.

`default_nettype none

module swo_uart_decode (
    input  wire        clk,
    input  wire        rst,

    // bit input (1-cycle strobe)
    input  wire        bit_valid,
    input  wire        bit_value,

    // byte output (1-cycle strobe)
    output reg         byte_valid,
    output reg [7:0]   byte_data
);

    localparam ST_WAITSTART = 1'b0;
    localparam ST_GETBITS    = 1'b1;
    reg        state;
    reg [9:0]  sr;      // [start][d0..d7][stop] assembled LSB-first via shift
    reg [3:0]  nbits;   // bits collected in GETBITS (0..9)

    always @(posedge clk) begin
        if (rst) begin
            state      <= ST_WAITSTART;
            sr         <= 0;
            nbits      <= 0;
            byte_valid <= 1'b0;
            byte_data  <= 8'h00;
        end else begin
            byte_valid <= 1'b0;
            case (state)
                ST_WAITSTART: begin
                    // start bit = 0
                    if (bit_valid && (bit_value == 1'b0)) begin
                        sr    <= 0;
                        nbits <= 0;
                        state <= ST_GETBITS;
                    end
                end
                ST_GETBITS: begin
                    if (bit_valid) begin
                        // shift data in LSB-first: first data bit is d0
                        if (nbits < 4'd8) begin
                            sr[7:0] <= {bit_value, sr[7:1]};
                            nbits   <= nbits + 1'b1;
                        end else begin
                            // this is the stop bit; valid frame iff it is 1
                            if (bit_value == 1'b1) begin
                                byte_data  <= sr[7:0];
                                byte_valid <= 1'b1;
                            end
                            state <= ST_WAITSTART;
                        end
                    end
                end
            endcase
        end
    end

endmodule

`default_nettype wire
