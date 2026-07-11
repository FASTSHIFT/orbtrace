// ddr3_selftest_top
// =================
// Proposal 32 P1: prove the A7-Lite DDR3 datapath (MIG calibration + native
// read/write) end-to-end on THIS board with THIS toolchain, BEFORE wiring it
// to the trace black box. Pure self-loop, LED-only status (stage3 net_test
// style: each stage introduces exactly one unknown).
//
//   50MHz osc -> clock IP (MMCM) -> 200MHz -> MIG sys_clk_i
//   MIG calibrates DDR3 (MT41K256M16, 512MB, x16, 800 MT/s)
//   -> ui_clk (50MHz), init_calib_complete
//   self-test FSM (ui_clk): write a known 128-bit counter pattern to N bursts,
//   read them back, compare. Any mismatch latches err_sticky.
//
// LED semantics (active-high; board LEDs may be inverted -- see xdc note):
//   led0 = init_calib_complete  (DDR3 calibrated)
//   led1 = test PASS heartbeat  (blinks ~1Hz once all bursts verified error-free;
//                                SOLID OFF = a compare error was latched)
//
// Reuses the vendor DDR3 abstraction layer (ddr3_ctrl + wr/rd/arbit), which is
// board-proven, plus the vendor clock + MIG IP (read via .xci in the build TCL).
// ddr3_wr_ctrl/ddr3_rd_ctrl move LENGTH 128-bit words per burst (default 64).
//
// BOARD-VERIFIED (2026-07-11): led0 solid + led1 ~1.5Hz blink = PASS (MIG
// calibrated, write/readback byte-exact).
//
// IMPORTANT POWER-UP NOTE: an openFPGALoader SRAM load is NOT enough for the
// DDR3 path -- after SRAM load the LEDs showed calib-ok/data-FAIL, and only a
// clean POWER CYCLE (re-plug / flash-boot) brought MIG up correctly (led1
// blinking). The MIG reset/power-up sequence does not complete cleanly on a
// bare SRAM reconfig. => ALL DDR3 bitstreams must be validated after a cold
// boot, not just an SRAM load (consistent with the network-PHY cold-boot rule).

