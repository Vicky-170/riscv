// =============================================================================
// tb_axi4_master.sv - V0..V5 for axi4_master.sv   (-GREAD_ONLY=0/1)
//
// Environment
//   native side : this TB issues read/write commands and collects native responses
//   AXI side    : independent slave BFM with per-channel random ready (backpressure),
//                 random R-beat gaps, random B delay, error windows (SLVERR/DECERR),
//                 AW and W accepted in either order (p_aw / p_w knobs)
// Scoreboard    : every native command must produce the exact AXI transaction
//                 (address/len/size/burst; single W beat with strobes, wlast=1) and
//                 the exact native response stream (data, order, rsp_last, rsp_err).
// Protocol assertions (V3): VALID/payload stability until READY, constant fields,
//                 never AR and AW together, BREADY only after AW and W both completed,
//                 RREADY only while a read is outstanding, req_ready only when idle.
// =============================================================================
module tb_axi4_master import rv32im_pkg::*;;
  `include "tb_common.svh"

  parameter bit READ_ONLY = 1'b0;

  logic        clk = 0, rst_n = 0;
  logic        req_valid = 0, req_write = 0, req_ready;
  logic [31:0] req_addr = 0, req_wdata = 0;
  logic [7:0]  req_len = 0;
  logic [3:0]  req_wstrb = 0;
  logic        rsp_valid, rsp_last, rsp_err;
  logic [31:0] rsp_data;
  axi_req_t    m_req;
  axi_rsp_t    m_rsp;

  always #5 clk = ~clk;
  always @(posedge clk) cyc++;

  axi4_master #(.READ_ONLY(READ_ONLY)) dut (.*);

  // ---------------------------------------------------------------- AXI slave BFM
  int unsigned p_ar = 100, p_aw = 100, p_w = 100, p_r = 100, p_b = 100;   // ready/valid probabilities (%)
  logic [31:0] sm [1024];
  logic [31:0] err_lo = 32'hFFFF_FFFF, err_hi = 0;
  logic [1:0]  errcode = AXI_RESP_SLVERR;

  function automatic logic [31:0] pat(input int unsigned i); return 32'hA5A5_0000 ^ (i * 32'h0001_0101); endfunction
  function automatic bit ierr(input logic [31:0] a); return (a >= err_lo && a <= err_hi); endfunction

  bit arok = 0, awok = 0, wok = 0;
  int rd_st = 0, wr_st = 0, b_dly = 0;
  logic [31:0] rd_addr, aw_addr, w_data;
  logic [7:0]  rd_len;
  int          rd_beat = 0;
  bit          aw_got = 0, w_got = 0;
  logic [3:0]  w_strb;
  bit          rvalid_w = 0, rlast_w = 0, bvalid_w = 0;
  logic [31:0] rdata_w = 0;
  logic [1:0]  rresp_w = 0, bresp_w = 0;
  // captured AXI-side observations for the scoreboard
  logic [31:0] seen_ar_addr, seen_aw_addr, seen_w_data;
  logic [7:0]  seen_ar_len, seen_aw_len;
  logic [2:0]  seen_ar_size, seen_aw_size;
  logic [1:0]  seen_ar_burst, seen_aw_burst;
  logic [3:0]  seen_w_strb;
  bit          seen_w_last;
  int unsigned n_ar = 0, n_aw = 0, n_w = 0, n_b = 0;
  bit          aw_first = 0, w_first = 0;

  wire arready_w = (rd_st == 0) && arok;
  wire awready_w = !aw_got && awok;
  wire wready_w  = !w_got && wok;
  assign m_rsp = {awready_w, wready_w, bresp_w, bvalid_w, arready_w, rdata_w, rresp_w, rlast_w, rvalid_w};

  always @(posedge clk) begin
    bit ar_hs, aw_hs, w_hs, aw_done, w_done;
    logic [31:0] eff_aw, eff_wd;
    logic [3:0]  eff_ws;
    arok <= ($urandom_range(0, 99) < p_ar);
    awok <= ($urandom_range(0, 99) < p_aw);
    wok  <= ($urandom_range(0, 99) < p_w);
    if (!rst_n) begin
      rd_st <= 0; wr_st <= 0; aw_got <= 0; w_got <= 0; rvalid_w <= 0; bvalid_w <= 0;
    end else begin
      ar_hs = m_req.arvalid && arready_w;
      aw_hs = m_req.awvalid && awready_w;
      w_hs  = m_req.wvalid  && wready_w;
      // ---- read channel
      if (ar_hs) begin
        rd_addr <= m_req.araddr; rd_len <= m_req.arlen; rd_beat <= 0; rd_st <= 1;
        seen_ar_addr <= m_req.araddr; seen_ar_len <= m_req.arlen;
        seen_ar_size <= m_req.arsize; seen_ar_burst <= m_req.arburst; n_ar = n_ar + 1;
      end
      if (rd_st == 1) begin
        if (!rvalid_w) begin
          if ($urandom_range(0, 99) < p_r) begin
            rvalid_w <= 1; rdata_w <= sm[((rd_addr >> 2) + rd_beat) % 1024];
            rlast_w  <= (rd_beat == int'(rd_len));
            rresp_w  <= ierr(rd_addr + 32'(4 * rd_beat)) ? errcode : AXI_RESP_OKAY;
          end
        end else if (m_req.rready) begin
          rvalid_w <= 0;
          if (rlast_w) rd_st <= 0; else rd_beat <= rd_beat + 1;
        end
      end
      // ---- write channels (AW and W complete independently)
      if (aw_hs) begin
        aw_got <= 1; aw_addr <= m_req.awaddr; seen_aw_addr <= m_req.awaddr; seen_aw_len <= m_req.awlen;
        seen_aw_size <= m_req.awsize; seen_aw_burst <= m_req.awburst; n_aw = n_aw + 1;
        if (!w_got && !w_hs) aw_first = 1;
      end
      if (w_hs) begin
        w_got <= 1; w_data <= m_req.wdata; w_strb <= m_req.wstrb; seen_w_data <= m_req.wdata;
        seen_w_strb <= m_req.wstrb; seen_w_last <= m_req.wlast; n_w = n_w + 1;
        if (!aw_got && !aw_hs) w_first = 1;
      end
      aw_done = aw_got || aw_hs;
      w_done  = w_got  || w_hs;
      eff_aw = aw_hs ? m_req.awaddr : aw_addr;
      eff_wd = w_hs ? m_req.wdata : w_data;
      eff_ws = w_hs ? m_req.wstrb : w_strb;
      case (wr_st)
        0: if (aw_done && w_done) begin
             if (!ierr(eff_aw))
               for (int b = 0; b < 4; b++)
                 if (eff_ws[b]) sm[(eff_aw >> 2) % 1024][8*b +: 8] <= eff_wd[8*b +: 8];
             bresp_w <= ierr(eff_aw) ? errcode : AXI_RESP_OKAY;
             b_dly <= $urandom_range(0, 3); wr_st <= 1;
           end
        1: if (b_dly > 0) b_dly <= b_dly - 1;
           else if ($urandom_range(0, 99) < p_b) begin bvalid_w <= 1; wr_st <= 2; end
        2: if (m_req.bready) begin
             bvalid_w <= 0; wr_st <= 0; aw_got <= 0; w_got <= 0; n_b = n_b + 1;
           end
        default: wr_st <= 0;
      endcase
    end
  end

  // ---------------------------------------------------------------- V3 protocol assertions
  ap_ar_stable: assert property (@(posedge clk) disable iff (!rst_n)
      (m_req.arvalid && !m_rsp.arready) |=> (m_req.arvalid && $stable(m_req.araddr) && $stable(m_req.arlen)));
  ap_aw_stable: assert property (@(posedge clk) disable iff (!rst_n)
      (m_req.awvalid && !m_rsp.awready) |=> (m_req.awvalid && $stable(m_req.awaddr) && $stable(m_req.awlen)));
  ap_w_stable:  assert property (@(posedge clk) disable iff (!rst_n)
      (m_req.wvalid && !m_rsp.wready) |=> (m_req.wvalid && $stable(m_req.wdata) && $stable(m_req.wstrb)));
  ap_fixed_ar:  assert property (@(posedge clk) disable iff (!rst_n)
      m_req.arvalid |-> (m_req.arsize == 3'b010 && m_req.arburst == AXI_BURST_INCR));
  ap_fixed_aw:  assert property (@(posedge clk) disable iff (!rst_n)
      m_req.awvalid |-> (m_req.awsize == 3'b010 && m_req.awburst == AXI_BURST_INCR && m_req.awlen == 0));
  ap_wlast:     assert property (@(posedge clk) disable iff (!rst_n) m_req.wvalid |-> m_req.wlast);
  ap_no_ar_aw:  assert property (@(posedge clk) disable iff (!rst_n) !(m_req.arvalid && m_req.awvalid));
  ap_idle_ready: assert property (@(posedge clk) disable iff (!rst_n)
      req_ready |-> (!m_req.arvalid && !m_req.awvalid && !m_req.wvalid && !m_req.rready && !m_req.bready));
  ap_no_rsp_idle: assert property (@(posedge clk) disable iff (!rst_n) rsp_valid |-> !req_ready);
  ap_ro_noaw: assert property (@(posedge clk) disable iff (!rst_n)
      READ_ONLY |-> (!m_req.awvalid && !m_req.wvalid && !m_req.bready));
  // BREADY only after both AW and W have completed for the current write
  ap_bready_order: assert property (@(posedge clk) disable iff (!rst_n) m_req.bready |-> (aw_got && w_got));
  ap_rready_outstanding: assert property (@(posedge clk) disable iff (!rst_n) m_req.rready |-> (rd_st != 0));

  // ---------------------------------------------------------------- native response monitor
  logic [31:0] rq_data [64];  bit rq_last [64];  bit rq_err [64];
  int          rq_n = 0;
  always @(posedge clk) if (rst_n && rsp_valid) begin
    if (rq_n < 64) begin rq_data[rq_n] = rsp_data; rq_last[rq_n] = rsp_last; rq_err[rq_n] = rsp_err; end
    rq_n = rq_n + 1;
  end

  // ---------------------------------------------------------------- native drivers / scoreboard
  task automatic issue(input bit wr, input logic [31:0] a, input logic [7:0] len,
                       input logic [31:0] wd, input logic [3:0] ws);
    int guard = 0;
    @(negedge clk);
    rq_n = 0;
    req_valid = 1; req_write = wr; req_addr = a; req_len = len; req_wdata = wd; req_wstrb = ws;
    #1;
    while (!req_ready && guard < 500) begin @(negedge clk); #1; guard++; end   // wait for idle
    @(posedge clk);                                                            // command accepted
    @(negedge clk);
    req_valid = 0; req_write = 0;
  endtask

  task automatic wait_done(input string nm);
    int guard = 0;
    while (guard < 2000 && !(rq_n > 0 && rq_last[(rq_n > 64) ? 63 : rq_n - 1] && req_ready)) begin
      @(negedge clk); guard++;
    end
    if (guard >= 2000) chk({nm, "_TIMEOUT"}, 64'd1, 64'd0);
    repeat (2) @(negedge clk);
  endtask

  task automatic do_read(input logic [31:0] a, input logic [7:0] len, input bit is_rand);
    bit          exp_err;
    logic [31:0] exp_d;
    string       cfg;
    cfg = $sformatf("rd_len%0d_pr%0d", len, p_r);
    issue(0, a, len, 32'd0, 4'h0);
    wait_done("read");
    // ---- AXI-side transaction contents
    if (is_rand) rchk("ar_fields", {a, 24'd0, len} , {seen_ar_addr, 24'd0, seen_ar_len});
    else begin
      chk("ar_addr", {32'd0, a}, {32'd0, seen_ar_addr});
      chk("ar_len",  {56'd0, len}, {56'd0, seen_ar_len});
      chk("ar_size_burst", {59'd0, 3'b010, 2'b01}, {59'd0, seen_ar_size, seen_ar_burst});
    end
    // ---- native response stream
    if (is_rand) rchk("beat_count", 64'(len) + 1, 64'(rq_n));
    else         chk("beat_count", 64'(len) + 1, 64'(rq_n));
    for (int i = 0; i <= int'(len) && i < rq_n && i < 64; i++) begin
      exp_d   = sm[((a >> 2) + i) % 1024];
      exp_err = ierr(a + 32'(4 * i));
      if (is_rand) begin
        rchk("beat_data", {32'd0, exp_d} & (exp_err ? 64'h0 : 64'hFFFF_FFFF), {32'd0, rq_data[i]} & (exp_err ? 64'h0 : 64'hFFFF_FFFF));
        rchk("beat_last", {63'd0, (i == int'(len))}, {63'd0, rq_last[i]});
        rchk("beat_err",  {63'd0, exp_err}, {63'd0, rq_err[i]});
      end else begin
        chk($sformatf("beat%0d_data", i), {32'd0, exp_d} & (exp_err ? 64'h0 : 64'hFFFF_FFFF), {32'd0, rq_data[i]} & (exp_err ? 64'h0 : 64'hFFFF_FFFF));
        chk($sformatf("beat%0d_last", i), {63'd0, (i == int'(len))}, {63'd0, rq_last[i]});
        chk($sformatf("beat%0d_err", i),  {63'd0, exp_err}, {63'd0, rq_err[i]});
      end
      if (exp_err) cov_hit(6);
    end
    cov_hit(0); if (len != 0) cov_hit(1);
    if (p_r < 100 || p_ar < 100) cov_hit(7);
  endtask

  task automatic do_write(input logic [31:0] a, input logic [31:0] d, input logic [3:0] s, input bit is_rand);
    bit          exp_err;
    logic [31:0] exp_mem;
    int          n_aw0 = n_aw, n_w0 = n_w, n_b0 = n_b;
    exp_err = ierr(a);
    // reference memory update mirrors the strobes (unless the slave errors)
    exp_mem = sm[(a >> 2) % 1024];
    for (int b = 0; b < 4; b++) if (s[b] && !exp_err) exp_mem[8*b +: 8] = d[8*b +: 8];
    issue(1, a, 8'd0, d, s);
    wait_done("write");
    if (is_rand) begin
      rchk("aw_addr", {32'd0, a}, {32'd0, seen_aw_addr});
      rchk("w_data_strb", {32'd0, d & {{8{s[3]}}, {8{s[2]}}, {8{s[1]}}, {8{s[0]}}}, s},
                          {32'd0, seen_w_data & {{8{seen_w_strb[3]}}, {8{seen_w_strb[2]}}, {8{seen_w_strb[1]}}, {8{seen_w_strb[0]}}}, seen_w_strb});
      rchk("one_response", 64'd1, 64'(rq_n));
      rchk("resp_err", {63'd0, exp_err}, {63'd0, rq_err[0]});
      rchk("mem_updated", {32'd0, exp_mem}, {32'd0, sm[(a >> 2) % 1024]});
    end else begin
      chk("aw_addr", {32'd0, a}, {32'd0, seen_aw_addr});
      chk("aw_len_size_burst", {56'd0, 8'd0} | {59'd0, 3'b010, 2'b01}, {56'd0, seen_aw_len} | {59'd0, seen_aw_size, seen_aw_burst});
      chk("w_data", {32'd0, d & {{8{s[3]}}, {8{s[2]}}, {8{s[1]}}, {8{s[0]}}}},
                    {32'd0, seen_w_data & {{8{seen_w_strb[3]}}, {8{seen_w_strb[2]}}, {8{seen_w_strb[1]}}, {8{seen_w_strb[0]}}}});
      chk("w_strb", {60'd0, s}, {60'd0, seen_w_strb});
      chk("w_last", 64'd1, {63'd0, seen_w_last});
      chk("exactly_one_aw_w_b", 64'(n_aw0 + 1) | (64'(n_w0 + 1) << 20) | (64'(n_b0 + 1) << 40),
                                64'(n_aw) | (64'(n_w) << 20) | (64'(n_b) << 40));
      chk("one_response", 64'd1, 64'(rq_n));
      chk("resp_last", 64'd1, {63'd0, rq_last[0]});
      chk("resp_err", {63'd0, exp_err}, {63'd0, rq_err[0]});
      chk("mem_updated", {32'd0, exp_mem}, {32'd0, sm[(a >> 2) % 1024]});
    end
    cov_hit(2);
    if (s != 4'hF) cov_hit(3);
    if (exp_err) cov_hit(8);
    if (aw_first) cov_hit(4);
    if (w_first)  cov_hit(5);
    aw_first = 0; w_first = 0;
  endtask

  initial begin
    tb_init($sformatf("axi4_master_ro%0d", READ_ONLY));
    cov_def(0,"read_single"); cov_def(1,"read_burst"); cov_def(2,"write"); cov_def(3,"write_partial_strobe");
    cov_def(4,"aw_before_w"); cov_def(5,"w_before_aw"); cov_def(6,"read_error_beat");
    cov_def(7,"backpressure_read"); cov_def(8,"write_error");
    for (int i = 0; i < 1024; i++) sm[i] = pat(i);
    repeat (3) @(negedge clk);
    rst_n = 1; @(negedge clk);

    // ---- V1: reads -------------------------------------------------------------------
    do_read(32'h0000_0040, 8'd0, 0);
    do_read(32'h0000_0100, 8'd3, 0);
    do_read(32'h0000_0200, 8'd7, 0);
    do_read(32'h0000_03F0, 8'd1, 0);
    // backpressure: slow AR, slow R beats
    p_ar = 20; p_r = 25;
    do_read(32'h0000_0080, 8'd0, 0);
    do_read(32'h0000_0180, 8'd5, 0);
    p_ar = 100; p_r = 100;
    // errors: SLVERR and DECERR on a window, burst crossing the window edge
    err_lo = 32'h0000_0110; err_hi = 32'h0000_011F; errcode = AXI_RESP_SLVERR;
    do_read(32'h0000_0100, 8'd7, 0);
    errcode = AXI_RESP_DECERR;
    do_read(32'h0000_0110, 8'd0, 0);
    err_lo = 32'hFFFF_FFFF; err_hi = 0; errcode = AXI_RESP_SLVERR;

    if (!READ_ONLY) begin
      // ---- V1: writes -------------------------------------------------------------------
      do_write(32'h0000_0040, 32'h1122_3344, 4'hF, 0);
      do_write(32'h0000_0044, 32'hAABB_CCDD, 4'b0011, 0);
      do_write(32'h0000_0048, 32'hAABB_CCDD, 4'b1100, 0);
      do_write(32'h0000_004C, 32'hFFFF_FFFF, 4'b0101, 0);
      do_read (32'h0000_0040, 8'd3, 0);                       // read back through the same path
      // AW accepted long before W, and the reverse
      p_aw = 100; p_w = 10;  do_write(32'h0000_0100, 32'h0000_0001, 4'hF, 0);
      p_aw = 10;  p_w = 100; do_write(32'h0000_0104, 32'h0000_0002, 4'hF, 0);
      p_aw = 30;  p_w = 30;  p_b = 30; do_write(32'h0000_0108, 32'h0000_0003, 4'hF, 0);
      p_aw = 100; p_w = 100; p_b = 100;
      // write error
      err_lo = 32'h0000_0300; err_hi = 32'h0000_030F; errcode = AXI_RESP_SLVERR;
      do_write(32'h0000_0304, 32'hDEAD_BEEF, 4'hF, 0);
      errcode = AXI_RESP_DECERR;
      do_write(32'h0000_0308, 32'hDEAD_BEEF, 4'hF, 0);
      err_lo = 32'hFFFF_FFFF; err_hi = 0; errcode = AXI_RESP_SLVERR;
      // mid-transaction reset: master must return to idle and accept a new command
      @(negedge clk); req_valid = 1; req_write = 0; req_addr = 32'h40; req_len = 8'd7;
      @(negedge clk); req_valid = 0; p_r = 10;
      repeat (2) @(negedge clk);
      rst_n = 0; @(negedge clk); @(negedge clk); rst_n = 1; p_r = 100; @(negedge clk);
      chk("ready_after_reset", 64'd1, {63'd0, req_ready});
      do_read(32'h0000_0080, 8'd1, 0);
    end

    // ---- V2/V5: 110 randomized transactions -----------------------------------------------
    for (int i = 0; i < ((READ_ONLY) ? 50 : 110); i++) begin
      logic [31:0] a;
      p_ar = $urandom_range(0, 1) ? 100 : $urandom_range(20, 80);
      p_aw = $urandom_range(0, 1) ? 100 : $urandom_range(20, 80);
      p_w  = $urandom_range(0, 1) ? 100 : $urandom_range(20, 80);
      p_r  = $urandom_range(0, 1) ? 100 : $urandom_range(20, 80);
      p_b  = $urandom_range(0, 1) ? 100 : $urandom_range(20, 80);
      if ($urandom_range(0, 9) == 0) begin
        err_lo = 32'h0000_0100 + 32'($urandom_range(0, 7) * 16); err_hi = err_lo + 32'd15;
        errcode = $urandom_range(0, 1) ? AXI_RESP_SLVERR : AXI_RESP_DECERR;
      end else if ($urandom_range(0, 4) == 0) begin err_lo = 32'hFFFF_FFFF; err_hi = 0; end
      a = 32'($urandom_range(16, 200)) * 4;
      if (READ_ONLY || $urandom_range(0, 9) < 5) do_read(a, 8'($urandom_range(0, 7)), 1);
      else do_write(a, $urandom(), ($urandom_range(0, 3) == 0) ? 4'($urandom_range(1, 15)) : 4'hF, 1);
    end

    finish_report();
    $finish;
  end
endmodule
