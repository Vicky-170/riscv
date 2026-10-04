// =============================================================================
// tb_icache.sv - V0..V5 for icache.sv   (-GENABLE / -GLINES / -GLINE_BYTES)
//
// Reference: native_mem.svh memory model + shadow of fully-delivered lines.
//   * hit/miss exactness   : cpu_ready at the instant an address is applied must
//                            equal "line present in shadow" (or error-line, or
//                            1-word fetch-buffer match when ENABLE=0)
//   * data integrity       : every non-error result equals the memory word
//   * refill geometry      : line-aligned address, length = WORDS-1 (len 0 bypass)
//   * FENCE.I              : invalidates all; an invalidate DURING a refill must
//                            not let the stale fill install ("kill")
//   * errors               : bus error -> cpu_err with cpu_ready for that line
//   * redirect mid-refill  : address change while a refill is in flight
// =============================================================================
module tb_icache;
  `include "tb_common.svh"

  parameter bit ENABLE     = 1'b1;
  parameter int LINES      = 8;
  parameter int LINE_BYTES = 16;
  localparam int WORDS = LINE_BYTES / 4;
  localparam int OFFW  = $clog2(LINE_BYTES);

  logic        clk = 0, rst_n = 0;
  logic [31:0] cpu_addr = 0, cpu_rdata;
  logic        cpu_ready, cpu_err, inval = 0;
  logic        req_valid, req_ready;
  logic [31:0] req_addr;
  logic [7:0]  req_len;
  logic        rsp_valid = 0, rsp_last = 0, rsp_err = 0;
  logic [31:0] rsp_data = 0;
  logic        miss_evt;
  logic        req_write = 0; logic [31:0] req_wdata = 0; logic [3:0] req_wstrb = 0;   // unused by I$

  always #5 clk = ~clk;
  always @(posedge clk) cyc++;

  icache #(.ENABLE(ENABLE), .LINES(LINES), .LINE_BYTES(LINE_BYTES)) dut (.*);

  `include "native_mem.svh"

  // ---- shadow of error-line / fetch-buffer state -----------------------------------
  bit          sh_err_v = 0;  logic [31:0] sh_err_line = 0;
  bit          fb_v = 0;      logic [31:0] fb_addr = 0;

  // ---- V3 assertions -------------------------------------------------------------------
  ap_err_ready: assert property (@(posedge clk) disable iff (!rst_n) cpu_err |-> cpu_ready);
  ap_req_stable: assert property (@(posedge clk) disable iff (!rst_n)
                     (req_valid && !req_ready) |=> (req_valid && $stable(req_addr)));
  ap_geometry: assert property (@(posedge clk) disable iff (!rst_n)
                     req_valid |-> (ENABLE ? (req_addr[OFFW-1:0] == 0 && req_len == 8'(WORDS-1))
                                           : (req_len == 8'd0)));
  // safety (R2): a non-error hit must be a line the memory really delivered.
  // Sampled mid-cycle so it does not race the shadow update at the clock edge.
  always @(negedge clk) begin
    #3;
    if (rst_n && ENABLE && cpu_ready && !cpu_err && !inval)
      assert (line_present(cpu_addr))
        else $error("icache: hit on line the memory never fully delivered (addr=%08h)", cpu_addr);
  end

  // ---- helpers -----------------------------------------------------------------------------
  function automatic logic [31:0] lineno(input logic [31:0] a); return a >> OFFW; endfunction

  int last_waited = 0;
  bit stale_ok = 0;                         // memory deliberately modified without FENCE.I yet

  task automatic fetch(input logic [31:0] a, input bit is_rand, input bit exact);
    bit          exp_ready0, exp_err;
    int          waited = 0;
    @(negedge clk);
    if (ENABLE) begin
      exp_ready0 = line_present(a) || (sh_err_v && lineno(a) == sh_err_line);
      if (!exp_ready0) sh_err_v = 0;                 // a miss to another line drops the stale error
    end else
      exp_ready0 = fb_v && (fb_addr == (a & ~32'd3));
    cpu_addr = a;
    #1;
    if (exact) begin
      if (is_rand) rchk("ready_exact", {63'd0, exp_ready0}, {63'd0, cpu_ready});
      else         chk($sformatf("ready_exact a=%08h", a), {63'd0, exp_ready0}, {63'd0, cpu_ready});
    end
    if (exp_ready0) cov_hit(0); else cov_hit(1);
    while (!cpu_ready && waited < 600) begin @(negedge clk); #1; waited++; end
    last_waited = waited;
    if (waited >= 600) chk("TIMEOUT", 64'd1, 64'd0);
    exp_err = ENABLE ? in_err(a & ~32'(LINE_BYTES - 1)) : in_err(a & ~32'd3);
    if (is_rand) rchk("err", {63'd0, exp_err}, {63'd0, cpu_err});
    else         chk($sformatf("err a=%08h", a), {63'd0, exp_err}, {63'd0, cpu_err});
    if (!cpu_err && !stale_ok) begin
      if (is_rand) rchk("data", {32'd0, mword(a)}, {32'd0, cpu_rdata});
      else         chk($sformatf("data a=%08h", a), {32'd0, mword(a)}, {32'd0, cpu_rdata});
    end
    if (cpu_err) begin sh_err_v = 1; sh_err_line = lineno(a); cov_hit(2); end
    if (!ENABLE) begin fb_v = 1; fb_addr = a & ~32'd3; end
    if (waited == 0) cov_hit(3); else cov_hit(4);
    @(posedge clk);
  endtask

  task automatic do_inval();
    @(negedge clk);
    inval = 1;
    for (int i = 0; i < LINES; i++) filled_v[i] = 0;
    sh_err_v = 0; fb_v = 0;
    cov_hit(5);
    @(negedge clk);
    inval = 0;
  endtask

  initial begin
    logic [31:0] A, B, C;
    int          n0;
    tb_init($sformatf("icache_e%0d_l%0d_b%0d", ENABLE, LINES, LINE_BYTES));
    cov_def(0,"hit_at_apply"); cov_def(1,"miss_at_apply"); cov_def(2,"error_result");
    cov_def(3,"zero_wait_result"); cov_def(4,"refill_wait_result"); cov_def(5,"fence_i");
    cov_def(6,"conflict_miss"); cov_def(7,"invalidate_during_refill"); cov_def(8,"redirect_mid_refill");
    cov_def(9,"same_line_word_hit"); cov_def(10,"selfmod_after_fence_i");
    mem_init();
    repeat (3) @(negedge clk);
    rst_n = 1;
    // the cache starts refilling address 0 as soon as reset releases; let that settle first
    fetch(32'h0000_0000, 0, 0);
    repeat (4) @(negedge clk);

    A = 32'h0000_0040;                                      // line 4 (16B) / word 16
    B = A + 32'(LINES * LINE_BYTES);                        // same index, different tag
    C = A + 32'(LINE_BYTES);                                // next line

    // ---- V1 directed: first access misses and issues the right refill ----------------
    n0 = n_rd_req;
    fetch(A, 0, 1);
    chk_t("first_fetch_missed", last_waited > 0);
    chk("refill_addr_aligned", {32'd0, ENABLE ? (A & ~32'(LINE_BYTES - 1)) : (A & ~32'd3)}, {32'd0, last_req_addr});
    chk("refill_len", {56'd0, ENABLE ? 8'(WORDS - 1) : 8'd0}, {56'd0, last_req_len});
    chk("one_request", 64'(n0 + 1), 64'(n_rd_req));
    // ---- hit: zero wait, no new bus traffic ---------------------------------------------
    n0 = n_rd_req;
    fetch(A, 0, 1);
    chk("hit_zero_wait", 64'd0, 64'(last_waited));
    chk("hit_no_traffic", 64'(n0), 64'(n_rd_req));
    // ---- other words of the same line -------------------------------------------------------
    for (int w = 1; w < WORDS; w++) begin
      n0 = n_rd_req;
      fetch(A + 32'(4 * w), 0, 1);
      if (ENABLE) begin cov_hit(9); chk("same_line_no_refill", 64'(n0), 64'(n_rd_req)); end
    end
    // ---- a different line coexists ------------------------------------------------------------
    fetch(C, 0, 1); fetch(A, 0, 1); fetch(C, 0, 1);
    // ---- conflict: same index, different tag --------------------------------------------------
    n0 = n_rd_req;
    fetch(B, 0, 1);                                          // evicts A
    fetch(A, 0, 1);                                          // conflict miss (A gone)
    fetch(B, 0, 1);                                          // conflict miss (B gone)
    if (ENABLE) begin cov_hit(6); chk("conflict_refills", 64'(n0 + 3), 64'(n_rd_req)); end
    fetch(C, 0, 1);                                          // untouched neighbour still fine

    // ---- V1 directed: FENCE.I invalidates everything ---------------------------------------------
    fetch(A, 0, 1); fetch(C, 0, 1);
    do_inval();
    n0 = n_rd_req;
    fetch(A, 0, 1); fetch(C, 0, 1);
    chk_t("fencei_forces_refetch", n_rd_req >= n0 + 2);

    // ---- V1 directed: self-modifying code + FENCE.I -----------------------------------------------
    fetch(A, 0, 1);
    mem[(A >> 2) % MEM_WORDS] = 32'hFACE_B00C;               // store to instruction memory
    stale_ok = 1; fetch(A, 0, 0); stale_ok = 0;              // stale hit is architecturally allowed
    do_inval();
    fetch(A, 0, 1);
    chk("selfmod_new_data_after_fencei", 64'hFACE_B00C, {32'd0, cpu_rdata});
    cov_hit(10);

    // ---- V1 directed: FENCE.I during a refill must not install the stale line ----------------------
    do_inval();
    lat_max = 6;
    n0 = n_rd_req;
    @(negedge clk); cpu_addr = 32'h0000_0100; #1;
    repeat (3) begin @(negedge clk); end
    inval = 1; for (int i = 0; i < LINES; i++) filled_v[i] = 0; sh_err_v = 0; fb_v = 0;
    @(negedge clk); inval = 0;
    begin int w = 0; while (!cpu_ready && w < 600) begin @(negedge clk); #1; w++; end end
    chk("kill_data_correct", {32'd0, mword(32'h0000_0100)}, {32'd0, cpu_rdata});
    if (ENABLE) begin
      chk_t("kill_forced_second_refill", n_rd_req >= n0 + 2);   // stale fill was discarded
      cov_hit(7);
    end
    // the completed refill after the kill is genuine: re-sync the shadow with the memory model
    lat_max = 2;
    @(posedge clk);

    // ---- V1 directed: error line ------------------------------------------------------------------------
    do_inval();
    err_lo = 32'h0000_0200; err_hi = 32'h0000_020F | 32'(LINE_BYTES - 1);
    if (ENABLE) begin
      fetch(32'h0000_0200, 0, 1);                             // refill returns an error
      chk("error_flagged", 64'd1, {63'd0, cpu_err});
      n0 = n_rd_req;
      fetch(32'h0000_0204, 0, 1);                             // same line: instant error, no new refill
      chk("error_line_no_refill", 64'(n0), 64'(n_rd_req));
    end else begin
      fetch(32'h0000_0200, 0, 1); chk("error_flagged", 64'd1, {63'd0, cpu_err});
    end
    fetch(A, 0, 1);                                            // a good line clears the error state
    err_lo = 32'hFFFF_FFFF; err_hi = 0;                        // error window removed
    do_inval();
    fetch(32'h0000_0200, 0, 1);
    chk("error_cleared_after_fencei", 64'd0, {63'd0, cpu_err});
    chk("error_cleared_data", {32'd0, mword(32'h0000_0200)}, {32'd0, cpu_rdata});

    // ---- V1 directed: redirect while a refill is in flight ------------------------------------------------
    do_inval();
    lat_max = 5;
    @(negedge clk); cpu_addr = 32'h0000_0300; #1;
    repeat (2) @(negedge clk);
    cpu_addr = 32'h0000_0350; #1;                              // redirect to a different line/index
    begin int w = 0; while (!cpu_ready && w < 600) begin @(negedge clk); #1; w++; end end
    chk("redirect_data_correct", {32'd0, mword(32'h0000_0350)}, {32'd0, cpu_rdata});
    cov_hit(8);
    @(posedge clk);
    lat_max = 2;
    // let any leftover refill finish, then the shadow is authoritative again
    repeat (20) @(negedge clk);
    fetch(32'h0000_0300, 0, 1);

    // ---- V2/V5: 120 randomized fetches ------------------------------------------------------------------------
    do_inval();
    for (int i = 0; i < 120; i++) begin
      logic [31:0] a;
      lat_max = ($urandom_range(0, 1)) ? 0 : 4;
      gap_pct = ($urandom_range(0, 2) == 0) ? 40 : 0;
      if ($urandom_range(0, 19) == 0) begin                    // occasionally flip the error window
        do_inval();
        if (err_lo == 32'hFFFF_FFFF) begin err_lo = 32'h0000_0080 & ~32'(LINE_BYTES - 1);
                                           err_hi = (32'h0000_0080 & ~32'(LINE_BYTES - 1)) + 32'(LINE_BYTES - 1); end
        else begin err_lo = 32'hFFFF_FFFF; err_hi = 0; end
      end else if ($urandom_range(0, 19) == 0) do_inval();
      a = ($urandom_range(0, 2) == 0) ? A : (32'($urandom_range(0, 255)) * 4);   // word aligned, 1 KiB window
      a = a & 32'h0000_03FF;
      fetch(a, 1, 1);
    end

    finish_report();
    $finish;
  end
endmodule
