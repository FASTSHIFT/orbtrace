// udp_tx_streamer_tb
// ==================
// FULL-STACK self-TX test: udp_tx_streamer -> REAL udp_complete -> eth wire.
// Reproduces the hardware "no packet ever sent" symptom in sim so we can fix
// the ARP/header handshake deterministically (not blind on the board).
//
// The eth TX output of udp_complete is parsed by a behavioral peer that:
//   - detects ARP requests (who-has DEST_IP) and injects an ARP REPLY back
//     into udp_complete's eth RX, so the IP layer can resolve the dest MAC;
//   - counts UDP/IP data frames that come out (ethertype 0x0800) = success.
//
// PASS = udp_hdr_ready asserted AND >=1 IP/UDP frame egressed after ARP.
// If udp_hdr_ready never asserts or no IP frame egresses, the bug is in the
// streamer<->udp_complete handshake (what we are hunting).

`timescale 1ns/1ps
`default_nettype none

module udp_tx_streamer_tb;
    localparam [31:0] LOCAL_IP = {8'd192,8'd168,8'd10,8'd42};
    localparam [31:0] DEST_IP  = {8'd192,8'd168,8'd10,8'd245};
    localparam [47:0] LOCAL_MAC= 48'h02_CA_FE_A7_7E_5C;
    localparam [47:0] PEER_MAC = 48'hAA_BB_CC_DD_EE_01;
    localparam [15:0] PKT = 16'd16;

    reg clk = 0; always #4 clk = ~clk;   // 125 MHz
    reg rst = 1;

    // ---- payload source: continuous ramp ----
    reg [7:0] ramp = 0;
    wire stream_tready;
    wire stream_tvalid = 1'b1;
    always @(posedge clk) if (!rst && stream_tvalid && stream_tready) ramp <= ramp + 1'b1;

    // ---- streamer <-> udp_complete s_udp_* ----
    wire        udp_hdr_valid, udp_hdr_ready;
    wire [5:0]  udp_ip_dscp;  wire [1:0] udp_ip_ecn;  wire [7:0] udp_ip_ttl;
    wire [31:0] udp_ip_source_ip, udp_ip_dest_ip;
    wire [15:0] udp_source_port, udp_dest_port, udp_length, udp_checksum;
    wire [7:0]  udp_pl_tdata;  wire udp_pl_tvalid, udp_pl_tready, udp_pl_tlast, udp_pl_tuser;
    wire [1:0]  dbg_state;

    udp_tx_streamer #(
        .DEST_IP(DEST_IP), .DEST_PORT(16'd5555), .SRC_PORT(16'd5555),
        .PKT_BYTES(PKT), .LOCAL_IP(LOCAL_IP)
    ) dut (
        .clk(clk), .rst(rst),
        .stream_tdata(ramp), .stream_tvalid(stream_tvalid), .stream_tready(stream_tready),
        .can_start(1'b1),
        .udp_hdr_valid(udp_hdr_valid), .udp_hdr_ready(udp_hdr_ready),
        .udp_ip_dscp(udp_ip_dscp), .udp_ip_ecn(udp_ip_ecn), .udp_ip_ttl(udp_ip_ttl),
        .udp_ip_source_ip(udp_ip_source_ip), .udp_ip_dest_ip(udp_ip_dest_ip),
        .udp_source_port(udp_source_port), .udp_dest_port(udp_dest_port),
        .udp_length(udp_length), .udp_checksum(udp_checksum),
        .udp_payload_tdata(udp_pl_tdata), .udp_payload_tvalid(udp_pl_tvalid),
        .udp_payload_tready(udp_pl_tready), .udp_payload_tlast(udp_pl_tlast),
        .udp_payload_tuser(udp_pl_tuser), .dbg_state(dbg_state)
    );

    // ---- eth-side wires of udp_complete ----
    // RX (into udp_complete) <- peer injects ARP reply
    reg         rx_eth_hdr_valid = 0;  wire rx_eth_hdr_ready;
    reg  [47:0] rx_eth_dest_mac;  reg [47:0] rx_eth_src_mac;  reg [15:0] rx_eth_type;
    reg  [7:0]  rx_eth_pl_tdata;  reg rx_eth_pl_tvalid;  wire rx_eth_pl_tready;
    reg         rx_eth_pl_tlast;  reg rx_eth_pl_tuser;
    // TX (out of udp_complete) -> peer parses
    wire        tx_eth_hdr_valid; reg tx_eth_hdr_ready = 1;
    wire [47:0] tx_eth_dest_mac, tx_eth_src_mac;  wire [15:0] tx_eth_type;
    wire [7:0]  tx_eth_pl_tdata;  wire tx_eth_pl_tvalid; reg tx_eth_pl_tready = 1;
    wire        tx_eth_pl_tlast, tx_eth_pl_tuser;

    // unused IP-frame ports
    wire        rx_ip_hdr_valid; wire [7:0] rx_ip_pl_tdata; wire rx_ip_pl_tvalid, rx_ip_pl_tlast, rx_ip_pl_tuser;

    udp_complete #(.UDP_CHECKSUM_GEN_ENABLE(0)) udp (
        .clk(clk), .rst(rst),
        // eth RX in
        .s_eth_hdr_valid(rx_eth_hdr_valid), .s_eth_hdr_ready(rx_eth_hdr_ready),
        .s_eth_dest_mac(rx_eth_dest_mac), .s_eth_src_mac(rx_eth_src_mac), .s_eth_type(rx_eth_type),
        .s_eth_payload_axis_tdata(rx_eth_pl_tdata), .s_eth_payload_axis_tvalid(rx_eth_pl_tvalid),
        .s_eth_payload_axis_tready(rx_eth_pl_tready), .s_eth_payload_axis_tlast(rx_eth_pl_tlast),
        .s_eth_payload_axis_tuser(rx_eth_pl_tuser),
        // eth TX out
        .m_eth_hdr_valid(tx_eth_hdr_valid), .m_eth_hdr_ready(tx_eth_hdr_ready),
        .m_eth_dest_mac(tx_eth_dest_mac), .m_eth_src_mac(tx_eth_src_mac), .m_eth_type(tx_eth_type),
        .m_eth_payload_axis_tdata(tx_eth_pl_tdata), .m_eth_payload_axis_tvalid(tx_eth_pl_tvalid),
        .m_eth_payload_axis_tready(tx_eth_pl_tready), .m_eth_payload_axis_tlast(tx_eth_pl_tlast),
        .m_eth_payload_axis_tuser(tx_eth_pl_tuser),
        // IP in (unused)
        .s_ip_hdr_valid(1'b0), .s_ip_hdr_ready(),
        .s_ip_dscp(6'd0), .s_ip_ecn(2'd0), .s_ip_length(16'd0), .s_ip_ttl(8'd0),
        .s_ip_protocol(8'd0), .s_ip_source_ip(32'd0), .s_ip_dest_ip(32'd0),
        .s_ip_payload_axis_tdata(8'd0), .s_ip_payload_axis_tvalid(1'b0),
        .s_ip_payload_axis_tready(), .s_ip_payload_axis_tlast(1'b0), .s_ip_payload_axis_tuser(1'b0),
        // IP out (unused, accept)
        .m_ip_hdr_valid(rx_ip_hdr_valid), .m_ip_hdr_ready(1'b1),
        .m_ip_eth_dest_mac(), .m_ip_eth_src_mac(), .m_ip_eth_type(),
        .m_ip_version(), .m_ip_ihl(), .m_ip_dscp(), .m_ip_ecn(), .m_ip_length(),
        .m_ip_identification(), .m_ip_flags(), .m_ip_fragment_offset(), .m_ip_ttl(),
        .m_ip_protocol(), .m_ip_header_checksum(), .m_ip_source_ip(), .m_ip_dest_ip(),
        .m_ip_payload_axis_tdata(rx_ip_pl_tdata), .m_ip_payload_axis_tvalid(rx_ip_pl_tvalid),
        .m_ip_payload_axis_tready(1'b1), .m_ip_payload_axis_tlast(rx_ip_pl_tlast),
        .m_ip_payload_axis_tuser(rx_ip_pl_tuser),
        // UDP in (from streamer)
        .s_udp_hdr_valid(udp_hdr_valid), .s_udp_hdr_ready(udp_hdr_ready),
        .s_udp_ip_dscp(udp_ip_dscp), .s_udp_ip_ecn(udp_ip_ecn), .s_udp_ip_ttl(udp_ip_ttl),
        .s_udp_ip_source_ip(udp_ip_source_ip), .s_udp_ip_dest_ip(udp_ip_dest_ip),
        .s_udp_source_port(udp_source_port), .s_udp_dest_port(udp_dest_port),
        .s_udp_length(udp_length), .s_udp_checksum(udp_checksum),
        .s_udp_payload_axis_tdata(udp_pl_tdata), .s_udp_payload_axis_tvalid(udp_pl_tvalid),
        .s_udp_payload_axis_tready(udp_pl_tready), .s_udp_payload_axis_tlast(udp_pl_tlast),
        .s_udp_payload_axis_tuser(udp_pl_tuser),
        // UDP out (unused, accept)
        .m_udp_hdr_valid(), .m_udp_hdr_ready(1'b1),
        .m_udp_eth_dest_mac(), .m_udp_eth_src_mac(), .m_udp_eth_type(),
        .m_udp_ip_version(), .m_udp_ip_ihl(), .m_udp_ip_dscp(), .m_udp_ip_ecn(),
        .m_udp_ip_length(), .m_udp_ip_identification(), .m_udp_ip_flags(),
        .m_udp_ip_fragment_offset(), .m_udp_ip_ttl(), .m_udp_ip_protocol(),
        .m_udp_ip_header_checksum(), .m_udp_ip_source_ip(), .m_udp_ip_dest_ip(),
        .m_udp_source_port(), .m_udp_dest_port(), .m_udp_length(), .m_udp_checksum(),
        .m_udp_payload_axis_tdata(), .m_udp_payload_axis_tvalid(),
        .m_udp_payload_axis_tready(1'b1), .m_udp_payload_axis_tlast(), .m_udp_payload_axis_tuser(),
        // status
        .ip_rx_busy(), .ip_tx_busy(), .udp_rx_busy(), .udp_tx_busy(),
        .ip_rx_error_header_early_termination(), .ip_rx_error_payload_early_termination(),
        .ip_rx_error_invalid_header(), .ip_rx_error_invalid_checksum(),
        .ip_tx_error_payload_early_termination(), .ip_tx_error_arp_failed(),
        .udp_rx_error_header_early_termination(), .udp_rx_error_payload_early_termination(),
        .udp_tx_error_payload_early_termination(),
        // config
        .local_mac(LOCAL_MAC), .local_ip(LOCAL_IP),
        .gateway_ip({8'd192,8'd168,8'd10,8'd1}), .subnet_mask({8'd255,8'd255,8'd255,8'd0}),
        .clear_arp_cache(1'b0)
    );

    // ---- behavioral peer: detect ARP request on TX eth, inject ARP reply ----
    integer arp_reqs = 0, ip_frames = 0;
    reg hdr_ready_seen = 0;
    always @(posedge clk) if (udp_hdr_ready) hdr_ready_seen <= 1;

    // probe payload drain + arp_failed
    integer pl_beats = 0;
    always @(posedge clk) if (udp_pl_tvalid && udp_pl_tready) pl_beats <= pl_beats + 1;
    always @(posedge clk) if (udp.ip_tx_error_arp_failed)
        $display("[%0t] ip_tx_error_arp_failed", $time);
    // probe internal ip_complete ARP request + ip tx header
    reg arpreq_seen = 0, iptx_hdr_seen = 0;
    always @(posedge clk) begin
        if (udp.ip_complete_inst.arp_request_valid) begin
            if (!arpreq_seen) $display("[%0t] ip_complete arp_request_valid ip=%08x", $time, udp.ip_complete_inst.arp_request_ip);
            arpreq_seen <= 1;
        end
        if (udp.ip_complete_inst.s_ip_hdr_valid) begin
            if (!iptx_hdr_seen) $display("[%0t] ip_complete s_ip_hdr_valid dest=%08x", $time, udp.ip_complete_inst.s_ip_dest_ip);
            iptx_hdr_seen <= 1;
        end
    end

    // count egress frame types at header time
    always @(posedge clk) begin
        if (tx_eth_hdr_valid && tx_eth_hdr_ready) begin
            if (tx_eth_type == 16'h0806) begin
                arp_reqs <= arp_reqs + 1;
                $display("[%0t] TX ARP frame (type 0806) dest=%012x", $time, tx_eth_dest_mac);
            end else if (tx_eth_type == 16'h0800) begin
                ip_frames <= ip_frames + 1;
                $display("[%0t] TX IP/UDP frame (type 0800) dest=%012x", $time, tx_eth_dest_mac);
            end
        end
    end

    // ARP reply injector: when we see an ARP request egress, after a few
    // cycles drive an ARP reply into the RX eth side (who-has DEST_IP ->
    // DEST_IP is-at PEER_MAC). ARP packet = 28 bytes payload.
    reg [7:0] arp_pl [0:27];
    integer i, ai;
    reg injecting = 0;
    integer inj_idx = 0;
    reg arp_pending = 0;

    always @(posedge clk) begin
        if (rst) begin
            arp_pending <= 0;
        end else if (tx_eth_hdr_valid && tx_eth_hdr_ready && tx_eth_type == 16'h0806) begin
            arp_pending <= 1;       // schedule a reply
        end else if (injecting) begin
            arp_pending <= 0;
        end
    end

    task build_arp_reply;
        begin
            // htype=1, ptype=0800, hlen=6, plen=4, oper=2 (reply)
            arp_pl[0]=8'h00; arp_pl[1]=8'h01; arp_pl[2]=8'h08; arp_pl[3]=8'h00;
            arp_pl[4]=8'h06; arp_pl[5]=8'h04; arp_pl[6]=8'h00; arp_pl[7]=8'h02;
            // sender HW = PEER_MAC, sender IP = DEST_IP
            arp_pl[8]=PEER_MAC[47:40]; arp_pl[9]=PEER_MAC[39:32]; arp_pl[10]=PEER_MAC[31:24];
            arp_pl[11]=PEER_MAC[23:16]; arp_pl[12]=PEER_MAC[15:8]; arp_pl[13]=PEER_MAC[7:0];
            arp_pl[14]=DEST_IP[31:24]; arp_pl[15]=DEST_IP[23:16]; arp_pl[16]=DEST_IP[15:8]; arp_pl[17]=DEST_IP[7:0];
            // target HW = LOCAL_MAC, target IP = LOCAL_IP
            arp_pl[18]=LOCAL_MAC[47:40]; arp_pl[19]=LOCAL_MAC[39:32]; arp_pl[20]=LOCAL_MAC[31:24];
            arp_pl[21]=LOCAL_MAC[23:16]; arp_pl[22]=LOCAL_MAC[15:8]; arp_pl[23]=LOCAL_MAC[7:0];
            arp_pl[24]=LOCAL_IP[31:24]; arp_pl[25]=LOCAL_IP[23:16]; arp_pl[26]=LOCAL_IP[15:8]; arp_pl[27]=LOCAL_IP[7:0];
        end
    endtask

    task inject_arp_reply;
        begin
            build_arp_reply;
            @(posedge clk);
            rx_eth_hdr_valid <= 1;
            rx_eth_dest_mac  <= LOCAL_MAC;
            rx_eth_src_mac   <= PEER_MAC;
            rx_eth_type      <= 16'h0806;
            @(posedge clk);
            while (!rx_eth_hdr_ready) @(posedge clk);
            rx_eth_hdr_valid <= 0;
            for (ai = 0; ai < 28; ai = ai + 1) begin
                rx_eth_pl_tdata  <= arp_pl[ai];
                rx_eth_pl_tvalid <= 1;
                rx_eth_pl_tlast  <= (ai == 27);
                rx_eth_pl_tuser  <= 0;
                @(posedge clk);
                while (!rx_eth_pl_tready) @(posedge clk);
            end
            rx_eth_pl_tvalid <= 0;
            rx_eth_pl_tlast  <= 0;
            injecting <= 0;
        end
    endtask

    // drive the ARP reply when scheduled
    initial begin
        rx_eth_pl_tvalid = 0; rx_eth_pl_tlast = 0; rx_eth_pl_tuser = 0;
        rx_eth_dest_mac = 0; rx_eth_src_mac = 0; rx_eth_type = 0; rx_eth_pl_tdata = 0;
        wait (!rst);
        forever begin
            wait (arp_pending);
            injecting = 1;
            inject_arp_reply;
            repeat (4) @(posedge clk);
        end
    end

    // (checksum_gen internal probes removed; testing with UDP_CHECKSUM_GEN_ENABLE=0)
    // probe checksum-gen output inside udp.v
    reg cksum_out_seen = 0;
    always @(posedge clk) begin
        if (udp.udp_inst.tx_udp_hdr_valid) begin
            if (!cksum_out_seen) $display("[%0t] checksum_gen emitted udp hdr", $time);
            cksum_out_seen <= 1;
        end
    end
    // probe udp.v -> ip path
    reg udptx_seen = 0;
    always @(posedge clk) begin
        if (udp.udp_tx_ip_hdr_valid) begin
            if (!udptx_seen) $display("[%0t] udp_inst emitted IP hdr (udp_tx_ip_hdr_valid)", $time);
            udptx_seen <= 1;
        end
    end
    initial begin
        $dumpfile("/tmp/selftx.vcd");
        $dumpvars(0, udp_tx_streamer_tb);
        repeat (8) @(posedge clk); rst = 0;
        repeat (4000) @(posedge clk);
        $display("--- arp_reqs=%0d ip_frames=%0d hdr_ready_seen=%0d state=%0d pl_beats=%0d",
                 arp_reqs, ip_frames, hdr_ready_seen, dbg_state, pl_beats);
        if (ip_frames >= 1) $display("PASS: self-TX emitted %0d IP/UDP frame(s) after ARP", ip_frames);
        else $display("FAIL: no IP/UDP frame egressed (hdr_ready_seen=%0d arp_reqs=%0d)", hdr_ready_seen, arp_reqs);
        $finish;
    end

    // safety timeout
    initial begin #400000; $display("TIMEOUT"); $finish; end
endmodule

`default_nettype wire
