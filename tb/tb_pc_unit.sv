// =============================================================================
// tb_pc_unit.sv - V0..V5 for pc_unit.sv
//   Reference model is a shadow PC updated with the documented priority:
//     redirect > prediction > pc+4, updated only on (redirect | advance),
//     with pc[1:0] forced to 0.
//   100 randomized cases with random advance/redirect/prediction activity.
// =============================================================================
module tb_pc_unit;
  `include "tb_common.svh"

  logic        clk = 0, rst_n = 0;
  logic        advance, redirect_valid, pred_taken;
  logic [31:0] redirect_pc, pred_target, pc, pc_plus4;

  localparam logic [31:0] RST_PC = 32'h0000_0000;

  always #5 clk = ~clk;
  always @(posedge clk) cyc++;

  pc_unit #(.RESET_PC(RST_PC)) dut (
    .clk(clk), .rst_n(rst_n), .advance(advance),
    .redirect_valid(redirect_valid), .redirect_pc(redirect_pc),
    .pred_taken(pred_taken), .pred_target(pred_target),
    .pc(pc), .pc_plus4(pc_plus4)
  );

  logic [31:0] shadow;                            // independent reference PC

  // ---- assertion: PC is always 4-byte aligned (IALIGN=32) --------------------
  ap_align: assert property (@(posedge clk) disable iff (!rst_n) (pc[1:0] == 2'b00));

  // drive one cycle, then compare against the reference
  task automatic step(input bit adv, rdv, prt, input logic [31:0] rpc, ptg, input bit is_rand);
    logic [31:0] exp;
    @(negedge clk);                               // drive away from the active edge
    advance = adv; redirect_valid = rdv; pred_taken = prt;
    redirect_pc = rpc; pred_target = ptg;
    #1;
    chk("pc_plus4", {32'd0, shadow + 32'd4}, {32'd0, pc_plus4});
    // reference next-state
    if (rdv)      exp = rpc;
    else if (prt) exp = ptg;
    else          exp = shadow + 32'd4;
    exp[1:0] = 2'b00;
    if (rdv || adv) shadow = exp;                 // else hold
    if (rdv)          cov_hit(0);
    else if (prt)     cov_hit(1);
    else              cov_hit(2);
    if (!adv && !rdv) cov_hit(3);                 // stalled hold
    if (rdv && !adv)  cov_hit(4);                 // redirect wins over stall
    if (rdv && prt)   cov_hit(5);                 // redirect wins over prediction
    @(posedge clk);
    #1;
    if (is_rand) rchk($sformatf("adv%0b rdv%0b prt%0b", adv, rdv, prt), {32'd0, shadow}, {32'd0, pc});
    else         chk($sformatf("pc adv=%0b rdv=%0b prt=%0b", adv, rdv, prt), {32'd0, shadow}, {32'd0, pc});
  endtask

  initial begin
    tb_init("pc_unit");
    cov_def(0,"redirect"); cov_def(1,"predicted_taken"); cov_def(2,"sequential");
    cov_def(3,"hold_on_stall"); cov_def(4,"redirect_over_stall"); cov_def(5,"redirect_over_prediction");

    advance = 0; redirect_valid = 0; pred_taken = 0; redirect_pc = 0; pred_target = 0;
    repeat (2) @(posedge clk);
    #1; chk("reset_pc", {32'd0, RST_PC}, {32'd0, pc});
    rst_n = 1; shadow = RST_PC;
    @(posedge clk);

    // -------- V1 directed -------------------------------------------------------
    repeat (4) step(1,0,0, 32'd0, 32'd0, 0);                          // sequential
    repeat (3) step(0,0,0, 32'd0, 32'd0, 0);                          // stall: hold
    step(1,0,1, 32'd0, 32'h0000_2000, 0);                             // predicted taken
    step(1,1,0, 32'h0000_3000, 32'd0, 0);                             // redirect
    step(0,1,0, 32'h0000_4000, 32'd0, 0);                             // redirect beats stall
    step(1,1,1, 32'h0000_5000, 32'h0000_9000, 0);                     // redirect beats prediction
    step(0,1,1, 32'h0000_6000, 32'h0000_9000, 0);                     // redirect beats both
    step(1,1,0, 32'h0000_7002, 32'd0, 0);                             // unaligned redirect -> masked
    step(1,0,1, 32'd0,         32'h0000_8001, 0);                     // unaligned prediction -> masked
    step(1,1,0, 32'hFFFF_FFFC, 32'd0, 0);                             // top of address space
    repeat (2) step(1,0,0, 32'd0, 32'd0, 0);                          // wraps to 0
    step(1,1,0, 32'h0000_0000, 32'd0, 0);
    // reset in the middle of operation
    rst_n = 0; @(posedge clk); #1;
    chk("reset_midrun", {32'd0, RST_PC}, {32'd0, pc});
    rst_n = 1; shadow = RST_PC; @(posedge clk);

    // -------- V2/V5: 100 randomized ----------------------------------------------
    for (int i = 0; i < 100; i++)
      step($urandom_range(0,1), ($urandom_range(0,3) == 0), ($urandom_range(0,2) == 0),
           $urandom(), $urandom(), 1);

    finish_report();
    $finish;
  end
endmodule
