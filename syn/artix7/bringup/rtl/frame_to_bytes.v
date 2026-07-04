// frame_to_bytes.v
// =================
// Serialize a 128-bit traceIF frame into 16 sequential bytes on a stream
// interface (tvalid/tready). Byte order: Frame[127:120] first (MSB byte),
// matching traceIF's presentation (payload[0] = Frame[127:120]).
//
// Interface:
//   Input:  frame_toggle (pulses/toggles when a new frame is available),
//           frame_data[127:0]
//   Output: m_tdata[7:0], m_tvalid, m_tready (AXI-Stream style)
//
// Clock: single clock domain (the consumer's clock, after CDC).

`default_nettype none

module frame_to_bytes (
    input  wire         clk,
    input  wire         rst,

    // Frame input (captured in this clock domain after CDC)
    input  wire         frame_valid,    // pulse: new frame available
    input  wire [127:0] frame_data,

    // Byte stream output
    output reg  [7:0]   m_tdata,
    output reg          m_tvalid,
    input  wire         m_tready
);

    reg [127:0] shift_reg;
    reg [3:0]   byte_cnt;      // 0..15, counts bytes remaining
    reg         active;

    always @(posedge clk) begin
        if (rst) begin
            active   <= 1'b0;
            m_tvalid <= 1'b0;
            byte_cnt <= 4'd0;
        end else if (!active) begin
            // Idle: wait for a frame
            if (frame_valid) begin
                shift_reg <= frame_data;
                byte_cnt  <= 4'd15;
                m_tdata   <= frame_data[127:120];  // first byte (MSB)
                m_tvalid  <= 1'b1;
                active    <= 1'b1;
            end else begin
                m_tvalid <= 1'b0;
            end
        end else begin
            // Active: shift out bytes
            if (m_tvalid && m_tready) begin
                if (byte_cnt == 4'd0) begin
                    // Done with this frame
                    active   <= 1'b0;
                    m_tvalid <= 1'b0;
                end else begin
                    shift_reg <= {shift_reg[119:0], 8'd0};
                    m_tdata   <= shift_reg[119:112];  // next byte
                    byte_cnt  <= byte_cnt - 4'd1;
                end
            end
        end
    end

endmodule

`default_nettype wire
