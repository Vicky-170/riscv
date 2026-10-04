// =============================================================================
// tb_axi_to_apb.sv - V0..V5 for axi_to_apb.sv
//
// Environment: single AXI master BFM (with independent AW/W/R/B delays) and four
// APB slave BFMs (random wait states, PSLVERR injection, write logging, read data
// = f(slave, address) so a wrong PSEL / PADDR shows up in the returned data).
// Scoreboard : exactly ONE APB access per AXI transaction, on the right slave, with
//   the right PADDR/PWRITE/PWDATA/PSTRB; responses OKAY / SLVERR (PSLVERR) /
//   DECERR (unmapped slot, no APB access at all).
// Assertions : one-hot PSEL, SETUP->ACCESS sequencing, PENABLE only with PSEL,
//   APB signal stability across wait states, reads carry PSTRB=0, AXI response
//   stability under back-pressure, RLAST=1, PSEL index == address[15:12].
// =============================================================================
module tb_axi_to_apb import rv32im_pkg::*;;
  `include "tb_common.svh"

  localparam int NP = 4;

  logic clk = 0, rst_n = 0;
  axi_req_t s_req;  axi_rsp_t s_rsp;
  logic [NP-1:0] psel;  logic penable, pwrite;
  logic [11:0] paddr;   logic [31:0] pwdata;  logic [3:0] pstrb;
  logic [NP*32-1:0] prdata;  logic [NP-1:0] pready, pslverr;

  always #5 clk = ~clk;
  always @(posedge clk) cyc++;

  axi_to_apb #(.NUM_PERIPH(NP)) dut (.clk(clk), .rst_n(rst_n), .s_req(s_req), .s_rsp(s_rsp),
      .psel(psel), .penable(penable), .pwrite(pwrite), .paddr(paddr), .pwdata(pwdata), .pstrb(pstrb),
      .prdata(prdata), .pready(pready), .pslverr(pslverr));

  // ---------------------------------------------------------------- APB slave BFMs
  int unsigned max_wait = 0;
  logic [31:0] err_addr = 32'hFFFF_FFFF;                     // PSLVERR when paddr matches (low 12 bits)
  int          wcnt = 0;
  int unsigned n_access = 0, n_apb_wr = 0, n_apb_rd = 0;
  logic [11:0] lg_addr [256]; logic [31:0] lg_data [256]; logic [3:0] lg_strb [256]; int lg_sel [256];
  int          n_log = 0;

  function automatic logic [31:0] ppat(input int idx, input logic [11:0] a);
    return {4'(idx), 4'hC, 8'h33, 4'h0, a};
  endfunction

  wire psel_any = |psel;
  always @(posedge clk) begin
    if (!rst_n) wcnt <= 0;
    else if (psel_any && !penable) wcnt <= (max_wait == 0) ? 0 : $urandom_range(0, max_wait);
    else if (psel_any && penable && wcnt > 0) wcnt <= wcnt - 1;
  end
  // ready during ACCESS when the wait counter reached 0; slave error on the chosen address
  assign pready  = {NP{(wcnt == 0)}};
  always_comb begin
    for (int i = 0; i < NP; i++) begin
      prdata[32*i +: 32] = ppat(i, paddr);
      pslverr[i] = psel[i] && penable && (paddr == err_addr[11:0]);
    end
  end
  // log completed accesses
  always @(posedge clk) if (rst_n && psel_any && penable && (wcnt == 0)) begin
    n_access = n_access + 1;
    if (pwrite) begin
      n_apb_wr = n_apb_wr + 1;
      if (n_log < 256) begin
        for (int i = 0; i < NP; i++) if (psel[i]) lg_sel[n_log] = i;
        lg_addr[n_log] = paddr; lg_data[n_log] = pwdata; lg_strb[n_log] = pstrb; n_log = n_log + 1;
      end
    end else n_apb_rd = n_apb_rd + 1;
  end

  // ---------------------------------------------------------------- V3 assertions
  ap_onehot:   assert property (@(posedge clk) disable iff (!rst_n) $onehot0(psel));
  ap_pen_psel: assert property (@(posedge clk) disable iff (!rst_n) penable |-> (|psel));
  ap_setup_access: assert property (@(posedge clk) disable iff (!rst_n)
                       (|psel && !penable) |=> (|psel && penable));
  ap_access_wait: assert property (@(posedge clk) disable iff (!rst_n)
                       (penable && !(|(psel & pready))) |=> (penable && $stable(psel) && $stable(paddr)
                                                             && $stable(pwrite) && $stable(pwdata) && $stable(pstrb)));
  ap_access_end:  assert property (@(posedge clk) disable iff (!rst_n)
                       (penable && (|(psel & pready))) |=> (!penable));
  ap_stable_setup_access: assert property (@(posedge clk) disable iff (!rst_n)
                       (|psel && !penable) |=> ($stable(paddr) && $stable(pwrite) && $stable(pwdata) && $stable(pstrb)));
  ap_read_strb0: assert property (@(posedge clk) disable iff (!rst_n) (|psel && !pwrite) |-> (pstrb == 4'b0));
  ap_psel_decode: assert property (@(posedge clk) disable iff (!rst_n)
                       (|psel) |-> (psel == (NP'(1) << dut.addr_q[15:12])));
  ap_rlast:    assert property (@(posedge clk) disable iff (!rst_n) s_rsp.rvalid |-> s_rsp.rlast);
  ap_r_stable: assert property (@(posedge clk) disable iff (!rst_n)
                       (s_rsp.rvalid && !s_req.rready) |=> (s_rsp.rvalid && $stable(s_rsp.rdata) && $stable(s_rsp.rresp)));
  ap_b_stable: assert property (@(posedge clk) disable iff (!rst_n)
                       (s_rsp.bvalid && !s_req.bready) |=> (s_rsp.bvalid && $stable(s_rsp.bresp)));
  ap_no_both:  assert property (@(posedge clk) disable iff (!rst_n) !(s_rsp.rvalid && s_rsp.bvalid));
  ap_busy_noready: assert property (@(posedge clk) disable iff (!rst_n)
                       (|psel || s_rsp.rvalid || s_rsp.bvalid) |-> (!s_rsp.arready && !s_rsp.awready && !s_rsp.wready));
  ap_wr_needs_both: assert property (@(posedge clk) disable iff (!rst_n)
                       s_rsp.awready |-> (s_req.awvalid && s_req.wvalid));

  // ---------------------------------------------------------------- AXI master BFM
  task automatic axi_read(input logic [31:0] a, input int rr_pct, input bit is_rand, output logic [1:0] resp, output logic [31:0] data);
    int guard = 0, exp_slot = int'(a[15:12]);
    int acc0 = n_access;
    bit done = 0;
    resp = 0; data = 0;
    @(negedge clk);
    s_req.arvalid = 1; s_req.araddr = a; s_req.arlen = 0; s_req.arsize = 3'b010; s_req.arburst = 2'b01;
    #1;
    while (!s_rsp.arready && guard < 500) begin @(negedge clk); #1; guard++; end
    @(posedge clk); @(negedge clk);
    s_req.arvalid = 0;
    guard = 0;
    while (!done && guard < 500) begin
      s_req.rready = ($urandom_range(0, 99) < rr_pct);
      #1;
      if (s_rsp.rvalid && s_req.rready) begin done = 1; resp = s_rsp.rresp; data = s_rsp.rdata; end
      @(negedge clk); guard++;
    end
    s_req.rready = 0;
    if (!done) chk("read_TIMEOUT", 1, 0);
    repeat (2) @(negedge clk);
    if (is_rand) rchk("one_apb_read_or_none", (exp_slot < NP) ? 64'd1 : 64'd0, 64'(n_access - acc0));
    else         chk($sformatf("one_apb_access_per_read a=%08h", a), (exp_slot < NP) ? 64'd1 : 64'd0, 64'(n_access - acc0));
  endtask

  task automatic axi_write(input logic [31:0] a, input logic [31:0] d, input logic [3:0] s,
                           input int aw_dly, input int w_dly, input int b_pct, input bit is_rand,
                           output logic [1:0] resp);
    int guard = 0, acc0 = n_access;
    bit aw_done = 0, w_done = 0, got_b = 0;
    resp = 0;
    @(negedge clk);
    // independent presentation delays for AW and W
    fork
      begin repeat (aw_dly) @(negedge clk); s_req.awvalid = 1; s_req.awaddr = a; s_req.awlen = 0; s_req.awsize = 3'b010; s_req.awburst = 2'b01; end
      begin repeat (w_dly)  @(negedge clk); s_req.wvalid = 1; s_req.wdata = d; s_req.wstrb = s; s_req.wlast = 1; end
    join
    begin
      bit aw_hs, w_hs;
      while (!(aw_done && w_done) && guard < 800) begin
        #1;
        aw_hs = !aw_done && s_req.awvalid && s_rsp.awready;
        w_hs  = !w_done  && s_req.wvalid  && s_rsp.wready;
        @(negedge clk);
        if (aw_hs) begin aw_done = 1; s_req.awvalid = 0; end
        if (w_hs)  begin w_done  = 1; s_req.wvalid  = 0; s_req.wlast = 0; end
        guard++;
      end
    end
    guard = 0;
    while (!got_b && guard < 800) begin
      s_req.bready = ($urandom_range(0, 99) < b_pct);
      #1;
      if (s_rsp.bvalid && s_req.bready) begin got_b = 1; resp = s_rsp.bresp; end
      @(negedge clk); guard++;
    end
    s_req.bready = 0;
    if (!got_b) chk("write_TIMEOUT", 1, 0);
    repeat (2) @(negedge clk);
    if (is_rand) rchk("one_apb_write_or_none", (a[15:12] < NP) ? 64'd1 : 64'd0, 64'(n_access - acc0));
    else         chk($sformatf("one_apb_access_per_write a=%08h", a), (a[15:12] < NP) ? 64'd1 : 64'd0, 64'(n_access - acc0));
  endtask

  // expected-behaviour checks ------------------------------------------------------------------
  task automatic check_read(input logic [31:0] a, input int rr_pct, input bit is_rand);
    logic [1:0] resp; logic [31:0] data;
    bit unmapped, inj;
    axi_read(a, rr_pct, is_rand, resp, data);
    unmapped = (a[15:12] >= NP);
    inj      = !unmapped && (a[11:0] == err_addr[11:0]);
    if (is_rand) begin
      rchk("rresp", unmapped ? AXI_RESP_DECERR : (inj ? AXI_RESP_SLVERR : AXI_RESP_OKAY), {62'd0, resp});
      if (!unmapped) rchk("rdata", {32'd0, ppat(int'(a[15:12]), a[11:0])}, {32'd0, data});
    end else begin
      chk($sformatf("rresp a=%08h", a), unmapped ? AXI_RESP_DECERR : (inj ? AXI_RESP_SLVERR : AXI_RESP_OKAY), {62'd0, resp});
      if (!unmapped) chk("rdata", {32'd0, ppat(int'(a[15:12]), a[11:0])}, {32'd0, data});
    end
    if (unmapped) cov_hit(4); else cov_hit(int'(a[15:12]));
    if (inj) cov_hit(5);
    if (rr_pct < 100) cov_hit(6);
    if (max_wait > 0) cov_hit(7);
  endtask

  task automatic check_write(input logic [31:0] a, input logic [31:0] d, input logic [3:0] s,
                             input int aw_dly, input int w_dly, input int b_pct, input bit is_rand);
    logic [1:0] resp;
    bit unmapped, inj;
    int n0 = n_log;
    axi_write(a, d, s, aw_dly, w_dly, b_pct, is_rand, resp);
    unmapped = (a[15:12] >= NP);
    inj      = !unmapped && (a[11:0] == err_addr[11:0]);
    if (is_rand) rchk("bresp", unmapped ? AXI_RESP_DECERR : (inj ? AXI_RESP_SLVERR : AXI_RESP_OKAY), {62'd0, resp});
    else chk($sformatf("bresp a=%08h", a), unmapped ? AXI_RESP_DECERR : (inj ? AXI_RESP_SLVERR : AXI_RESP_OKAY), {62'd0, resp});
    if (!unmapped) begin
      if (is_rand) begin
        rchk("apb_log_entry", 64'(n0 + 1), 64'(n_log));
        rchk("apb_sel",   64'(a[15:12]), 64'(lg_sel[n_log-1]));
        rchk("apb_addr",  {52'd0, a[11:0]}, {52'd0, lg_addr[n_log-1]});
        rchk("apb_data",  {32'd0, d}, {32'd0, lg_data[n_log-1]});
        rchk("apb_strb",  {60'd0, s}, {60'd0, lg_strb[n_log-1]});
      end else begin
        chk("apb_log_entry", 64'(n0 + 1), 64'(n_log));
        chk("apb_sel",   64'(a[15:12]), 64'(lg_sel[n_log-1]));
        chk("apb_addr",  {52'd0, a[11:0]}, {52'd0, lg_addr[n_log-1]});
        chk("apb_data",  {32'd0, d}, {32'd0, lg_data[n_log-1]});
        chk("apb_strb",  {60'd0, s}, {60'd0, lg_strb[n_log-1]});
      end
    end else chk("unmapped_no_apb_write", 64'(n0), 64'(n_log));
    if (unmapped) cov_hit(8); else cov_hit(9);
    if (s != 4'hF) cov_hit(10);
    if (aw_dly > w_dly) cov_hit(11);     // W presented before AW
    if (w_dly > aw_dly) cov_hit(12);     // AW presented before W
    if (b_pct < 100) cov_hit(13);
    if (inj) cov_hit(14);
  endtask

  initial begin
    logic [1:0] r; logic [31:0] dd;
    tb_init("axi_to_apb");
    cov_def(0,"rd_timer"); cov_def(1,"rd_uart"); cov_def(2,"rd_gpio"); cov_def(3,"rd_intc");
    cov_def(4,"rd_unmapped"); cov_def(5,"pslverr_read"); cov_def(6,"rready_backpressure");
    cov_def(7,"apb_wait_states"); cov_def(8,"wr_unmapped"); cov_def(9,"wr_mapped");
    cov_def(10,"wr_partial_strobe"); cov_def(11,"w_before_aw"); cov_def(12,"aw_before_w");
    cov_def(13,"bready_backpressure"); cov_def(14,"pslverr_write"); cov_def(15,"read_priority_over_write");
    s_req = AXI_REQ_IDLE;                              // (init in initial: Verilator struct-initializer quirk)
    repeat (3) @(negedge clk);
    rst_n = 1; @(negedge clk);

    // ---- V1: reads from each peripheral, several offsets ----------------------------------
    for (int p = 0; p < NP; p++) begin
      check_read(32'h4000_0000 | (32'(p) << 12) | 32'h000, 100, 0);
      check_read(32'h4000_0000 | (32'(p) << 12) | 32'h004, 100, 0);
      check_read(32'h4000_0000 | (32'(p) << 12) | 32'hFFC, 100, 0);
    end
    // ---- V1: writes to each peripheral incl. partial strobes ---------------------------------
    for (int p = 0; p < NP; p++) begin
      check_write(32'h4000_0000 | (32'(p) << 12) | 32'h010, 32'hA5A5_0000 + 32'(p), 4'hF, 0, 0, 100, 0);
      check_write(32'h4000_0000 | (32'(p) << 12) | 32'h014, 32'h0000_00FF, 4'b0001, 0, 0, 100, 0);
      check_write(32'h4000_0000 | (32'(p) << 12) | 32'h018, 32'hFF00_FF00, 4'b1010, 0, 0, 100, 0);
    end
    // ---- V1: APB wait states -------------------------------------------------------------------
    max_wait = 4;
    for (int p = 0; p < NP; p++) begin
      check_read(32'h4000_0000 | (32'(p) << 12) | 32'h020, 100, 0);
      check_write(32'h4000_0000 | (32'(p) << 12) | 32'h024, 32'h1234_0000 | 32'(p), 4'hF, 0, 0, 100, 0);
    end
    max_wait = 0;
    // ---- V1: PSLVERR -> SLVERR (read and write) -------------------------------------------------
    err_addr = 32'h0000_0030;
    check_read (32'h4000_1030, 100, 0);
    check_write(32'h4000_2030, 32'hBAD0_0001, 4'hF, 0, 0, 100, 0);
    check_read (32'h4000_1034, 100, 0);                          // neighbouring address is fine
    err_addr = 32'hFFFF_FFFF;
    // ---- V1: unmapped slots -> DECERR with NO apb access ---------------------------------------------
    for (int u = 4; u < 16; u++) begin
      check_read (32'h4000_0000 | (32'(u) << 12) | 32'h008, 100, 0);
      check_write(32'h4000_0000 | (32'(u) << 12) | 32'h00C, 32'hDEAD_BEEF, 4'hF, 0, 0, 100, 0);
    end
    // ---- V1: AXI back-pressure on the response channels ------------------------------------------------
    check_read(32'h4000_1040, 25, 0);
    check_write(32'h4000_2044, 32'hCAFE_0001, 4'hF, 0, 0, 25, 0);
    // ---- V1: AW and W presented far apart (bridge waits for both) -----------------------------------------
    check_write(32'h4000_0050, 32'h1111_1111, 4'hF, 0, 8, 100, 0);   // AW first, W 8 cycles later
    check_write(32'h4000_0054, 32'h2222_2222, 4'hF, 8, 0, 100, 0);   // W first, AW 8 cycles later
    check_write(32'h4000_0058, 32'h3333_3333, 4'hF, 3, 3, 40, 0);
    // ---- V1: simultaneous AR + AW/W: read served first ---------------------------------------------------------
    begin
      int a0 = n_apb_rd, w0 = n_apb_wr;
      @(negedge clk);
      s_req.arvalid = 1; s_req.araddr = 32'h4000_0060; s_req.arlen = 0;
      s_req.awvalid = 1; s_req.awaddr = 32'h4000_0064; s_req.wvalid = 1; s_req.wdata = 32'h7777_7777; s_req.wstrb = 4'hF; s_req.wlast = 1;
      #1;
      chk("read_priority_arready", 1, {63'd0, s_rsp.arready});
      chk("read_priority_no_awready", 0, {63'd0, s_rsp.awready});
      cov_hit(15);
      @(posedge clk); @(negedge clk); s_req.arvalid = 0; s_req.rready = 1;
      begin int g = 0; while (!s_rsp.rvalid && g < 50) begin @(negedge clk); g++; end end
      @(negedge clk); s_req.rready = 0;
      begin int g = 0; while (!s_rsp.awready && g < 50) begin @(negedge clk); #1; g++; end end
      @(posedge clk); @(negedge clk); s_req.awvalid = 0; s_req.wvalid = 0; s_req.wlast = 0; s_req.bready = 1;
      begin int g = 0; while (!s_rsp.bvalid && g < 50) begin @(negedge clk); g++; end end
      @(negedge clk); s_req.bready = 0;
      repeat (3) @(negedge clk);
      chk("read_then_write_counts", 64'(a0 + 1) | (64'(w0 + 1) << 32), 64'(n_apb_rd) | (64'(n_apb_wr) << 32));
    end
    // ---- V1: back-to-back read, write, read ---------------------------------------------------------------------------
    check_read(32'h4000_0070, 100, 0); check_write(32'h4000_0074, 32'h9999_9999, 4'hF, 0, 0, 100, 0); check_read(32'h4000_0074, 100, 0);
    // ---- V1: reset in the middle of an APB access returns to idle ------------------------------------------------------------
    max_wait = 4;
    @(negedge clk); s_req.arvalid = 1; s_req.araddr = 32'h4000_1080; s_req.arlen = 0;
    @(negedge clk); s_req.arvalid = 0; @(negedge clk);
    rst_n = 0; @(negedge clk); @(negedge clk); rst_n = 1; max_wait = 0; @(negedge clk); #1;
    chk("idle_after_reset_psel", 0, {60'd0, psel});
    chk("idle_after_reset_penable", 0, {63'd0, penable});
    check_read(32'h4000_0080, 100, 0);

    // ---- V2/V5: 110 randomized transactions ------------------------------------------------------------------------------------
    for (int i = 0; i < 110; i++) begin
      logic [31:0] a;
      max_wait = ($urandom_range(0, 2) == 0) ? $urandom_range(1, 5) : 0;
      err_addr = ($urandom_range(0, 9) == 0) ? 32'($urandom_range(0, 15) * 4) : 32'hFFFF_FFFF;
      a = 32'h4000_0000 | (32'($urandom_range(0, 7)) << 12) | (32'($urandom_range(0, 15)) * 4);   // slots 0..7 (4..7 unmapped)
      if ($urandom_range(0, 1)) check_read(a, ($urandom_range(0, 1)) ? 100 : $urandom_range(20, 90), 1);
      else check_write(a, $urandom(), ($urandom_range(0, 3) == 0) ? 4'($urandom_range(1, 15)) : 4'hF,
                       $urandom_range(0, 4), $urandom_range(0, 4), ($urandom_range(0, 1)) ? 100 : $urandom_range(20, 90), 1);
    end

    finish_report();
    $finish;
  end
endmodule
