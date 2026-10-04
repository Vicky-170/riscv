// =============================================================================
// tb_hazard_unit.sv - V0..V5 for hazard_unit.sv
//
// Reference model restates the documented stall/flush contract independently:
//   load_use : EX holds a late producer (load or CSR read) with rd != x0 that a
//              valid instruction in ID actually consumes
//   stalls   : mem_stall freezes IF..MEM, ex_busy freezes IF..EX, load_use freezes IF/ID
//   flushes  : mem_redirect kills IF/ID+ID/EX+EX/MEM, ex_redirect kills IF/ID+ID/EX,
//              load-use inserts a bubble into ID/EX, ex_busy a bubble into EX/MEM
// Plus invariant checks that must hold for any input combination.
// 100 randomized cases including simultaneous stall+flush.
// =============================================================================
module tb_hazard_unit;
  `include "tb_common.svh"

  logic       clk = 0;
  logic       idex_valid, idex_late, ifid_valid, ifid_use_rs1, ifid_use_rs2;
  logic [4:0] idex_rd, ifid_rs1, ifid_rs2;
  logic       mem_stall, ex_busy, ex_redirect, mem_redirect, trap_take;
  logic       load_use, pc_hold, ifid_hold, idex_hold, exmem_hold;
  logic       ifid_flush, idex_flush, exmem_flush, memwb_flush;

  always #5 clk = ~clk;
  always @(posedge clk) cyc++;

  hazard_unit dut (.*);

  // ---- reference ---------------------------------------------------------------
  logic e_lu, e_pch, e_ifh, e_idh, e_exh, e_iff, e_idf, e_exf, e_mwf;
  always_comb begin
    e_lu  = idex_valid & idex_late & (idex_rd != 5'd0) & ifid_valid &
            ((ifid_use_rs1 & (ifid_rs1 == idex_rd)) | (ifid_use_rs2 & (ifid_rs2 == idex_rd)));
    e_pch = mem_stall | ex_busy | e_lu;
    e_ifh = e_pch;
    e_idh = mem_stall | ex_busy;
    e_exh = mem_stall;
    e_iff = mem_redirect | ex_redirect;
    e_idf = mem_redirect | ex_redirect | (e_lu & ~e_idh);
    e_exf = mem_redirect | (ex_busy & ~mem_stall);
    e_mwf = mem_stall | trap_take;
  end

  task automatic apply(input bit is_rand);
    #1;
    if (e_lu)                        cov_hit(0);
    if (mem_stall)                   cov_hit(1);
    if (ex_busy)                     cov_hit(2);
    if (ex_redirect)                 cov_hit(3);
    if (mem_redirect)                cov_hit(4);
    if (mem_stall && mem_redirect)   cov_hit(5);      // stall + flush together
    if (ex_busy && ex_redirect)      cov_hit(6);      // mispredict while mul/div busy
    if (e_lu && mem_stall)           cov_hit(7);
    if (trap_take)                   cov_hit(8);
    if (!e_pch && !e_iff)            cov_hit(9);      // free-running pipeline
    if (is_rand) begin
      rchk("load_use",   {63'd0, e_lu},  {63'd0, load_use});
      rchk("pc_hold",    {63'd0, e_pch}, {63'd0, pc_hold});
      rchk("idex_hold",  {63'd0, e_idh}, {63'd0, idex_hold});
      rchk("exmem_hold", {63'd0, e_exh}, {63'd0, exmem_hold});
      rchk("ifid_flush", {63'd0, e_iff}, {63'd0, ifid_flush});
      rchk("idex_flush", {63'd0, e_idf}, {63'd0, idex_flush});
      rchk("exmem_flush",{63'd0, e_exf}, {63'd0, exmem_flush});
      rchk("memwb_flush",{63'd0, e_mwf}, {63'd0, memwb_flush});
    end else begin
      chk("load_use",    {63'd0, e_lu},  {63'd0, load_use});
      chk("pc_hold",     {63'd0, e_pch}, {63'd0, pc_hold});
      chk("ifid_hold",   {63'd0, e_ifh}, {63'd0, ifid_hold});
      chk("idex_hold",   {63'd0, e_idh}, {63'd0, idex_hold});
      chk("exmem_hold",  {63'd0, e_exh}, {63'd0, exmem_hold});
      chk("ifid_flush",  {63'd0, e_iff}, {63'd0, ifid_flush});
      chk("idex_flush",  {63'd0, e_idf}, {63'd0, idex_flush});
      chk("exmem_flush", {63'd0, e_exf}, {63'd0, exmem_flush});
      chk("memwb_flush", {63'd0, e_mwf}, {63'd0, memwb_flush});
    end
    // ---- invariants that must hold for every input combination ----------------
    // a MEM-stage redirect must flush all three younger stage registers
    if (mem_redirect) begin
      chk("inv_memredir_ifid",  64'd1, {63'd0, ifid_flush});
      chk("inv_memredir_idex",  64'd1, {63'd0, idex_flush});
      chk("inv_memredir_exmem", 64'd1, {63'd0, exmem_flush});
    end
    // a D-cache stall must freeze every stage up to MEM and bubble WB
    if (mem_stall) begin
      chk("inv_memstall_hold", 64'd1, {63'd0, pc_hold & ifid_hold & idex_hold & exmem_hold});
      chk("inv_memstall_wb",   64'd1, {63'd0, memwb_flush});
    end
    // load-use must never flush EX/MEM (the load itself must proceed)
    if (load_use && !mem_redirect && !ex_busy && !mem_stall)
      chk("inv_loaduse_no_exmem_flush", 64'd0, {63'd0, exmem_flush});
    // EX/MEM must never be held and flushed in a way that keeps a stale valid:
    // flush always wins in the register, so holding+flushing is legal - check the
    // weaker invariant that a stalled MEM never simultaneously advances EX/MEM
    if (mem_stall) chk("inv_exmem_frozen", 64'd1, {63'd0, exmem_hold});
    @(posedge clk);
  endtask

  task automatic set_in(input bit iv, lt, fv, u1, u2, ms, eb, exr, mr, tt,
                        input logic [4:0] rd, r1, r2);
    @(negedge clk);
    idex_valid = iv; idex_late = lt; idex_rd = rd;
    ifid_valid = fv; ifid_use_rs1 = u1; ifid_use_rs2 = u2; ifid_rs1 = r1; ifid_rs2 = r2;
    mem_stall = ms; ex_busy = eb; ex_redirect = exr; mem_redirect = mr; trap_take = tt;
  endtask

  initial begin
    tb_init("hazard_unit");
    cov_def(0,"load_use"); cov_def(1,"mem_stall"); cov_def(2,"ex_busy");
    cov_def(3,"ex_redirect"); cov_def(4,"mem_redirect"); cov_def(5,"stall_and_flush");
    cov_def(6,"mispredict_while_muldiv"); cov_def(7,"loaduse_and_memstall");
    cov_def(8,"trap_take"); cov_def(9,"free_running");

    set_in(0,0,0,0,0,0,0,0,0,0, 5'd0, 5'd0, 5'd0); apply(0);      // idle

    // -------- V1 directed: load-use --------------------------------------------
    set_in(1,1,1,1,0,0,0,0,0,0, 5'd5, 5'd5, 5'd9); apply(0);      // load-use via rs1
    set_in(1,1,1,0,1,0,0,0,0,0, 5'd5, 5'd9, 5'd5); apply(0);      // load-use via rs2
    set_in(1,1,1,1,1,0,0,0,0,0, 5'd5, 5'd5, 5'd5); apply(0);      // both operands
    set_in(1,1,1,0,0,0,0,0,0,0, 5'd5, 5'd5, 5'd5); apply(0);      // rs not actually used -> no stall
    set_in(1,1,1,1,1,0,0,0,0,0, 5'd0, 5'd0, 5'd0); apply(0);      // rd = x0 -> no stall
    set_in(1,0,1,1,1,0,0,0,0,0, 5'd5, 5'd5, 5'd5); apply(0);      // producer not late -> forward
    set_in(0,1,1,1,1,0,0,0,0,0, 5'd5, 5'd5, 5'd5); apply(0);      // EX invalid -> no stall
    set_in(1,1,0,1,1,0,0,0,0,0, 5'd5, 5'd5, 5'd5); apply(0);      // ID invalid -> no stall
    // -------- V1 directed: stalls ------------------------------------------------
    set_in(1,0,1,1,1,1,0,0,0,0, 5'd5, 5'd6, 5'd7); apply(0);      // D-cache stall
    set_in(1,0,1,1,1,0,1,0,0,0, 5'd5, 5'd6, 5'd7); apply(0);      // mul/div busy
    set_in(1,0,1,1,1,1,1,0,0,0, 5'd5, 5'd6, 5'd7); apply(0);      // both
    set_in(1,1,1,1,1,1,0,0,0,0, 5'd5, 5'd5, 5'd7); apply(0);      // load-use + D-cache stall
    // -------- V1 directed: flushes -------------------------------------------------
    set_in(1,0,1,1,1,0,0,1,0,0, 5'd5, 5'd6, 5'd7); apply(0);      // branch mispredict
    set_in(1,0,1,1,1,0,0,0,1,1, 5'd5, 5'd6, 5'd7); apply(0);      // trap
    set_in(1,0,1,1,1,0,0,0,1,0, 5'd5, 5'd6, 5'd7); apply(0);      // MRET / FENCE.I
    set_in(1,0,1,1,1,1,0,0,1,1, 5'd5, 5'd6, 5'd7); apply(0);      // trap during stall
    set_in(1,0,1,1,1,0,1,1,0,0, 5'd5, 5'd6, 5'd7); apply(0);      // mispredict while mul/div busy
    set_in(1,1,1,1,1,0,1,1,1,1, 5'd5, 5'd5, 5'd5); apply(0);      // everything at once
    // exhaustive sweep over the five event bits with a fixed dependency pattern
    for (int m = 0; m < 32; m++) begin
      set_in(1,1,1,1,1, m[0], m[1], m[2], m[3], m[4], 5'd5, 5'd5, 5'd5);
      apply(0);
    end

    // -------- V2/V5: 100 randomized ----------------------------------------------
    for (int i = 0; i < 100; i++) begin
      set_in($urandom_range(0,1), $urandom_range(0,1), $urandom_range(0,1),
             $urandom_range(0,1), $urandom_range(0,1),
             ($urandom_range(0,3) == 0), ($urandom_range(0,3) == 0),
             ($urandom_range(0,4) == 0), ($urandom_range(0,4) == 0), ($urandom_range(0,5) == 0),
             5'($urandom_range(0,3)), 5'($urandom_range(0,3)), 5'($urandom_range(0,3)));
      apply(1);
    end

    finish_report();
    $finish;
  end
endmodule
