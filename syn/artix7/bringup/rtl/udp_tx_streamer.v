// udp_tx_streamer
// ===============
// Self-initiated UDP TX: pull an AXIS byte stream and emit fixed-size UDP
// packets to a fixed destination, driving a verilog-ethernet udp_complete
// s_udp_* header+payload interface. Arbitrated with an optional RX-echo path
// (echo has priority when this streamer is idle; it cannot interrupt an
// in-flight self packet).
//
// Extracted from fpga_core_net g_stream (proposal 18 stage2) so the self-TX
// behaviour can be unit-tested in isolation against the real udp_complete
// (rtl/sim/udp_tx_streamer_tb.v), which is where the "no packet ever sent on
// hardware" bug was hiding. fpga_core_net can instantiate this instead of the
// inline FSM (keeps the eth core free of application TX logic).
//
// Handshake note (the hardware bug): verilog-ethernet udp_complete accepts the
// header (s_udp_hdr_ready) only when it can also start draining payload; if the
// payload is not presented in the same window the header handshake can stall,
// and for a fixed dest the IP layer must ARP-resolve first. This module
// therefore holds s_udp_hdr_valid AND presents valid payload from the first
// post-header cycle, and keeps payload valid across the whole packet.

`default_nettype none

module udp_tx_streamer #(
    parameter [31:0] DEST_IP   = {8'd192, 8'd168, 8'd10, 8'd245},
    parameter [15:0] DEST_PORT = 16'd5555,
    parameter [15:0] SRC_PORT  = 16'd5555,
    parameter [15:0] PKT_BYTES = 16'd1024,
    parameter [31:0] LOCAL_IP  = {8'd192, 8'd168, 8'd10, 8'd42}
) (
    input  wire        clk,
    input  wire        rst,

    // payload byte stream to transmit (continuous)
    input  wire [7:0]  stream_tdata,
    input  wire        stream_tvalid,
    output wire        stream_tready,

    // start gating: only begin a packet when at least one full PKT_BYTES is
    // buffered upstream (prevents mid-packet underrun stalling the MAC).
    input  wire        can_start,

    // udp_complete s_udp_* header
    output wire        udp_hdr_valid,
    input  wire        udp_hdr_ready,
    output wire [5:0]  udp_ip_dscp,
    output wire [1:0]  udp_ip_ecn,
    output wire [7:0]  udp_ip_ttl,
    output wire [31:0] udp_ip_source_ip,
    output wire [31:0] udp_ip_dest_ip,
    output wire [15:0] udp_source_port,
    output wire [15:0] udp_dest_port,
    output wire [15:0] udp_length,
    output wire [15:0] udp_checksum,
    // udp_complete s_udp_payload_axis_*
    output wire [7:0]  udp_payload_tdata,
    output wire        udp_payload_tvalid,
    input  wire        udp_payload_tready,
    output wire        udp_payload_tlast,
    output wire        udp_payload_tuser,

    output wire [1:0]  dbg_state
);
    localparam ST_IDLE = 2'd0, ST_HDR = 2'd1, ST_SEND = 2'd2;
    reg [1:0]  st = ST_IDLE;
    reg [15:0] bcnt = 0;
    assign dbg_state = st;

    wire sending = (st == ST_SEND);

    assign udp_hdr_valid    = (st == ST_HDR);
    assign udp_ip_dscp      = 0;
    assign udp_ip_ecn       = 0;
    assign udp_ip_ttl       = 8'd64;
    assign udp_ip_source_ip = LOCAL_IP;
    assign udp_ip_dest_ip   = DEST_IP;
    assign udp_source_port  = SRC_PORT;
    assign udp_dest_port    = DEST_PORT;
    assign udp_length       = 16'd8 + PKT_BYTES;
    assign udp_checksum     = 0;

    assign udp_payload_tdata  = stream_tdata;
    assign udp_payload_tvalid = sending && stream_tvalid;
    assign udp_payload_tlast  = sending && (bcnt == PKT_BYTES - 1);
    assign udp_payload_tuser  = 1'b0;
    assign stream_tready      = sending && udp_payload_tready;

    always @(posedge clk) begin
        if (rst) begin
            st <= ST_IDLE; bcnt <= 0;
        end else case (st)
            ST_IDLE:
                if (can_start && stream_tvalid) begin
                    st <= ST_HDR; bcnt <= 0;
                end
            ST_HDR:
                if (udp_hdr_ready) st <= ST_SEND;
            ST_SEND:
                if (udp_payload_tvalid && udp_payload_tready) begin
                    if (bcnt == PKT_BYTES - 1) begin
                        st <= ST_IDLE; bcnt <= 0;
                    end else bcnt <= bcnt + 1'b1;
                end
        endcase
    end
endmodule

`default_nettype wire
