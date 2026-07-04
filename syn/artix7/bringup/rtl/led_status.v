// led_status.v
// =============
// Dual-LED status indicator for the A7-Lite trace streaming system.
// Two LEDs, each with 4 priority-encoded states (off / slow-blink / fast-blink
// / steady), driven by system health signals.
//
// LED polarity: ACTIVE-LOW on A7-Lite (0 = lit, 1 = off).
//
// led0 (M18) — NETWORK status:
//   off      : system MMCM not locked (FPGA not up)
//   slow 1Hz : MMCM locked, PHY released, but no TX streaming
//   fast 4Hz : RX frames arriving (link up, ARP/ping traffic)
//   steady   : continuous UDP TX active (normal streaming state)
//
// led1 (N18) — TRACE CAPTURE status:
//   off      : trace MMCM not locked (no TRACECLK / wrong freq)
//   slow 1Hz : MMCM locked + cap_valid, but no packets sent yet
//   fast 4Hz : normal streaming (packets being sent, no loss)
//   steady   : ALARM — FIFO overflow detected (lost_cnt > 0), latched
//
// Clock: clk125 (125 MHz).
//   125M / 2^25 ≈ 3.7 Hz  (fast blink half-period)
//   125M / 2^27 ≈ 0.93 Hz (slow blink half-period)

`default_nettype none

module led_status #(
    parameter integer RX_WINDOW_BITS = 23   // ~67ms window for RX activity detect
) (
    input  wire        clk,           // 125 MHz
    input  wire        rst,

    // Network status inputs
    input  wire        sys_mmcm_locked,
    input  wire        rx_good_frame,     // pulse per good RX frame
    input  wire        tx_axis_tvalid,    // MAC TX active

    // Trace status inputs
    input  wire        trace_mmcm_locked,
    input  wire        pkt_active,        // a UDP trace packet is in flight
    input  wire [31:0] lost_cnt,          // capture-side FIFO drop counter

    // LED outputs (directly to pads, active-low)
    output wire        led0,
    output wire        led1
);

    // ---- free-running counter for blink generation ----
    reg [27:0] cnt;
    always @(posedge clk) begin
        if (rst) cnt <= 28'd0;
        else     cnt <= cnt + 28'd1;
    end

    wire blink_fast = cnt[25];   // toggles at ~3.7 Hz
    wire blink_slow = cnt[27];   // toggles at ~0.93 Hz

    // ---- RX activity detector: any rx_good_frame in the last ~67ms window ----
    reg [RX_WINDOW_BITS-1:0] rx_timer;
    reg rx_recent;
    always @(posedge clk) begin
        if (rst) begin
            rx_timer <= 0;
            rx_recent <= 1'b0;
        end else if (rx_good_frame) begin
            rx_timer <= {RX_WINDOW_BITS{1'b1}};
            rx_recent <= 1'b1;
        end else if (rx_timer != 0) begin
            rx_timer <= rx_timer - 1'b1;
        end else begin
            rx_recent <= 1'b0;
        end
    end

    // ---- TX streaming detector: tx_axis_tvalid high for sustained period ----
    // Use a leaky counter: increment on tvalid, decrement otherwise; "streaming"
    // when counter > half-full. This smooths single-packet bursts vs real stream.
    reg [15:0] tx_bucket;
    wire tx_streaming = tx_bucket[15];   // MSB = counter > 32768
    always @(posedge clk) begin
        if (rst) begin
            tx_bucket <= 16'd0;
        end else if (tx_axis_tvalid && !(&tx_bucket)) begin
            tx_bucket <= tx_bucket + 16'd1;
        end else if (!tx_axis_tvalid && tx_bucket != 16'd0) begin
            tx_bucket <= tx_bucket - 16'd1;
        end
    end

    // ---- Trace packet activity: any pkt_active in last ~67ms ----
    reg [RX_WINDOW_BITS-1:0] pkt_timer;
    reg pkt_recent;
    always @(posedge clk) begin
        if (rst) begin
            pkt_timer <= 0;
            pkt_recent <= 1'b0;
        end else if (pkt_active) begin
            pkt_timer <= {RX_WINDOW_BITS{1'b1}};
            pkt_recent <= 1'b1;
        end else if (pkt_timer != 0) begin
            pkt_timer <= pkt_timer - 1'b1;
        end else begin
            pkt_recent <= 1'b0;
        end
    end

    // ---- Trace loss alarm: latch once lost_cnt > 0 (cleared only by reset) ----
    reg trace_alarm;
    always @(posedge clk) begin
        if (rst)                  trace_alarm <= 1'b0;
        else if (lost_cnt != 0)  trace_alarm <= 1'b1;
    end

    // ---- LED0: network status (active-low: 0=lit, 1=off) ----
    // Priority: not-locked > streaming > rx-activity > idle
    reg led0_r;
    always @(*) begin
        if (!sys_mmcm_locked)
            led0_r = 1'b1;            // off (not up)
        else if (tx_streaming)
            led0_r = 1'b0;            // steady ON (streaming)
        else if (rx_recent)
            led0_r = blink_fast;      // fast blink (link active)
        else
            led0_r = blink_slow;      // slow blink (idle)
    end
    assign led0 = led0_r;

    // ---- LED1: trace capture status (active-low) ----
    // Priority: not-locked > alarm > streaming > idle
    reg led1_r;
    always @(*) begin
        if (!trace_mmcm_locked)
            led1_r = 1'b1;            // off (no trace clock)
        else if (trace_alarm)
            led1_r = 1'b0;            // steady ON = ALARM (FIFO loss!)
        else if (pkt_recent)
            led1_r = blink_fast;      // fast blink (normal streaming)
        else
            led1_r = blink_slow;      // slow blink (locked, waiting)
    end
    assign led1 = led1_r;

endmodule

`default_nettype wire
