// =============================================================================
// tb_dcache.sv - V0..V5 for dcache.sv   (-GENABLE / -GLINES / -GLINE_BYTES)
//
// Policy under test (from the RTL checkpoint record):
//   write-through, no-write-allocate, blocking stores, load hit in the same cycle,
//   peripheral space (0x4xxx_xxxx) never cached, cache updated on a store hit only
//   after the bus write succeeds, bus error -> cpu_err.
// Reference: native_mem.svh (memory that applies strobes, MMIO reads that change on
// every access, shadow of fully delivered lines).
//   * loads    : data == memory word (cacheable) / == the bus's answer (uncached)
//   * hit/miss : cpu_ready at apply == "line present in shadow" for cacheable loads;
//                stores and uncached accesses never complete in the apply cycle
//   * stores   : exactly one bus write, word address, strobes == byte enables, data
//   * no-write-allocate : a store miss must leave the line absent (next load misses)
//   * write-through coherence : after any store a load returns the merged memory value
// =============================================================================
module tb_dcache;
  `include "tb_common.svh"

  parameter bit ENABLE     = 1'b1;
  parameter int LINES      = 8;
  parameter int LINE_BYTES = 16;
  localparam int WORDS = LINE_BYTES / 4;
  localparam int OFFW  = $clog2(LINE_BYTES);

  logic        clk = 0, rst_n = 0;
  logic        cpu_req = 0, cpu_we = 0;
  logic [31:0] cpu_addr = 0, cpu_wdata = 0, cpu_rdata;
  logic [3:0]  cpu_be = 0;
  logic        cpu_ready, cpu_err, cpu_busy;
  logic        req_valid, req_ready, req_write;
  logic [31:0] req_addr, req_wdata;
  logic [7:0]  req_len;
  logic [3:0]  req_wstrb;
  logic        rsp_valid = 0, rsp_last = 0, rsp_err = 0;
  logic [31:0] rsp_data = 0;
  logic        miss_evt;

  always #5 clk = ~clk;
  always @(posedge clk) cyc++;

  dcache #(.ENABLE(ENABLE), .LINES(LINES), .LINE_BYTES(LINE_BYTES)) dut (.*);

  `include "native_mem.svh"

  // ---- V3 assertions ------------------------------------------------------------------
  ap_req_stable: assert property (@(posedge clk) disable iff (!rst_n)
                    (req_valid && !req_ready) |=> (req_valid && $stable(req_addr) && $stable(req_write)));
  ap_wr_single:  assert property (@(posedge clk) disable iff (!rst_n) (req_valid && req_write) |-> (req_len == 0));
  ap_wr_strobe:  assert property (@(posedge clk) disable iff (!rst_n) (req_valid && req_write) |-> (req_wstrb != 0));
  ap_err_busy:   assert property (@(posedge clk) disable iff (!rst_n) (cpu_ready && cpu_err) |-> cpu_busy);
  ap_req_busy:   assert property (@(posedge clk) disable iff (!rst_n) req_valid |-> cpu_busy);
  ap_mmio_single: assert property (@(posedge clk) disable iff (!rst_n)
                    (req_valid && !req_write && req_addr[31:28] == 4'h4) |-> (req_len == 0));
  ap_refill_geom: assert property (@(posedge clk) disable iff (!rst_n)
                    (req_valid && !req_write && req_len != 0) |->
                    (ENABLE && req_addr[OFFW-1:0] == 0 && req_len == 8'(WORDS - 1)));
  // R2 safety: a cacheable load "hit" (no bus activity) must be a line the memory delivered
  always @(negedge clk) begin
    #3;
    if (rst_n && ENABLE && cpu_req && !cpu_we && cpu_ready && !cpu_err && !cpu_busy &&
        cpu_addr[31:28] != 4'h4)
      assert (line_present(cpu_addr))
        else $error("dcache: load hit on a line the memory never fully delivered (addr=%08h)", cpu_addr);
  end

  // ---- helpers ------------------------------------------------------------------------------
  function automatic logic [31:0] lane_mask(input logic [3:0] be);
    return {{8{be[3]}}, {8{be[2]}}, {8{be[1]}}, {8{be[0]}}};
  endfunction
  function automatic bit cacheable(input logic [31:0] a);
    return ENABLE && (a[31:28] != 4'h4);
  endfunction

  int last_waited = 0;
  logic [31:0] res_data = 0;  bit res_err = 0;     // result captured at completion

  task automatic access(input bit we, input logic [31:0] a, input logic [31:0] wd, input logic [3:0] be,
                        input bit is_rand);
    bit          exp_hit0, exp_err;
    logic [31:0] exp_data, wa;
    int          waited = 0, wr0, rd0;
    wa = a & ~32'd3;
    @(negedge clk);
    exp_hit0 = !we && cacheable(a) && line_present(a);
    wr0 = n_wr_req; rd0 = n_rd_req;
    cpu_req = 1; cpu_we = we; cpu_addr = a; cpu_wdata = wd; cpu_be = be;
    #1;
    if (is_rand) rchk("ready_exact", {63'd0, exp_hit0}, {63'd0, cpu_ready});
    else         chk($sformatf("ready_exact a=%08h we=%0b", a, we), {63'd0, exp_hit0}, {63'd0, cpu_ready});
    if (exp_hit0) cov_hit(0); else cov_hit(1);
    while (!cpu_ready && waited < 800) begin @(negedge clk); #1; waited++; end
    last_waited = waited;
    res_data = cpu_rdata; res_err = cpu_err;
    if (waited >= 800) chk("TIMEOUT", 64'd1, 64'd0);
    // ---- expected result
    if (we)                  exp_err = in_err(wa);
    else if (exp_hit0)       exp_err = 1'b0;
    else if (cacheable(a))   exp_err = in_err(a & ~32'(LINE_BYTES - 1));
    else                     exp_err = in_err(wa);
    if (is_rand) rchk("err", {63'd0, exp_err}, {63'd0, cpu_err});
    else         chk($sformatf("err a=%08h we=%0b", a, we), {63'd0, exp_err}, {63'd0, cpu_err});
    if (!we && !exp_err) begin
      exp_data = (exp_hit0 || cacheable(a)) ? mword(a) : last_bus_rdata;
      if (is_rand) rchk("load_data", {32'd0, exp_data}, {32'd0, cpu_rdata});
      else         chk($sformatf("load_data a=%08h", a), {32'd0, exp_data}, {32'd0, cpu_rdata});
    end
    // ---- bus-side expectations
    if (we) begin
      chk("store_one_bus_write", 64'(wr0 + 1), 64'(n_wr_req));
      chk("store_addr",   {32'd0, wa}, {32'd0, last_req_addr});
      chk("store_strobe", {60'd0, be}, {60'd0, last_req_wstrb});
      chk("store_data",   {32'd0, wd & lane_mask(be)}, {32'd0, last_req_wdata & lane_mask(be)});
      chk("store_no_burst", 64'd0, {56'd0, last_req_len});
      cov_hit(2);
      if (cacheable(a) && line_present(a)) cov_hit(3); else cov_hit(4);   // write hit / miss
      if (be != 4'hF) cov_hit(5);
      if (exp_err) cov_hit(6);
    end else begin
      if (exp_hit0) chk("load_hit_no_bus", 64'(rd0), 64'(n_rd_req));
      else if (cacheable(a)) begin
        chk("load_miss_one_refill", 64'(rd0 + 1), 64'(n_rd_req));
        chk("refill_addr_aligned", {32'd0, a & ~32'(LINE_BYTES - 1)}, {32'd0, last_req_addr});
        chk("refill_len", {56'd0, 8'(WORDS - 1)}, {56'd0, last_req_len});
        cov_hit(7);
      end else begin
        chk("uncached_load_one_read", 64'(rd0 + 1), 64'(n_rd_req));
        chk("uncached_load_single_beat", 64'd0, {56'd0, last_req_len});
        chk("uncached_load_addr", {32'd0, wa}, {32'd0, last_req_addr});
        if (a[31:28] == 4'h4) cov_hit(8);
      end
      if (exp_err) cov_hit(9);
    end
    @(posedge clk);                                   // request consumed on this edge
    @(negedge clk);
    cpu_req = 0; cpu_we = 0;
  endtask

  task automatic ld(input logic [31:0] a, input bit r = 0); access(0, a, 32'd0, 4'h0, r); endtask
  task automatic st(input logic [31:0] a, input logic [31:0] d, input logic [3:0] be, input bit r = 0);
    access(1, a, d, be, r);
  endtask

  initial begin
    logic [31:0] A, B, C, M;
    int          n0;
    tb_init($sformatf("dcache_e%0d_l%0d_b%0d", ENABLE, LINES, LINE_BYTES));
    cov_def(0,"load_hit"); cov_def(1,"load_or_store_or_uncached_at_apply"); cov_def(2,"store");
    cov_def(3,"store_hit"); cov_def(4,"store_miss"); cov_def(5,"partial_byte_store");
    cov_def(6,"store_bus_error"); cov_def(7,"load_refill"); cov_def(8,"mmio_load_bypass");
    cov_def(9,"load_bus_error"); cov_def(10,"conflict_evict"); cov_def(11,"mmio_store");
    mem_init();
    repeat (3) @(negedge clk);
    rst_n = 1; @(negedge clk);

    A = 32'h0000_0040; B = A + 32'(LINES * LINE_BYTES); C = A + 32'(LINE_BYTES);
    M = 32'h4000_0100;                                       // peripheral space

    // ---- V1: load miss, hit, same-line words ----------------------------------------------
    ld(A);
    chk_t("first_load_missed", last_waited > 0);
    ld(A);
    if (ENABLE) chk("load_hit_zero_wait", 64'd0, 64'(last_waited));
    for (int w = 1; w < WORDS; w++) ld(A + 32'(4 * w));
    // ---- V1: write-through store hit, then coherent read-back -------------------------------------
    st(A, 32'hAABB_CCDD, 4'hF); ld(A);
    st(A + 4, 32'h1122_3344, 4'hF); ld(A + 4);
    // byte / halfword strobes on a hit, read-back merges correctly
    st(A, 32'h0000_00EE, 4'b0001); ld(A);
    st(A, 32'h0000_EE00, 4'b0010); ld(A);
    st(A, 32'h00EE_0000, 4'b0100); ld(A);
    st(A, 32'hEE00_0000, 4'b1000); ld(A);
    st(A + 4, 32'h1234_0000, 4'b1100); ld(A + 4);
    st(A + 4, 32'h0000_5678, 4'b0011); ld(A + 4);
    // ---- V1: no-write-allocate: a store miss must not create a line -------------------------------
    st(C, 32'hDEAD_BEEF, 4'hF);                              // C not present
    if (ENABLE) chk("store_miss_no_allocate", 64'd0, {63'd0, line_present(C)});
    ld(C);                                                   // must miss (exact check) and see the stored value
    chk("store_miss_visible", 64'hDEAD_BEEF, {32'd0, res_data});
    // ---- V1: conflict eviction ----------------------------------------------------------------------
    ld(B); ld(A); ld(B);
    if (ENABLE) cov_hit(10);
    st(B, 32'h0F0F_0F0F, 4'hF); ld(B);                       // hit on B after eviction cycle
    // ---- V1: peripheral space is never cached --------------------------------------------------------
    ld(M); begin logic [31:0] v1 = res_data; ld(M); chk_t("mmio_reads_differ", res_data != v1); end
    n0 = n_wr_req; st(M, 32'h0000_0055, 4'b0001);
    chk("mmio_store_reaches_bus", 64'(n0 + 1), 64'(n_wr_req)); cov_hit(11);
    ld(M + 4); ld(M + 4);
    // ---- V1: load bus error ---------------------------------------------------------------------------
    err_lo = 32'h0000_0200; err_hi = 32'h0000_020F | 32'(LINE_BYTES - 1);
    ld(32'h0000_0200);
    chk("load_error_flagged", 64'd1, {63'd0, res_err});
    ld(32'h0000_0200);                                       // line was not installed: misses & errors again
    chk("load_error_again", 64'd1, {63'd0, res_err});
    // ---- V1: store bus error must NOT update the cache ---------------------------------------------------
    err_lo = 32'hFFFF_FFFF; err_hi = 0;
    ld(32'h0000_0300);                                       // bring the line in
    err_lo = 32'h0000_0300; err_hi = 32'h0000_030F | 32'(LINE_BYTES - 1);
    st(32'h0000_0300, 32'hBAD0_BAD0, 4'hF);                  // bus write fails
    chk("store_error_flagged", 64'd1, {63'd0, res_err});
    ld(32'h0000_0300);                                       // hit: must still be the OLD data (mem unchanged)
    err_lo = 32'hFFFF_FFFF; err_hi = 0;
    // ---- V1: back-to-back mixed ops with latency and gaps ----------------------------------------------------
    lat_max = 5; gap_pct = 50;
    ld(32'h0000_0500); st(32'h0000_0504, 32'h1357_9BDF, 4'hF); ld(32'h0000_0504);
    ld(32'h0000_0500 + 32'(LINES * LINE_BYTES)); ld(32'h0000_0500);
    lat_max = 2; gap_pct = 0;

    // ---- V2/V5: 120 randomized accesses -------------------------------------------------------------------------
    for (int i = 0; i < 120; i++) begin
      logic [31:0] a, wd;
      logic [3:0]  be;
      bit          is_st;
      lat_max = $urandom_range(0, 1) ? 0 : 4;
      gap_pct = ($urandom_range(0, 3) == 0) ? 40 : 0;
      if ($urandom_range(0, 24) == 0) begin                       // flip error window on a fixed line
        if (err_lo == 32'hFFFF_FFFF) begin
          err_lo = 32'h0000_0080 & ~32'(LINE_BYTES - 1); err_hi = err_lo + 32'(LINE_BYTES - 1);
        end else begin err_lo = 32'hFFFF_FFFF; err_hi = 0; end
      end
      a = ($urandom_range(0, 19) == 0) ? (32'h4000_0000 | (32'($urandom_range(0, 15)) * 4))
                                       : (32'($urandom_range(0, 255)) * 4);
      a = (a[31:28] == 4'h4) ? a : (a & 32'h0000_03FF);
      is_st = ($urandom_range(0, 9) < 4);
      case ($urandom_range(0, 2))                                  // byte / half / word, lane-replicated like the core
        0: begin be = 4'b0001 << $urandom_range(0, 3); a = a + (be == 4'b0010 ? 1 : be == 4'b0100 ? 2 : be == 4'b1000 ? 3 : 0);
                 wd = {4{8'($urandom())}}; end
        1: begin be = $urandom_range(0, 1) ? 4'b1100 : 4'b0011; wd = {2{16'($urandom())}}; end
        default: begin be = 4'hF; wd = $urandom(); end
      endcase
      if (is_st) st(a, wd, be, 1); else ld(a, 1);
    end

    finish_report();
    $finish;
  end
endmodule
