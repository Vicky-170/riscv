// =============================================================================
// tb_common.svh - shared verification infrastructure, included INSIDE each TB
//
// Why an include and not a package: Verilator 5.020 was observed to alias
// package-scope static counters in some testbenches (increments visible inside
// the calling task, but read back as 0 from the initial block), which would
// silently report "0 tests executed, 0 failures".  Module-scope state avoids
// that entirely and keeps every testbench self-contained.
//
// Provides: tb_init / chk / chk_t / rchk / cov_def / cov_hit / finish_report
//   * rchk writes one CSV row per randomized test:
//       test_id,seed,config,module,result,cycle,expected,actual
//   * finish_report prints one machine-readable RESULT line for the regression
//     script, including a nonzero-activity guard.
// =============================================================================

  int unsigned dir_pass = 0, dir_fail = 0, rnd_pass = 0, rnd_fail = 0;
  int unsigned rid = 0, cyc = 0, seed_q = 1;
  int unsigned first_fail_cyc = 32'hFFFF_FFFF;
  string       mod_name = "?";
  int          rlog_fd = 0;

  localparam int NCOV = 160;
  int unsigned cov_hits [NCOV];
  string       cov_name [NCOV];
  int unsigned cov_n = 0;

  function automatic void cov_def(input int unsigned id, input string nm);
    if (id < NCOV) begin
      cov_name[id] = nm;
      cov_hits[id] = 0;
      if (id + 1 > cov_n) cov_n = id + 1;
    end
  endfunction

  function automatic void cov_hit(input int unsigned id);
    if (id < NCOV) cov_hits[id] = cov_hits[id] + 1;
  endfunction

  function automatic void tb_init(input string m);
    int unsigned s = 1;
    mod_name = m;
    void'($value$plusargs("SEED=%d", s));
    if (s == 0) s = 1;
    seed_q = s;
    void'($urandom(seed_q));                     // deterministic stream for this seed
    rlog_fd = $fopen({"logs/random_", m, ".csv"}, "w");
    if (rlog_fd != 0) $fdisplay(rlog_fd, "test_id,seed,config,module,result,cycle,expected,actual");
    $display("[%s] START seed=%0d", m, seed_q);
  endfunction

  // ---- directed check ----------------------------------------------------------
  function automatic void chk(input string nm, input logic [63:0] exp, input logic [63:0] act);
    if (exp === act) dir_pass = dir_pass + 1;
    else begin
      dir_fail = dir_fail + 1;
      if (cyc < first_fail_cyc) first_fail_cyc = cyc;
      $display("[%s] DIR-FAIL %s cycle=%0d exp=0x%0h act=0x%0h", mod_name, nm, cyc, exp, act);
    end
  endfunction

  function automatic void chk_t(input string nm, input bit cond);
    chk(nm, 64'd1, cond ? 64'd1 : 64'd0);
  endfunction

  // ---- randomized check (logged) --------------------------------------------------
  function automatic void rchk(input string cfg, input logic [63:0] exp, input logic [63:0] act);
    bit ok;
    ok  = (exp === act);
    rid = rid + 1;
    if (ok) rnd_pass = rnd_pass + 1;
    else begin
      rnd_fail = rnd_fail + 1;
      if (cyc < first_fail_cyc) first_fail_cyc = cyc;
      $display("[%s] RND-FAIL id=%0d seed=%0d cfg=%s cycle=%0d exp=0x%0h act=0x%0h",
               mod_name, rid, seed_q, cfg, cyc, exp, act);
    end
    if (rlog_fd != 0)
      $fdisplay(rlog_fd, "%0d,%0d,%s,%s,%s,%0d,0x%0h,0x%0h",
                rid, seed_q, cfg, mod_name, ok ? "PASS" : "FAIL", cyc, exp, act);
  endfunction

  // ---- final report ---------------------------------------------------------------
  function automatic void finish_report();
    int unsigned covered = 0, nbins = 0;
    for (int i = 0; i < cov_n; i++)
      if (cov_name[i] != "") begin
        nbins = nbins + 1;
        if (cov_hits[i] != 0) covered = covered + 1;
        $display("[%s] COV %-30s hits=%0d%s", mod_name, cov_name[i], cov_hits[i],
                 (cov_hits[i] == 0) ? "   <-- HOLE" : "");
      end
    $display("RESULT module=%s seed=%0d dir_pass=%0d dir_fail=%0d rnd_pass=%0d rnd_fail=%0d rnd_total=%0d cov_bins=%0d cov_hit=%0d first_fail_cycle=%0d",
             mod_name, seed_q, dir_pass, dir_fail, rnd_pass, rnd_fail, rid, nbins, covered,
             (dir_fail + rnd_fail) != 0 ? first_fail_cyc : 0);
    if (rlog_fd != 0) $fclose(rlog_fd);
  endfunction
