// =============================================================================
// tb_pipeline_regs.sv - V0..V5 for pipeline_regs.sv (all four stage registers)
//
// Checks the documented contract:
//   * flush has priority over en (flush while holding still produces a bubble)
//   * reset/flush clear only the control part (valid / ctrl / exc / reg_write)
//   * the data payload loads on en=1 and holds on en=0
//   * a bubble carries no side-effect control bits
// 100 randomized sequences across all four registers.
// =============================================================================
module tb_pipeline_regs import rv32im_pkg::*;;
  `include "tb_common.svh"

  logic clk = 0, rst_n = 0;
  logic en, flush;

  if_id_t  a_d, a_q;
  id_ex_t  b_d, b_q;
  ex_mem_t c_d, c_q;
  mem_wb_t d_d, d_q;

  always #5 clk = ~clk;
  always @(posedge clk) cyc++;

  if_id_reg  u_a (.clk(clk), .rst_n(rst_n), .en(en), .flush(flush), .d(a_d), .q(a_q));
  id_ex_reg  u_b (.clk(clk), .rst_n(rst_n), .en(en), .flush(flush), .d(b_d), .q(b_q));
  ex_mem_reg u_c (.clk(clk), .rst_n(rst_n), .en(en), .flush(flush), .d(c_d), .q(c_q));
  mem_wb_reg u_d (.clk(clk), .rst_n(rst_n), .en(en), .flush(flush), .d(d_d), .q(d_q));

  // ---- assertions: a flush must produce a bubble in every register -----------
  ap_flush_a: assert property (@(posedge clk) disable iff (!rst_n) flush |=> !a_q.valid);
  ap_flush_b: assert property (@(posedge clk) disable iff (!rst_n) flush |=> !b_q.valid);
  ap_flush_c: assert property (@(posedge clk) disable iff (!rst_n) flush |=> !c_q.valid);
  ap_flush_d: assert property (@(posedge clk) disable iff (!rst_n) flush |=> !d_q.reg_write);
  // a bubble must carry no side-effect control bits
  ap_bubble_b: assert property (@(posedge clk) disable iff (!rst_n)
                                !b_q.valid |-> !(b_q.ctrl.reg_write | b_q.ctrl.mem_write));

  // reference state
  logic exp_av, exp_bv, exp_cv, exp_dw;
  logic [31:0] exp_apc, exp_bpc, exp_cpc, exp_ddata;

  task automatic drive_rand();
    a_d = '0; b_d = '0; c_d = '0; d_d = '0;
    a_d.valid = 1'b1; a_d.pc = $urandom();
    b_d.valid = 1'b1; b_d.pc = $urandom(); b_d.ctrl.reg_write = 1'b1; b_d.ctrl.mem_write = 1'b1;
    c_d.valid = 1'b1; c_d.pc = $urandom(); c_d.ctrl.reg_write = 1'b1;
    d_d.reg_write = 1'b1; d_d.data = $urandom();
  endtask

  task automatic step(input bit ven, vflush, input bit is_rand);
    @(negedge clk);                               // drive away from the active edge
    en = ven; flush = vflush;
    drive_rand();
    #1;
    // reference next state
    if (vflush)     begin exp_av=0; exp_bv=0; exp_cv=0; exp_dw=0; end
    else if (ven)   begin exp_av=a_d.valid; exp_bv=b_d.valid; exp_cv=c_d.valid; exp_dw=d_d.reg_write; end
    if (ven)        begin exp_apc=a_d.pc; exp_bpc=b_d.pc; exp_cpc=c_d.pc; exp_ddata=d_d.data; end
    if (vflush && ven)  cov_hit(0);                // flush wins over en
    if (vflush && !ven) cov_hit(1);                // flush while stalled
    if (!vflush && ven) cov_hit(2);                // normal advance
    if (!vflush && !ven)cov_hit(3);                // hold
    @(posedge clk);
    #1;
    if (is_rand) begin
      rchk("ifid_valid",  {63'd0, exp_av},  {63'd0, a_q.valid});
      rchk("idex_valid",  {63'd0, exp_bv},  {63'd0, b_q.valid});
      rchk("exmem_valid", {63'd0, exp_cv},  {63'd0, c_q.valid});
      rchk("memwb_rw",    {63'd0, exp_dw},  {63'd0, d_q.reg_write});
      rchk("ifid_pc",     {32'd0, exp_apc}, {32'd0, a_q.pc});
      rchk("memwb_data",  {32'd0, exp_ddata},{32'd0, d_q.data});
    end else begin
      chk("ifid_valid",  {63'd0, exp_av},  {63'd0, a_q.valid});
      chk("idex_valid",  {63'd0, exp_bv},  {63'd0, b_q.valid});
      chk("exmem_valid", {63'd0, exp_cv},  {63'd0, c_q.valid});
      chk("memwb_rw",    {63'd0, exp_dw},  {63'd0, d_q.reg_write});
      chk("ifid_pc",     {32'd0, exp_apc}, {32'd0, a_q.pc});
      chk("idex_pc",     {32'd0, exp_bpc}, {32'd0, b_q.pc});
      chk("exmem_pc",    {32'd0, exp_cpc}, {32'd0, c_q.pc});
      chk("memwb_data",  {32'd0, exp_ddata},{32'd0, d_q.data});
      // a bubble must clear the control bundle, not just valid
      if (!exp_bv) chk("idex_bubble_ctrl", 64'd0, {63'd0, b_q.ctrl.reg_write | b_q.ctrl.mem_write});
      if (!exp_cv) chk("exmem_bubble_ctrl", 64'd0, {63'd0, c_q.ctrl.reg_write});
    end
  endtask

  initial begin
    tb_init("pipeline_regs");
    cov_def(0,"flush_and_en"); cov_def(1,"flush_while_stalled");
    cov_def(2,"advance"); cov_def(3,"hold");

    en = 0; flush = 0; drive_rand();
    repeat (2) @(posedge clk); #1;
    chk("reset_ifid_valid",  64'd0, {63'd0, a_q.valid});
    chk("reset_idex_valid",  64'd0, {63'd0, b_q.valid});
    chk("reset_exmem_valid", 64'd0, {63'd0, c_q.valid});
    chk("reset_memwb_rw",    64'd0, {63'd0, d_q.reg_write});
    rst_n = 1;
    exp_av=0; exp_bv=0; exp_cv=0; exp_dw=0; exp_apc=0; exp_bpc=0; exp_cpc=0; exp_ddata=0;
    @(posedge clk);

    // -------- V1 directed: all four (en, flush) combinations ------------------
    step(1,0,0);           // advance
    step(0,0,0);           // hold - data must not change
    step(0,0,0);
    step(1,1,0);           // flush wins over en
    step(0,1,0);           // flush while stalled
    step(1,0,0);           // recover
    step(1,1,0);
    step(1,0,0);
    // data payload must survive a long stall
    step(1,0,0);
    repeat (5) step(0,0,0);
    step(1,0,0);

    // -------- V2/V5: 100 randomized ---------------------------------------------
    for (int i = 0; i < 100; i++)
      step($urandom_range(0,1), ($urandom_range(0,2) == 0), 1);

    finish_report();
    $finish;
  end
endmodule
