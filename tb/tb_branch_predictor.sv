// =============================================================================
// tb_branch_predictor.sv - V0..V5 for branch_predictor.sv (bht + btb + wrapper)
//   Run with -GENABLE_BHT / -GENABLE_BTB:  static (0,0), BHT-only (1,0), BHT+BTB (1,1).
//   Small tables (BHT 16, BTB 8) so index aliasing and BTB conflict evictions occur.
//   Reference model: shadow 2-bit counters + shadow BTB (valid/tag/target/uncond),
//   updated from the same training inputs; every prediction output is compared
//   each cycle.
// =============================================================================
module tb_branch_predictor;
  `include "tb_common.svh"

  parameter bit ENABLE_BHT  = 1'b1;
  parameter bit ENABLE_BTB  = 1'b1;
  localparam int BHT_N = 16, BTB_N = 8;
  localparam int BI = $clog2(BHT_N), TI = $clog2(BTB_N);

  logic        clk = 0, rst_n = 0;
  logic [31:0] if_pc = 0, id_pc = 0, if_pred_target;
  logic        if_pred_taken, id_bht_taken;
  logic        upd_valid = 0, upd_is_cond = 0, upd_taken = 0;
  logic [31:0] upd_pc = 0, upd_target = 0;

  always #5 clk = ~clk;
  always @(posedge clk) cyc++;

  branch_predictor #(.ENABLE_BHT(ENABLE_BHT), .ENABLE_BTB(ENABLE_BTB),
                     .BHT_ENTRIES(BHT_N), .BTB_ENTRIES(BTB_N)) dut (.*);

  // ---- V3 assertions ------------------------------------------------------------
  ap_static: assert property (@(posedge clk) disable iff (!rst_n)
                              (!ENABLE_BTB) |-> !if_pred_taken);
  ap_nobht:  assert property (@(posedge clk) disable iff (!rst_n)
                              (!ENABLE_BHT) |-> !id_bht_taken);
  ap_target_aligned: assert property (@(posedge clk) disable iff (!rst_n)
                              if_pred_taken |-> (if_pred_target[1:0] == 2'b00));

  // ---- reference model ------------------------------------------------------------
  logic [1:0]  m_ctr [BHT_N];
  bit          m_v   [BTB_N];
  logic [31:0] m_tag [BTB_N];
  logic [29:0] m_tgt [BTB_N];
  bit          m_unc [BTB_N];

  function automatic void mreset();
    for (int i = 0; i < BHT_N; i++) m_ctr[i] = 2'b01;       // weakly not-taken
    for (int i = 0; i < BTB_N; i++) begin m_v[i] = 0; m_tag[i] = 0; m_tgt[i] = 0; m_unc[i] = 0; end
  endfunction

  function automatic int bidx(input logic [31:0] pc); return int'(pc[BI+1:2]); endfunction
  function automatic int tidx(input logic [31:0] pc); return int'(pc[TI+1:2]); endfunction
  function automatic logic [31:0] ttag(input logic [31:0] pc); return pc >> (TI + 2); endfunction

  function automatic bit m_btb_hit(input logic [31:0] pc);
    return m_v[tidx(pc)] && (m_tag[tidx(pc)] == ttag(pc));
  endfunction
  function automatic bit m_pred_taken(input logic [31:0] pc);
    if (!ENABLE_BTB) return 1'b0;
    return m_btb_hit(pc) && (m_unc[tidx(pc)] || m_ctr[bidx(pc)][1]);
  endfunction
  function automatic logic [31:0] m_pred_target(input logic [31:0] pc);
    return {m_tgt[tidx(pc)], 2'b00};
  endfunction

  function automatic void mupdate();
    if (upd_valid && upd_is_cond && ENABLE_BHT) begin
      if (upd_taken) begin if (m_ctr[bidx(upd_pc)] != 2'b11) m_ctr[bidx(upd_pc)]++; end
      else           begin if (m_ctr[bidx(upd_pc)] != 2'b00) m_ctr[bidx(upd_pc)]--; end
    end
    if (upd_valid && upd_taken && ENABLE_BTB) begin
      m_v  [tidx(upd_pc)] = 1;
      m_tag[tidx(upd_pc)] = ttag(upd_pc);
      m_tgt[tidx(upd_pc)] = upd_target[31:2];
      m_unc[tidx(upd_pc)] = !upd_is_cond;
    end
  endfunction

  // ---- one cycle -------------------------------------------------------------------
  task automatic step(input bit is_rand);
    bit          e_tk, e_bht;
    logic [31:0] e_tg;
    #1;
    e_tk  = m_pred_taken(if_pc);
    e_tg  = m_pred_target(if_pc);
    e_bht = ENABLE_BHT ? m_ctr[bidx(id_pc)][1] : 1'b0;
    if (ENABLE_BTB && m_btb_hit(if_pc))  cov_hit(0);
    if (ENABLE_BTB && !m_btb_hit(if_pc)) cov_hit(1);
    if (e_tk)                            cov_hit(2);
    if (ENABLE_BHT && m_ctr[bidx(id_pc)] == 2'b00) cov_hit(3);
    if (ENABLE_BHT && m_ctr[bidx(id_pc)] == 2'b01) cov_hit(4);
    if (ENABLE_BHT && m_ctr[bidx(id_pc)] == 2'b10) cov_hit(5);
    if (ENABLE_BHT && m_ctr[bidx(id_pc)] == 2'b11) cov_hit(6);
    if (upd_valid && upd_is_cond && upd_taken)   cov_hit(7);
    if (upd_valid && upd_is_cond && !upd_taken)  cov_hit(8);
    if (upd_valid && !upd_is_cond && upd_taken)  cov_hit(9);   // JAL/JALR training
    if (upd_valid && ENABLE_BTB && upd_taken && m_v[tidx(upd_pc)] &&
        m_tag[tidx(upd_pc)] != ttag(upd_pc))     cov_hit(10);  // BTB conflict eviction
    if (upd_valid && ENABLE_BTB && upd_taken && m_btb_hit(upd_pc) &&
        m_tgt[tidx(upd_pc)] != upd_target[31:2]) cov_hit(11);  // target mismatch retrain
    if (upd_valid && ENABLE_BHT && upd_is_cond && upd_taken && m_ctr[bidx(upd_pc)] == 2'b11) cov_hit(12);
    if (upd_valid && ENABLE_BHT && upd_is_cond && !upd_taken && m_ctr[bidx(upd_pc)] == 2'b00) cov_hit(13);
    if (ENABLE_BHT && bidx(if_pc) == bidx(id_pc) && if_pc != id_pc) cov_hit(14);   // BHT alias
    if (is_rand) begin
      rchk("if_taken",  {63'd0, e_tk},  {63'd0, if_pred_taken});
      if (e_tk) rchk("if_target", {32'd0, e_tg}, {32'd0, if_pred_target});
      rchk("id_taken",  {63'd0, e_bht}, {63'd0, id_bht_taken});
    end else begin
      chk("if_taken",   {63'd0, e_tk},  {63'd0, if_pred_taken});
      if (e_tk) chk("if_target", {32'd0, e_tg}, {32'd0, if_pred_target});
      chk("id_taken",   {63'd0, e_bht}, {63'd0, id_bht_taken});
    end
    mupdate();
    @(posedge clk);
    @(negedge clk);
    upd_valid = 0;                                   // updates are single-cycle pulses
  endtask

  task automatic train(input logic [31:0] pc, tgt, input bit cond, taken);
    upd_valid = 1; upd_pc = pc; upd_target = tgt; upd_is_cond = cond; upd_taken = taken;
    if_pc = pc; id_pc = pc;
    step(0);
  endtask

  task automatic look(input logic [31:0] pc);
    upd_valid = 0; if_pc = pc; id_pc = pc; step(0);
  endtask

  localparam logic [31:0] A = 32'h0000_1040;                  // idx (bht) 0, btb idx 0
  localparam logic [31:0] B = 32'h0000_2040;                  // same BTB/BHT index as A, different tag
  localparam logic [31:0] C = 32'h0000_1044;                  // next index
  localparam logic [31:0] T1 = 32'h0000_3000, T2 = 32'h0000_4000;

  initial begin
    tb_init($sformatf("bp_%0d%0d", ENABLE_BHT, ENABLE_BTB));
    cov_def(0,"btb_hit"); cov_def(1,"btb_miss"); cov_def(2,"predict_taken");
    cov_def(3,"ctr_00"); cov_def(4,"ctr_01"); cov_def(5,"ctr_10"); cov_def(6,"ctr_11");
    cov_def(7,"train_cond_taken"); cov_def(8,"train_cond_nottaken"); cov_def(9,"train_uncond");
    cov_def(10,"btb_conflict_evict"); cov_def(11,"target_mismatch_retrain");
    cov_def(12,"ctr_saturate_high"); cov_def(13,"ctr_saturate_low"); cov_def(14,"bht_alias");
    mreset();
    repeat (3) @(negedge clk);
    rst_n = 1;
    @(negedge clk);

    // ---- V1 directed ---------------------------------------------------------------
    look(A); look(C);                                  // reset state: nothing predicted taken
    train(A, T1, 1, 1);                                // cond taken: 01 -> 10, BTB allocated
    look(A);
    train(A, T1, 1, 1);                                // 10 -> 11
    train(A, T1, 1, 1);                                // saturate at 11
    train(A, T1, 1, 1);
    look(A);
    train(A, T1, 1, 0);                                // 11 -> 10 : hysteresis, still taken
    look(A);
    train(A, T1, 1, 0);                                // 10 -> 01 : now not-taken
    look(A);
    train(A, T1, 1, 0);                                // 01 -> 00
    train(A, T1, 1, 0);                                // saturate at 00
    train(A, T1, 1, 0);
    look(A);
    train(A, T1, 1, 1);                                // 00 -> 01 : still not predicted taken
    look(A);
    train(A, T1, 1, 1);                                // 01 -> 10
    look(A);
    // not-taken conditional branch must not allocate a BTB entry
    look(C);
    train(C, T2, 1, 0);
    look(C);
    // unconditional (JAL/JALR): BTB entry marked uncond -> predicted taken regardless of BHT
    train(A, T1, 1, 0); train(A, T1, 1, 0); train(A, T1, 1, 0);   // drive counter low
    train(A, T2, 0, 1);                                // uncond with a *new target* (retrain)
    look(A);
    // target mismatch: same PC re-trained to a different target
    train(A, T1, 0, 1);
    look(A);
    train(A, T2, 0, 1);
    look(A);
    // conflict: B maps to the same index as A with a different tag -> evicts A
    train(B, T2, 0, 1);
    look(B); look(A);
    train(A, T1, 0, 1);                                // re-evict B
    look(A); look(B);
    // BHT aliasing: two PCs one index apart in tag share a counter
    train(A, T1, 1, 1); train(A, T1, 1, 1);
    look(B);
    // idle cycles: state must not change without upd_valid
    look(A); look(C); look(B);
    // update with upd_valid=0 but other fields toggling
    upd_valid = 0; upd_pc = A; upd_taken = 1; upd_is_cond = 1; upd_target = T2; look(A);
    // mid-run reset -> model and DUT return to weakly-not-taken / empty BTB
    rst_n = 0; @(negedge clk); @(negedge clk); mreset(); rst_n = 1; @(negedge clk);
    look(A); look(B);

    // ---- V2/V5: 130 randomized cycles ------------------------------------------------
    for (int i = 0; i < 130; i++) begin
      logic [31:0] pcs [6];
      // small PC pool so index conflicts, tag conflicts and repeat hits are frequent
      pcs = '{A, B, C, 32'h0000_1048, 32'h0000_3040, 32'h0000_5044};
      if_pc  = pcs[$urandom_range(0, 5)];
      id_pc  = pcs[$urandom_range(0, 5)];
      upd_valid   = ($urandom_range(0, 9) < 7);
      upd_pc      = pcs[$urandom_range(0, 5)];
      upd_is_cond = ($urandom_range(0, 9) < 7);
      // conditional branches: taken/not-taken mix; unconditional always taken
      upd_taken   = upd_is_cond ? ($urandom_range(0, 9) < 6) : 1'b1;
      upd_target  = {$urandom_range(0, 32'h3FFF), 2'b00} | 32'h0000_1000;
      step(1);
    end

    finish_report();
    $finish;
  end
endmodule
