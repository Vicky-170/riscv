// =============================================================================
// tb_axi4_interconnect.sv - V0..V5 for axi4_interconnect.sv
//
// Environment
//   * three independent slave BFMs (S0 ROM-like, S1 SRAM-like, S2 peripheral-like).
//     Read data = f(slave id, byte address) so a mis-routed read or a response
//     delivered to the wrong master is immediately visible.  Writes are logged.
//   * two concurrent master threads (fork/join) that follow AXI VALID/READY rules
//   * unmapped regions -> DECERR handled by the DUT's internal error slave;
//     S1 can also inject SLVERR on a window
// Scoreboard
//   * every read beat: data/resp/last vs the pattern function
//   * every write: found exactly once in the intended slave's log with the right
//     address and strobes, and NOT in any other slave's log
//   * fairness monitor: no master is granted twice in a row while the other waits
// Assertions (V3): one slave addressed at a time, slave-side VALID stability,
//   response only to the granted master, never two masters responded to at once.
// =============================================================================
module tb_slave_bfm import rv32im_pkg::*; #(parameter int SID = 0) (
  input  logic clk, rst_n,
  input  axi_req_t s_req,
  output axi_rsp_t s_rsp
);
  int unsigned p_ready = 100;
  logic [31:0] err_lo = 32'hFFFF_FFFF, err_hi = 0;
  logic [1:0]  errcode = AXI_RESP_SLVERR;
  logic [31:0] log_addr [512];  logic [31:0] log_data [512];  logic [3:0] log_strb [512];
  int          n_log = 0;
  int unsigned n_reads = 0;

  function automatic logic [31:0] pat(input logic [31:0] a);
    return {4'(SID), 4'hD, 8'h5A, a[15:0]};
  endfunction
  function automatic bit ierr(input logic [31:0] a); return a >= err_lo && a <= err_hi; endfunction

  bit arok = 0, awok = 0, wok = 0, rvalid_w = 0, rlast_w = 0, bvalid_w = 0, aw_got = 0, w_got = 0;
  int rd_st = 0, wr_st = 0, rd_beat = 0;
  logic [31:0] rd_addr, aw_addr, w_data, rdata_w = 0;
  logic [7:0]  rd_len;
  logic [3:0]  w_strb;
  logic [1:0]  rresp_w = 0, bresp_w = 0;

  wire arready_w = (rd_st == 0) && arok;
  wire awready_w = !aw_got && awok;
  wire wready_w  = !w_got && wok;
  assign s_rsp = {awready_w, wready_w, bresp_w, bvalid_w, arready_w, rdata_w, rresp_w, rlast_w, rvalid_w};

  always @(posedge clk) begin
    bit aw_hs, w_hs;
    logic [31:0] eaw, ewd; logic [3:0] ews;
    arok <= ($urandom_range(0, 99) < p_ready);
    awok <= ($urandom_range(0, 99) < p_ready);
    wok  <= ($urandom_range(0, 99) < p_ready);
    if (!rst_n) begin rd_st <= 0; wr_st <= 0; aw_got <= 0; w_got <= 0; rvalid_w <= 0; bvalid_w <= 0; end
    else begin
      aw_hs = s_req.awvalid && awready_w;
      w_hs  = s_req.wvalid  && wready_w;
      if (s_req.arvalid && arready_w) begin
        rd_addr <= s_req.araddr; rd_len <= s_req.arlen; rd_beat <= 0; rd_st <= 1; n_reads = n_reads + 1;
      end
      if (rd_st == 1) begin
        if (!rvalid_w) begin
          if ($urandom_range(0, 99) < p_ready) begin
            rvalid_w <= 1; rlast_w <= (rd_beat == int'(rd_len));
            rdata_w  <= pat(rd_addr + 32'(4 * rd_beat));
            rresp_w  <= ierr(rd_addr + 32'(4 * rd_beat)) ? errcode : AXI_RESP_OKAY;
          end
        end else if (s_req.rready) begin
          rvalid_w <= 0;
          if (rlast_w) rd_st <= 0; else rd_beat <= rd_beat + 1;
        end
      end
      if (aw_hs) begin aw_got <= 1; aw_addr <= s_req.awaddr; end
      if (w_hs)  begin w_got <= 1; w_data <= s_req.wdata; w_strb <= s_req.wstrb; end
      eaw = aw_hs ? s_req.awaddr : aw_addr;
      ewd = w_hs ? s_req.wdata : w_data;
      ews = w_hs ? s_req.wstrb : w_strb;
      case (wr_st)
        0: if ((aw_got || aw_hs) && (w_got || w_hs)) begin
             if (n_log < 512) begin log_addr[n_log] = eaw; log_data[n_log] = ewd; log_strb[n_log] = ews; n_log = n_log + 1; end
             bresp_w <= ierr(eaw) ? errcode : AXI_RESP_OKAY;
             wr_st <= 1;
           end
        1: if ($urandom_range(0, 99) < p_ready) begin bvalid_w <= 1; wr_st <= 2; end
        2: if (s_req.bready) begin bvalid_w <= 0; wr_st <= 0; aw_got <= 0; w_got <= 0; end
        default: wr_st <= 0;
      endcase
    end
  end
endmodule

// =============================================================================
module tb_axi4_interconnect import rv32im_pkg::*;;
  `include "tb_common.svh"

  logic     clk = 0, rst_n = 0;
  axi_req_t m0_req, m1_req, s0_req, s1_req, s2_req;
  axi_rsp_t m0_rsp, m1_rsp, s0_rsp, s1_rsp, s2_rsp;

  always #5 clk = ~clk;
  always @(posedge clk) cyc++;

  axi4_interconnect dut (.*);
  tb_slave_bfm #(.SID(0)) u_s0 (.clk(clk), .rst_n(rst_n), .s_req(s0_req), .s_rsp(s0_rsp));
  tb_slave_bfm #(.SID(1)) u_s1 (.clk(clk), .rst_n(rst_n), .s_req(s1_req), .s_rsp(s1_rsp));
  tb_slave_bfm #(.SID(2)) u_s2 (.clk(clk), .rst_n(rst_n), .s_req(s2_req), .s_rsp(s2_rsp));

  // ---------------------------------------------------------------- V3 assertions
  ap_one_slave_ar: assert property (@(posedge clk) disable iff (!rst_n)
      $onehot0({s0_req.arvalid, s1_req.arvalid, s2_req.arvalid}));
  ap_one_slave_aw: assert property (@(posedge clk) disable iff (!rst_n)
      $onehot0({s0_req.awvalid, s1_req.awvalid, s2_req.awvalid}));
  ap_s0_ar_stable: assert property (@(posedge clk) disable iff (!rst_n)
      (s0_req.arvalid && !s0_rsp.arready) |=> (s0_req.arvalid && $stable(s0_req.araddr)));
  ap_s1_ar_stable: assert property (@(posedge clk) disable iff (!rst_n)
      (s1_req.arvalid && !s1_rsp.arready) |=> (s1_req.arvalid && $stable(s1_req.araddr)));
  ap_s2_ar_stable: assert property (@(posedge clk) disable iff (!rst_n)
      (s2_req.arvalid && !s2_rsp.arready) |=> (s2_req.arvalid && $stable(s2_req.araddr)));
  ap_s1_aw_stable: assert property (@(posedge clk) disable iff (!rst_n)
      (s1_req.awvalid && !s1_rsp.awready) |=> (s1_req.awvalid && $stable(s1_req.awaddr)));
  ap_one_master_resp: assert property (@(posedge clk) disable iff (!rst_n)
      !((m0_rsp.rvalid || m0_rsp.bvalid) && (m1_rsp.rvalid || m1_rsp.bvalid)));
  ap_resp_owner0: assert property (@(posedge clk) disable iff (!rst_n)
      (m0_rsp.rvalid || m0_rsp.bvalid || m0_rsp.arready || m0_rsp.awready || m0_rsp.wready) |-> (dut.act && !dut.gm));
  ap_resp_owner1: assert property (@(posedge clk) disable iff (!rst_n)
      (m1_rsp.rvalid || m1_rsp.bvalid || m1_rsp.arready || m1_rsp.awready || m1_rsp.wready) |-> (dut.act && dut.gm));
  ap_slave_only_when_act: assert property (@(posedge clk) disable iff (!rst_n)
      (s0_req.arvalid || s1_req.arvalid || s2_req.arvalid || s0_req.awvalid || s1_req.awvalid || s2_req.awvalid) |-> dut.act);

  // ---------------------------------------------------------------- fairness monitor
  bit prev_act = 0; bit last_gm_seen = 1; bit have_last = 0;
  int unsigned n_grants0 = 0, n_grants1 = 0, fair_viol = 0, n_contended = 0;
  always @(posedge clk) begin
    if (rst_n) begin
      if (!prev_act && dut.act) begin
        bit other_pending;
        other_pending = dut.gm ? (m0_req.arvalid || m0_req.awvalid) : (m1_req.arvalid || m1_req.awvalid);
        if (dut.gm) n_grants1 = n_grants1 + 1; else n_grants0 = n_grants0 + 1;
        if (other_pending) begin
          n_contended = n_contended + 1;
          if (have_last && dut.gm == last_gm_seen) fair_viol = fair_viol + 1;
        end
        last_gm_seen = dut.gm; have_last = 1;
      end
      prev_act = dut.act;
    end
  end

  // ---------------------------------------------------------------- master drive helpers
  task automatic drive_ar(input int mi, input bit v, input logic [31:0] a, input logic [7:0] len);
    if (mi == 0) begin m0_req.arvalid = v; m0_req.araddr = a; m0_req.arlen = len; m0_req.arsize = 3'b010; m0_req.arburst = 2'b01; end
    else         begin m1_req.arvalid = v; m1_req.araddr = a; m1_req.arlen = len; m1_req.arsize = 3'b010; m1_req.arburst = 2'b01; end
  endtask
  task automatic drive_rready(input int mi, input bit v);
    if (mi == 0) m0_req.rready = v; else m1_req.rready = v;
  endtask
  task automatic drive_aw(input int mi, input bit v, input logic [31:0] a);
    if (mi == 0) begin m0_req.awvalid = v; m0_req.awaddr = a; m0_req.awlen = 0; m0_req.awsize = 3'b010; m0_req.awburst = 2'b01; end
    else         begin m1_req.awvalid = v; m1_req.awaddr = a; m1_req.awlen = 0; m1_req.awsize = 3'b010; m1_req.awburst = 2'b01; end
  endtask
  task automatic drive_w(input int mi, input bit v, input logic [31:0] d, input logic [3:0] s);
    if (mi == 0) begin m0_req.wvalid = v; m0_req.wdata = d; m0_req.wstrb = s; m0_req.wlast = v; end
    else         begin m1_req.wvalid = v; m1_req.wdata = d; m1_req.wstrb = s; m1_req.wlast = v; end
  endtask
  task automatic drive_bready(input int mi, input bit v);
    if (mi == 0) m0_req.bready = v; else m1_req.bready = v;
  endtask
  function automatic axi_rsp_t rsp_of(input int mi); return (mi == 0) ? m0_rsp : m1_rsp; endfunction

  function automatic int sid_of(input logic [31:0] a);
    case (a[31:28]) 4'h0: return 0; 4'h1: return 1; 4'h4: return 2; default: return 3; endcase
  endfunction
  function automatic logic [31:0] exp_pat(input int sid, input logic [31:0] a);
    return {4'(sid), 4'hD, 8'h5A, a[15:0]};
  endfunction

  // slave-side hierarchical accessors
  function automatic int slave_nlog(input int sid);
    case (sid) 0: return u_s0.n_log; 1: return u_s1.n_log; default: return u_s2.n_log; endcase
  endfunction
  function automatic int count_log(input int sid, input logic [31:0] d, output logic [31:0] la, output logic [3:0] ls);
    int n = 0;
    la = 0; ls = 0;
    for (int i = 0; i < 512; i++) begin
      if (sid == 0 && i < u_s0.n_log && u_s0.log_data[i] == d) begin n++; la = u_s0.log_addr[i]; ls = u_s0.log_strb[i]; end
      if (sid == 1 && i < u_s1.n_log && u_s1.log_data[i] == d) begin n++; la = u_s1.log_addr[i]; ls = u_s1.log_strb[i]; end
      if (sid == 2 && i < u_s2.n_log && u_s2.log_data[i] == d) begin n++; la = u_s2.log_addr[i]; ls = u_s2.log_strb[i]; end
    end
    return n;
  endfunction

  // ---------------------------------------------------------------- transactions
  int unsigned wr_uid = 32'h1000_0000;

  task automatic m_read(input int mi, input logic [31:0] a, input logic [7:0] len, input int rr_pct, input bit is_rand);
    int beats = 0, guard = 0, sid;
    bit bad_data = 0, bad_last = 0, bad_resp = 0;
    logic [31:0] ba;
    sid = sid_of(a);
    @(negedge clk);
    drive_ar(mi, 1, a, len);
    #1;
    while (!rsp_of(mi).arready && guard < 3000) begin @(negedge clk); #1; guard++; end
    @(posedge clk); @(negedge clk);
    drive_ar(mi, 0, a, len);
    guard = 0;
    while (beats <= int'(len) && guard < 4000) begin
      drive_rready(mi, $urandom_range(0, 99) < rr_pct);
      #1;
      if (rsp_of(mi).rvalid && ((mi == 0) ? m0_req.rready : m1_req.rready)) begin
        ba = a + 32'(4 * beats);
        if (sid == 3) begin
          if (rsp_of(mi).rresp != AXI_RESP_DECERR) bad_resp = 1;
        end else if (sid == 1 && ba >= u_s1.err_lo && ba <= u_s1.err_hi) begin
          if (rsp_of(mi).rresp != u_s1.errcode) bad_resp = 1;
        end else begin
          if (rsp_of(mi).rresp != AXI_RESP_OKAY) bad_resp = 1;
          if (rsp_of(mi).rdata != exp_pat(sid, ba)) bad_data = 1;
        end
        if (rsp_of(mi).rlast != (beats == int'(len))) bad_last = 1;
        beats++;
      end
      @(negedge clk); guard++;
    end
    drive_rready(mi, 0);
    if (guard >= 4000) chk("read_TIMEOUT", 1, 0);
    if (is_rand) begin
      rchk("rd_beats", 64'(len) + 1, 64'(beats)); rchk("rd_data", 0, {63'd0, bad_data});
      rchk("rd_resp", 0, {63'd0, bad_resp});      rchk("rd_last", 0, {63'd0, bad_last});
    end else begin
      chk($sformatf("m%0d_rd_beats a=%08h", mi, a), 64'(len) + 1, 64'(beats));
      chk("rd_data", 0, {63'd0, bad_data}); chk("rd_resp", 0, {63'd0, bad_resp}); chk("rd_last", 0, {63'd0, bad_last});
    end
    cov_hit(sid);                                    // bins 0..3 : S0, S1, S2, DECERR
    if (mi == 0) cov_hit(4); else cov_hit(5);
    if (len != 0) cov_hit(6);
    if (rr_pct < 100) cov_hit(7);
  endtask

  task automatic m_write(input int mi, input logic [31:0] a, input logic [3:0] s, input int b_pct, input bit is_rand);
    int guard = 0, sid, nfound, nother = 0, bs = 0;
    bit aw_done = 0, w_done = 0, aw_hs, w_hs, got_b = 0, bad_resp = 0;
    logic [31:0] uid, la, la2; logic [3:0] ls, ls2;
    sid = sid_of(a);
    wr_uid = wr_uid + 32'h0001_0001;
    uid = wr_uid ^ (32'(mi) << 31);
    @(negedge clk);
    drive_aw(mi, 1, a); drive_w(mi, 1, uid, s);
    while (!(aw_done && w_done) && guard < 3000) begin
      #1;
      aw_hs = !aw_done && rsp_of(mi).awready;
      w_hs  = !w_done  && rsp_of(mi).wready;
      @(negedge clk);
      if (aw_hs) begin aw_done = 1; drive_aw(mi, 0, a); end
      if (w_hs)  begin w_done = 1;  drive_w(mi, 0, uid, s); end
      guard++;
    end
    guard = 0;
    while (!got_b && guard < 3000) begin
      drive_bready(mi, $urandom_range(0, 99) < b_pct);
      #1;
      if (rsp_of(mi).bvalid && ((mi == 0) ? m0_req.bready : m1_req.bready)) begin
        got_b = 1;
        if (sid == 3 && rsp_of(mi).bresp != AXI_RESP_DECERR) bad_resp = 1;
        if (sid == 1 && a >= u_s1.err_lo && a <= u_s1.err_hi && rsp_of(mi).bresp != u_s1.errcode) bad_resp = 1;
        if (sid != 3 && !(sid == 1 && a >= u_s1.err_lo && a <= u_s1.err_hi) && rsp_of(mi).bresp != AXI_RESP_OKAY) bad_resp = 1;
      end
      @(negedge clk); guard++;
    end
    drive_bready(mi, 0);
    if (guard >= 3000 || !aw_done || !w_done) chk("write_TIMEOUT", 1, 0);
    repeat (2) @(negedge clk);
    // scoreboard: exactly one log entry, in the intended slave, none elsewhere
    for (int k = 0; k < 3; k++) begin
      int c = count_log(k, uid, la, ls);
      if (k == sid) begin nfound = c; la2 = la; ls2 = ls; end else nother += c;
    end
    if (sid == 3) begin nfound = 0; nother = nother; end      // DECERR: no slave may see it
    begin
      int exp_found = (sid == 3) ? 0 : 1;
      if (is_rand) begin
        rchk("wr_logged_once", 64'(exp_found), 64'(nfound)); rchk("wr_not_elsewhere", 0, 64'(nother));
        rchk("wr_resp", 0, {63'd0, bad_resp});
        if (exp_found) begin rchk("wr_addr", {32'd0, a}, {32'd0, la2}); rchk("wr_strb", {60'd0, s}, {60'd0, ls2}); end
      end else begin
        chk($sformatf("m%0d_wr_logged_once a=%08h", mi, a), 64'(exp_found), 64'(nfound));
        chk("wr_not_elsewhere", 0, 64'(nother)); chk("wr_resp", 0, {63'd0, bad_resp});
        if (exp_found) begin chk("wr_addr", {32'd0, a}, {32'd0, la2}); chk("wr_strb", {60'd0, s}, {60'd0, ls2}); end
      end
    end
    cov_hit(8 + sid);                                // bins 8..11 : write to S0,S1,S2,DECERR
    if (b_pct < 100) cov_hit(12);
  endtask

  task automatic init_masters();
    m0_req = AXI_REQ_IDLE; m1_req = AXI_REQ_IDLE;
  endtask

  initial begin
    tb_init("axi4_interconnect");
    cov_def(0,"rd_S0"); cov_def(1,"rd_S1"); cov_def(2,"rd_S2"); cov_def(3,"rd_DECERR");
    cov_def(4,"master0"); cov_def(5,"master1"); cov_def(6,"burst"); cov_def(7,"rready_backpressure");
    cov_def(8,"wr_S0"); cov_def(9,"wr_S1"); cov_def(10,"wr_S2"); cov_def(11,"wr_DECERR");
    cov_def(12,"bready_backpressure"); cov_def(13,"contention_fork"); cov_def(14,"slave_backpressure");
    cov_def(15,"slave_SLVERR_forwarded");
    init_masters();
    repeat (3) @(negedge clk);
    rst_n = 1; @(negedge clk);

    // ---- V1: every master -> every slave, single reads and bursts ----------------------------
    for (int m = 0; m < 2; m++) begin
      m_read(m, 32'h0000_0040, 8'd0, 100, 0);
      m_read(m, 32'h1000_0040, 8'd0, 100, 0);
      m_read(m, 32'h4000_0040, 8'd0, 100, 0);
      m_read(m, 32'h0000_0100, 8'd3, 100, 0);
      m_read(m, 32'h1000_0100, 8'd7, 100, 0);
    end
    // ---- V1: writes to every slave from every master, partial strobes --------------------------
    for (int m = 0; m < 2; m++) begin
      m_write(m, 32'h0000_0080, 4'hF, 100, 0);      // ROM address: the fabric just routes, slave decides
      m_write(m, 32'h1000_0084, 4'b0011, 100, 0);
      m_write(m, 32'h4000_0088, 4'b1100, 100, 0);
    end
    // ---- V1: unmapped regions -> DECERR (reads and writes), several region codes --------------------
    for (int m = 0; m < 2; m++) begin
      m_read(m, 32'h2000_0000, 8'd0, 100, 0);
      m_read(m, 32'h3000_0010, 8'd3, 100, 0);
      m_read(m, 32'h8000_0000, 8'd1, 100, 0);
      m_read(m, 32'hF000_0000, 8'd0, 100, 0);
      m_write(m, 32'h5000_0000, 4'hF, 100, 0);
      m_write(m, 32'hC000_0004, 4'hF, 100, 0);
    end
    // decode boundaries: last word of one region / first of the next
    m_read(0, 32'h0FFF_FFFC, 8'd0, 100, 0);          // S0 top
    m_read(0, 32'h1000_0000, 8'd0, 100, 0);          // S1 base
    m_read(0, 32'h1FFF_FFFC, 8'd0, 100, 0);          // S1 top
    m_read(0, 32'h2000_0000, 8'd0, 100, 0);          // DECERR base
    m_read(0, 32'h4FFF_FFFC, 8'd0, 100, 0);          // S2 top
    m_read(0, 32'h5000_0000, 8'd0, 100, 0);          // DECERR
    // ---- V1: slave SLVERR forwarded to the correct master ----------------------------------------------
    u_s1.err_lo = 32'h1000_0200; u_s1.err_hi = 32'h1000_020F; u_s1.errcode = AXI_RESP_SLVERR;
    m_read(0, 32'h1000_01F0, 8'd7, 100, 0);          // burst crossing into the error window
    m_read(1, 32'h1000_0200, 8'd0, 100, 0);
    m_write(1, 32'h1000_0204, 4'hF, 100, 0);
    m_write(0, 32'h1000_0304, 4'hF, 100, 0);         // outside the window: OKAY
    u_s1.err_lo = 32'hFFFF_FFFF; u_s1.err_hi = 0;
    cov_hit(15);
    // ---- V1: slave and master backpressure -------------------------------------------------------------
    u_s0.p_ready = 30; u_s1.p_ready = 30; u_s2.p_ready = 30;
    m_read(0, 32'h0000_0040, 8'd3, 30, 0);
    m_write(1, 32'h1000_0090, 4'hF, 30, 0);
    m_read(1, 32'h4000_0040, 8'd0, 30, 0);
    u_s0.p_ready = 100; u_s1.p_ready = 100; u_s2.p_ready = 100;
    cov_hit(14);

    // ---- V1: contention - both masters request simultaneously, repeatedly ---------------------------------
    fork
      thr_rd(0, 32'h0000_0040, 20);
      thr_rd(1, 32'h1000_0040, 20);
    join
    cov_hit(13);
    fork
      thr_wr(0, 32'h1000_1000, 10);
      thr_rd(1, 32'h4000_0100, 10);
    join
    chk_t("contention_happened", n_contended >= 10);
    chk("round_robin_no_repeat_grant_while_other_waits", 0, 64'(fair_viol));
    chk_t("both_masters_granted", n_grants0 > 10 && n_grants1 > 10);

    // ---- V2/V5: 110 randomized transactions from two concurrent masters -----------------------------------------
    fork
      thr_rand(0, 55);
      thr_rand(1, 55);
    join
    chk("fairness_after_random", 0, 64'(fair_viol));

    finish_report();
    $finish;
  end

  // thread bodies live in tasks (Verilator 5.020 crashes on loop variables declared inside fork branches)
  task automatic thr_rd(input int mi, input logic [31:0] base, input int n);
    for (int i = 0; i < n; i++) m_read(mi, base + 32'(i * 4), 8'd1, 100, 0);
  endtask
  task automatic thr_wr(input int mi, input logic [31:0] base, input int n);
    for (int i = 0; i < n; i++) m_write(mi, base + 32'(i * 4), 4'hF, 100, 0);
  endtask
  task automatic thr_rand(input int mi, input int n);
    for (int i = 0; i < n; i++) rand_txn(mi);
  endtask

  task automatic rand_txn(input int mi);
    logic [31:0] a;
    int          r = $urandom_range(0, 99);
    int          pr = ($urandom_range(0, 1)) ? 100 : $urandom_range(20, 90);
    // region choice: mostly mapped, sometimes unmapped
    case ($urandom_range(0, 9))
      0, 1, 2:  a = {4'h0, 28'($urandom_range(16, 1000) * 4)};
      3, 4, 5:  a = {4'h1, 28'($urandom_range(16, 1000) * 4)};
      6, 7:     a = {4'h4, 28'($urandom_range(16, 1000) * 4)};
      default:  a = {4'($urandom_range(0, 15)), 28'($urandom_range(16, 1000) * 4)};
    endcase
    if ($urandom_range(0, 7) == 0) begin u_s0.p_ready = $urandom_range(30, 100); u_s1.p_ready = $urandom_range(30, 100); u_s2.p_ready = $urandom_range(30, 100); end
    if (r < 55) m_read(mi, a, 8'($urandom_range(0, 7)), pr, 1);
    else        m_write(mi, a, ($urandom_range(0, 3) == 0) ? 4'($urandom_range(1, 15)) : 4'hF, pr, 1);
  endtask
endmodule