`default_nettype none

module ddr3_selftest_top #(
    parameter integer LENGTH = 64        // 128-bit words per burst (MUST match the
                                         // vendor ddr3_wr_ctrl/ddr3_rd_ctrl default)
) (
    input  wire        sys_clk_50,   // 50MHz board oscillator (J19)
    input  wire        rst_n,        // active-low reset (L18)

    // DDR3 hardware interface
    output wire [14:0] ddr3_addr,
    output wire [2:0]  ddr3_ba,
    output wire        ddr3_cas_n,
    output wire [0:0]  ddr3_ck_n,
    output wire [0:0]  ddr3_ck_p,
    output wire [0:0]  ddr3_cke,
    output wire        ddr3_ras_n,
    output wire        ddr3_reset_n,
    output wire        ddr3_we_n,
    inout  wire [15:0] ddr3_dq,
    inout  wire [1:0]  ddr3_dqs_n,
    inout  wire [1:0]  ddr3_dqs_p,
    output wire [1:0]  ddr3_dm,
    output wire [0:0]  ddr3_odt,

    output wire        led0,          // init_calib_complete
    output wire        led1           // PASS heartbeat / FAIL solid-off
);
    // ---- 50 -> 200 MHz for MIG sys_clk_i (vendor clock IP) ----
    wire sys_clk_200, clk_locked;
    clock u_clock (
        .clk_out1(sys_clk_200),
        .resetn  (rst_n),
        .locked  (clk_locked),
        .clk_in1 (sys_clk_50)
    );

    // ---- DDR3 controller (vendor abstraction over MIG) ----
    wire        ui_clk, ui_rst, ddr3_busy;
    // write interface
    wire         wr_start;
    wire         wr_data_req;
    reg  [127:0] wr_data;
    wire         wr_addr_req;
    reg  [28:0]  wr_addr;
    wire         wr_done;
    // read interface
    wire         rd_start;
    wire         rd_addr_req;
    reg  [28:0]  rd_addr;
    wire         rd_data_vld;
    wire [127:0] rd_data;
    wire         rd_done;

    ddr3_ctrl u_ddr3 (
        .sys_clk    (sys_clk_200),
        .sys_rst_n  (clk_locked),      // MIG sys_rst is ACTIVE LOW; release on lock
        .ui_clk     (ui_clk),
        .ui_rst     (ui_rst),
        .calib_complete(),
        .ddr3_busy  (ddr3_busy),
        .ddr3_wr_start   (wr_start),
        .ddr3_wr_data_req(wr_data_req),
        .ddr3_wr_data    (wr_data),
        .ddr3_wr_addr_req(wr_addr_req),
        .ddr3_wr_addr    (wr_addr),
        .ddr3_wr_done    (wr_done),
        .ddr3_rd_start   (rd_start),
        .ddr3_rd_addr_req(rd_addr_req),
        .ddr3_rd_addr    (rd_addr),
        .ddr3_rd_data_vld(rd_data_vld),
        .ddr3_rd_data    (rd_data),
        .ddr3_rd_done    (rd_done),
        .ddr3_addr(ddr3_addr), .ddr3_ba(ddr3_ba), .ddr3_cas_n(ddr3_cas_n),
        .ddr3_ck_n(ddr3_ck_n), .ddr3_ck_p(ddr3_ck_p), .ddr3_cke(ddr3_cke),
        .ddr3_ras_n(ddr3_ras_n), .ddr3_reset_n(ddr3_reset_n), .ddr3_we_n(ddr3_we_n),
        .ddr3_dq(ddr3_dq), .ddr3_dqs_n(ddr3_dqs_n), .ddr3_dqs_p(ddr3_dqs_p),
        .ddr3_dm(ddr3_dm), .ddr3_odt(ddr3_odt)
    );

    // init_calib_complete is inside ddr3_ctrl; ui_rst deasserts only after
    // calibration completes (ui_rst = ui_clk_sync_rst | ~init_calib_complete),
    // so "ui_rst released" is a proxy for "calibrated". Surface a clean flag by
    // detecting ui_rst low for a while.
    reg calib_done = 0;
    always @(posedge ui_clk) if (!ui_rst) calib_done <= 1'b1;

    // ---- self-test FSM (ui_clk / 50MHz) ----
    // Mirrors the vendor ddr3_generate_data timing (board-proven): alternate a
    // full LENGTH-word WRITE burst then a READ burst; on each rd_data_vld
    // compare against the SAME per-word pattern. The vendor wr/rd ctrl own the
    // address counters (addr += 8 per addr_req, 4:1 PHY word stride); we only
    // supply/verify the data words. Runs continuously (wraps addresses via the
    // ctrls) so any DDR3 bit error eventually latches err_sticky.
    localparam S_ARBIT=0, S_WRITE=1, S_READ=2;
    reg [1:0]  st = S_ARBIT;
    reg        wr_rd_flag = 0;    // 0 = do a write burst, 1 = do a read burst
    reg [9:0]  wr_cnt = 0;        // word index within the write burst
    reg [9:0]  rd_cnt = 0;        // word index within the read burst
    reg        err_sticky = 0;
    reg [31:0] err_count  = 0;
    reg [31:0] pass_bursts = 0;   // read bursts verified error-free
    localparam [9:0] MAX_NUM = LENGTH-1;

    // per-word expected pattern (same on write and readback)
    function [127:0] patgen(input [9:0] w);
        patgen = {16{w[7:0]}} ^ {4{32'hA5A5_0000 | w}};
    endfunction

    assign wr_start = (wr_rd_flag == 1'b0) && (st == S_ARBIT) && calib_done;
    assign rd_start = (wr_rd_flag == 1'b1) && (st == S_ARBIT) && calib_done;

    // Addresses: the vendor ddr3_wr_ctrl/ddr3_rd_ctrl transparently pass
    // app_addr = ddr3_wr_addr/ddr3_rd_addr (they do NOT stride the address
    // themselves). The DATA SOURCE must advance the address on each addr_req,
    // exactly like the vendor ddr3_generate_data: +8 per app command (4:1 PHY,
    // one UI 128-bit word spans 8 DDR3 column addresses). Write and read each
    // advance independently but in lock-step across alternating bursts, so a
    // read burst always targets the region the matching write burst just wrote.
    always @(posedge ui_clk) begin
        if (ui_rst) wr_addr <= 29'd0;
        else if (wr_addr_req) wr_addr <= wr_addr + 29'd8;
    end
    always @(posedge ui_clk) begin
        if (ui_rst) rd_addr <= 29'd0;
        else if (rd_addr_req) rd_addr <= rd_addr + 29'd8;
    end

    always @(posedge ui_clk) begin
        if (ui_rst) begin
            st <= S_ARBIT; wr_rd_flag <= 0;
        end else begin
            case (st)
                S_ARBIT:
                    if (calib_done) begin
                        if (wr_rd_flag == 1'b0) st <= S_WRITE;
                        else                    st <= S_READ;
                    end
                S_WRITE: if (wr_done) begin st <= S_ARBIT; wr_rd_flag <= 1'b1; end
                S_READ:  if (rd_done) begin st <= S_ARBIT; wr_rd_flag <= 1'b0; end
            endcase
        end
    end

    // write data: COMBINATIONAL — ddr3_wr_ctrl samples app_wdf_data on the same
    // cycle it asserts wr_data_req, so a registered update is one cycle late
    // (stores the previous word). Drive from wr_cnt combinationally.
    always @(*) wr_data = patgen(wr_cnt);
    always @(posedge ui_clk) begin
        if (ui_rst) wr_cnt <= 0;
        else if (wr_data_req)
            wr_cnt <= (wr_cnt == MAX_NUM) ? 10'd0 : wr_cnt + 1'b1;
    end

    // compare read data on each rd_data_vld
    always @(posedge ui_clk) begin
        if (ui_rst) begin
            rd_cnt <= 0; err_sticky <= 0; err_count <= 0; pass_bursts <= 0;
        end else if (rd_data_vld) begin
            if (rd_data !== patgen(rd_cnt)) begin
                err_sticky <= 1'b1;
                err_count  <= err_count + 1'b1;
            end
            if (rd_cnt == MAX_NUM) begin
                rd_cnt <= 10'd0;
                if (!err_sticky) pass_bursts <= pass_bursts + 1'b1;
            end else begin
                rd_cnt <= rd_cnt + 1'b1;
            end
        end
    end

    // ---- LED status ----
    // led0 = calibrated (init_calib_complete). led1 = PASS heartbeat (~1.5Hz)
    // while at least one burst verified error-free AND no error ever latched;
    // led1 SOLID OFF = a compare error was latched (FAIL).
    reg [24:0] hb = 0;
    always @(posedge ui_clk) hb <= hb + 1'b1;
    wire pass = (pass_bursts != 0) && !err_sticky;
    assign led0 = calib_done;
    assign led1 = pass ? hb[24] : 1'b0;

    // Status outputs for the integrated readout path (proposal 32 P2):
    // exposed to the caller so they can be surfaced via the existing :5001
    // dbg_regfile readout (fpga_health.py DDR3 detector), instead of a
    // throwaway VIO/JTAG channel. In this standalone P1 top they also drive the
    // LEDs above; the integrated top wires them into dbg_regfile.
    // (kept as regs already: calib_done, err_sticky, err_count, pass_bursts)

endmodule

`default_nettype wire
