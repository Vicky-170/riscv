// =============================================================================
// tb_axi_err_slave.sv - V0..V5 for axi_err_slave (in axi4_interconnect.sv)
//   Run with -GRESP=3 (DECERR, interconnect use) and -GRESP=2 (SLVERR, ROM write reject).
//   The TB is an AXI master BFM: every read burst must return exactly len+1 beats,
//   each with rresp==RESP, rdata==0, rlast only on the final beat; every write
//   (AW then W beats up to wlast) must be swallowed and answered by exactly ONE B
//   with bresp==RESP - even when the master delays RREADY/BREADY or W beats.
// =============================================================================
module tb_axi_err_slave import rv32im_pkg::*;;
  `include "tb_common.svh"

  parameter logic [1:0] RESP = AXI_RESP_DECERR;

  logic     clk = 0, rst_n = 0;
  axi_req_t req;                       // NOTE: no declaration initializer (Verilator 5.020 quirk, see report)
  axi_rsp_t rsp;

  always #5 clk = ~clk;
  always @(posedge clk) cyc++;

  axi_err_slave #(.RESP(RESP)) dut (.clk(clk), .rst_n(rst_n), .req(req), .rsp(rsp));

  // ---- V3 assertions --------------------------------------------------------------------
  ap_r_stable: assert property (@(posedge clk) disable iff (!rst_n)
      (rsp.rvalid && !req.rready) |=> (rsp.rvalid && $stable(rsp.rlast) && $stable(rsp.rresp)));
  ap_b_stable: assert property (@(posedge clk) disable iff (!rst_n)
      (rsp.bvalid && !req.bready) |=> (rsp.bvalid && $stable(rsp.bresp)));
  ap_one_resp: assert property (@(posedge clk) disable iff (!rst_n) !(rsp.rvalid && rsp.bvalid));
  ap_r_resp:   assert property (@(posedge clk) disable iff (!rst_n) rsp.rvalid |-> (rsp.rresp == RESP && rsp.rdata == 0));
  ap_b_resp:   assert property (@(posedge clk) disable iff (!rst_n) rsp.bvalid |-> (rsp.bresp == RESP));
  ap_no_ready_busy: assert property (@(posedge clk) disable iff (!rst_n)
      (rsp.rvalid || rsp.bvalid) |-> (!rsp.arready && !rsp.awready));

  int n_r_beats = 0, n_b = 0;
  bit r_bad_resp = 0, r_bad_last = 0;

  // ---- transaction tasks -------------------------------------------------------------------
  task automatic do_read(input logic [7:0] len, input int rready_pct, input bit is_rand);
    int beats = 0, guard = 0;
    bit bad_last = 0, bad_resp = 0;
    @(negedge clk);
    req.arvalid = 1; req.araddr = 32'h1000; req.arlen = len;
    #1;
    while (!rsp.arready && guard < 200) begin @(negedge clk); #1; guard++; end
    @(posedge clk); @(negedge clk);
    req.arvalid = 0;
    guard = 0;
    while (beats <= int'(len) && guard < 1000) begin
      req.rready = ($urandom_range(0, 99) < rready_pct);
      #1;
      if (rsp.rvalid && req.rready) begin
        if (rsp.rresp != RESP) bad_resp = 1;
        if (rsp.rlast != (beats == int'(len))) bad_last = 1;
        beats++;
      end
      @(negedge clk); guard++;
    end
    req.rready = 0;
    repeat (2) @(negedge clk);
    if (is_rand) begin
      rchk("read_beats", 64'(len) + 1, 64'(beats));
      rchk("read_resp", 0, {63'd0, bad_resp});
      rchk("read_last", 0, {63'd0, bad_last});
      rchk("no_extra_rvalid", 0, {63'd0, rsp.rvalid});
    end else begin
      chk("read_beats", 64'(len) + 1, 64'(beats));
      chk("read_resp", 0, {63'd0, bad_resp});
      chk("read_last", 0, {63'd0, bad_last});
      chk("no_extra_rvalid", 0, {63'd0, rsp.rvalid});
    end
    if (len == 0) cov_hit(0); else cov_hit(1);
    if (rready_pct < 100) cov_hit(2);
  endtask

  task automatic do_write(input int nbeats, input int wgap_pct, input int bready_pct, input bit w_first, input bit is_rand);
    int sent = 0, guard = 0, bs = 0;
    bit got_b = 0;
    @(negedge clk);
    req.awaddr = 32'h2000;
    if (!w_first) req.awvalid = 1;
    else begin                                        // W presented before the address handshake completes
      req.wvalid = 1; req.wdata = $urandom(); req.wlast = (nbeats == 1); req.wstrb = 4'hF;
    end
    #1;
    guard = 0;
    while (!(req.awvalid && rsp.awready) && guard < 200) begin
      @(negedge clk);
      if (w_first && guard == 3) req.awvalid = 1;
      #1; guard++;
    end
    @(posedge clk); @(negedge clk);
    req.awvalid = 0;
    // W beats (wready only after AW has been accepted)
    guard = 0;
    while (sent < nbeats && guard < 1000) begin
      if (!req.wvalid && ($urandom_range(0, 99) >= wgap_pct)) begin
        req.wvalid = 1; req.wdata = $urandom(); req.wstrb = 4'hF; req.wlast = (sent == nbeats - 1);
      end
      #1;
      if (req.wvalid && rsp.wready) begin
        @(posedge clk); @(negedge clk);
        req.wvalid = 0; sent++;
      end else begin @(negedge clk); end
      guard++;
    end
    req.wvalid = 0; req.wlast = 0;
    guard = 0;
    while (!got_b && guard < 500) begin
      req.bready = ($urandom_range(0, 99) < bready_pct);
      #1;
      if (rsp.bvalid && req.bready) begin
        got_b = 1; bs = 1;
        chk_t("b_resp_value", rsp.bresp == RESP);
      end
      @(negedge clk); guard++;
    end
    req.bready = 0;
    repeat (3) @(negedge clk);
    if (is_rand) begin
      rchk("all_w_accepted", 64'(nbeats), 64'(sent));
      rchk("one_b", 1, 64'(bs));
      rchk("no_second_b", 0, {63'd0, rsp.bvalid});
    end else begin
      chk("all_w_accepted", 64'(nbeats), 64'(sent));
      chk("one_b", 1, 64'(bs));
      chk("no_second_b", 0, {63'd0, rsp.bvalid});
    end
    cov_hit(3);
    if (nbeats > 1) cov_hit(4);
    if (w_first) cov_hit(5);
    if (bready_pct < 100) cov_hit(6);
  endtask

  initial begin
    tb_init($sformatf("axi_err_slave_r%0d", RESP));
    cov_def(0,"read_single"); cov_def(1,"read_burst"); cov_def(2,"rready_backpressure");
    cov_def(3,"write"); cov_def(4,"write_burst"); cov_def(5,"w_before_aw"); cov_def(6,"bready_backpressure");
    req = AXI_REQ_IDLE;
    repeat (3) @(negedge clk);
    rst_n = 1; @(negedge clk);
    // idle: the slave must be ready for either address channel
    #1; chk("idle_no_valid", 0, {62'd0, rsp.rvalid, rsp.bvalid});
    // ---- V1 directed ----------------------------------------------------------------------
    do_read(8'd0, 100, 0);
    do_read(8'd3, 100, 0);
    do_read(8'd7, 30, 0);                              // slow master
    do_read(8'd15, 100, 0);
    do_write(1, 0, 100, 0, 0);
    do_write(4, 0, 100, 0, 0);
    do_write(4, 60, 30, 0, 0);                         // gappy W, delayed BREADY
    do_write(2, 0, 100, 1, 0);                         // W offered before AW handshake
    do_read(8'd0, 100, 0);                             // back to a read right after a write
    // simultaneous AR and AW: the read is served first (documented priority), then the
    // still-pending write is accepted and completed
    @(negedge clk); req.arvalid = 1; req.araddr = 32'h1000; req.arlen = 8'd1; req.awvalid = 1; req.awaddr = 32'h2000;
    #1; chk("read_priority_arready", 1, {63'd0, rsp.arready});
    chk("read_priority_no_awready", 0, {63'd0, rsp.awready});
    @(posedge clk); @(negedge clk); req.arvalid = 0; req.rready = 1;
    repeat (2) @(negedge clk);                          // two R beats consumed
    req.rready = 0; #1;
    chk("write_accepted_after_read", 1, {63'd0, rsp.awready});
    @(posedge clk); @(negedge clk); req.awvalid = 0;
    req.wvalid = 1; req.wlast = 1; req.wstrb = 4'hF; #1;
    chk("wready_after_aw", 1, {63'd0, rsp.wready});
    @(posedge clk); @(negedge clk); req.wvalid = 0; req.wlast = 0; req.bready = 1;
    #1; chk("b_after_wlast", 1, {63'd0, rsp.bvalid});
    @(posedge clk); @(negedge clk); req.bready = 0;
    repeat (2) @(negedge clk);
    // reset mid-transaction returns to idle
    do_read(8'd7, 20, 0);
    @(negedge clk); req.arvalid = 1; req.arlen = 8'd7; @(negedge clk); req.arvalid = 0;
    repeat (2) @(negedge clk);
    rst_n = 0; @(negedge clk); @(negedge clk); rst_n = 1; @(negedge clk); #1;
    chk("idle_after_reset", 0, {62'd0, rsp.rvalid, rsp.bvalid});
    do_read(8'd2, 100, 0);

    // ---- V2/V5: 60 randomized transactions per configuration -----------------------------------
    for (int i = 0; i < 60; i++) begin
      if ($urandom_range(0, 1)) do_read(8'($urandom_range(0, 15)), $urandom_range(20, 100), 1);
      else do_write($urandom_range(1, 6), $urandom_range(0, 70), $urandom_range(20, 100),
                    ($urandom_range(0, 3) == 0), 1);
    end
    finish_report();
    $finish;
  end
endmodule
