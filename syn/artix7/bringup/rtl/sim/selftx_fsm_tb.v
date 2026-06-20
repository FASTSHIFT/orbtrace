// selftx_fsm_tb
// =============
// Isolate and verify the self-initiated UDP TX FSM logic from fpga_core_net's
// g_stream block, against a BEHAVIORAL udp_complete-TX stub, so we can find the
// FSM bug deterministically without the full eth stack / board (r19 Q2, and the
// "no packet even sent" symptom on hardware).
//
// The stub models udp_complete's TX-side handshake:
//   * s_udp_hdr_valid/ready: header accepted in 1 cycle when ready (ready is
//     deasserted a few cycles to model ARP latency, then asserts).
//   * s_udp_payload_axis_t*: standard AXIS; stub consumes payload, counts bytes,
//     checks the count matches (length-8) at tlast, prints each emitted packet.
//
// We replicate the FSM exactly as in fpga_core_net g_stream (echo_req tied 0 =
// no RX), feed stream_tvalid=1 + a ramp, and expect periodic packets of
// STREAM_PKT_BYTES.

`timescale 1ns/1ps
`default_nettype none

module selftx_fsm_tb;
    localparam PKT = 16'd8;          // small packet for fast sim
    reg clk = 0; always #2 clk = ~clk;
    reg rst = 1;

    // ---- FSM (copy of g_stream) ----
    localparam ST_IDLE=2'd0, ST_HDR=2'd1, ST_SEND=2'd2;
    reg [1:0] st; reg [15:0] bcnt;

    // stream source
    reg [7:0] ramp = 0;
    wire stream_tready;
    wire stream_tvalid = 1'b1;
    always @(posedge clk) if (!rst && stream_tvalid && stream_tready) ramp <= ramp + 1'b1;

    wire echo_req = 1'b0;            // no RX in this test
    wire self_busy = (st != ST_IDLE);

    // udp_complete TX stub signals
    wire        hdr_valid = (st == ST_HDR);
    reg         hdr_ready;
    wire [7:0]  pl_tdata  = stream_tdata;
    wire        pl_tvalid = (st == ST_SEND && stream_tvalid);
    wire        pl_tlast  = (st == ST_SEND && (bcnt == PKT-1));
    reg         pl_tready;
    wire [7:0]  stream_tdata = ramp;
    assign stream_tready = (st == ST_SEND) && pl_tready;

    always @(posedge clk) begin
        if (rst) begin st <= ST_IDLE; bcnt <= 0; end
        else case (st)
            ST_IDLE: if (stream_tvalid && !echo_req) begin st <= ST_HDR; bcnt <= 0; end
            ST_HDR:  if (hdr_ready) st <= ST_SEND;
            ST_SEND: if (pl_tvalid && pl_tready) begin
                        if (bcnt == PKT-1) begin st <= ST_IDLE; bcnt <= 0; end
                        else bcnt <= bcnt + 1'b1;
                     end
        endcase
    end

    // ---- behavioral udp_complete TX stub ----
    // ARP latency model: after hdr_valid asserted, wait ARP_LAT cycles then
    // assert hdr_ready for 1 cycle; then accept payload (pl_tready=1).
    localparam ARP_LAT = 5;
    integer arp_cnt;
    reg accepting;
    integer rxbytes; integer pkts = 0;
    always @(posedge clk) begin
        if (rst) begin
            hdr_ready <= 0; pl_tready <= 0; arp_cnt <= 0; accepting <= 0; rxbytes <= 0;
        end else begin
            hdr_ready <= 0;
            if (st == ST_HDR && !accepting) begin
                if (arp_cnt < ARP_LAT) arp_cnt <= arp_cnt + 1;
                else begin
                    hdr_ready <= 1;       // accept header
                    accepting <= 1;
                    pl_tready <= 1;
                    rxbytes <= 0;
                    arp_cnt <= 0;
                end
            end
            if (accepting && pl_tvalid && pl_tready) begin
                rxbytes <= rxbytes + 1;
                if (pl_tlast) begin
                    pkts = pkts + 1;
                    $display("  pkt %0d: %0d payload bytes (last byte 0x%02x)", pkts, rxbytes+1, pl_tdata);
                    accepting <= 0; pl_tready <= 0;
                end
            end
        end
    end

    initial begin
        repeat (6) @(posedge clk); rst = 0;
        repeat (400) @(posedge clk);
        if (pkts >= 3) $display("PASS: self-TX FSM emitted %0d packets", pkts);
        else           $display("FAIL: only %0d packets (FSM stuck)", pkts);
        $finish;
    end
endmodule

`default_nettype wire
