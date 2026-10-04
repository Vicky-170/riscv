// =============================================================================
// tb_forwarding_unit.sv - V0..V5 for forwarding_unit.sv
//   Reference model states the rule directly: forward from the YOUNGEST writer
//   of the register (EX/MEM beats MEM/WB), never from x0, never when the
//   producer does not write.
//   110 randomized register-dependency cases.
// =============================================================================
module tb_forwarding_unit;
  `include "tb_common.svh"

  logic       clk = 0;
  logic [4:0] ex_rs1, ex_rs2, exmem_rd, memwb_rd;
  logic       exmem_reg_write, memwb_reg_write;
  logic [1:0] fwd_a, fwd_b;

  always #5 clk = ~clk;
  always @(posedge clk) cyc++;

  forwarding_unit dut (
    .ex_rs1(ex_rs1), .ex_rs2(ex_rs2),
    .exmem_reg_write(exmem_reg_write), .exmem_rd(exmem_rd),
    .memwb_reg_write(memwb_reg_write), .memwb_rd(memwb_rd),
    .fwd_a(fwd_a), .fwd_b(fwd_b)
  );

  // independent reference: youngest producer wins, x0 never forwarded
  function automatic logic [1:0] ref_fwd(input logic [4:0] rs);
    if (rs == 5'd0)                                         return 2'd0;
    if (exmem_reg_write && exmem_rd == rs)                  return 2'd1;   // EX/MEM (younger)
    if (memwb_reg_write && memwb_rd == rs)                  return 2'd2;   // MEM/WB (older)
    return 2'd0;
  endfunction

  task automatic apply(input logic [4:0] r1, r2, xrd, wrd, input bit xwe, wwe, input bit is_rand);
    logic [1:0] ea, eb;
    ex_rs1 = r1; ex_rs2 = r2; exmem_rd = xrd; memwb_rd = wrd;
    exmem_reg_write = xwe; memwb_reg_write = wwe;
    #1;
    ea = ref_fwd(r1); eb = ref_fwd(r2);
    if (ea == 2'd0) cov_hit(0);
    if (ea == 2'd1) cov_hit(1);
    if (ea == 2'd2) cov_hit(2);
    if (eb == 2'd1) cov_hit(3);
    if (eb == 2'd2) cov_hit(4);
    // both stages write the same register -> priority case
    if (xwe && wwe && xrd == wrd && xrd != 0 && (r1 == xrd || r2 == xrd)) cov_hit(5);
    if (r1 == 5'd0 || r2 == 5'd0) cov_hit(6);
    if (xwe && xrd == 5'd0) cov_hit(7);                     // x0 producer must be ignored
    if (is_rand) begin
      rchk("fwd_a", {62'd0, ea}, {62'd0, fwd_a});
      rchk("fwd_b", {62'd0, eb}, {62'd0, fwd_b});
    end else begin
      chk($sformatf("fwd_a rs1=%0d", r1), {62'd0, ea}, {62'd0, fwd_a});
      chk($sformatf("fwd_b rs2=%0d", r2), {62'd0, eb}, {62'd0, fwd_b});
    end
    @(posedge clk);
  endtask

  initial begin
    tb_init("forwarding_unit");
    cov_def(0,"no_forward"); cov_def(1,"fwdA_from_EXMEM"); cov_def(2,"fwdA_from_MEMWB");
    cov_def(3,"fwdB_from_EXMEM"); cov_def(4,"fwdB_from_MEMWB");
    cov_def(5,"priority_both_write_same_reg"); cov_def(6,"x0_consumer"); cov_def(7,"x0_producer");

    // -------- V1 directed -------------------------------------------------------
    apply(5'd1, 5'd2, 5'd0,  5'd0,  0,0, 0);              // nothing writes
    apply(5'd1, 5'd2, 5'd1,  5'd0,  1,0, 0);              // A from EX/MEM
    apply(5'd1, 5'd2, 5'd2,  5'd0,  1,0, 0);              // B from EX/MEM
    apply(5'd1, 5'd2, 5'd0,  5'd1,  0,1, 0);              // A from MEM/WB
    apply(5'd1, 5'd2, 5'd0,  5'd2,  0,1, 0);              // B from MEM/WB
    apply(5'd3, 5'd3, 5'd3,  5'd3,  1,1, 0);              // both write x3 -> EX/MEM wins
    apply(5'd3, 5'd3, 5'd3,  5'd3,  0,1, 0);              // only MEM/WB valid
    apply(5'd3, 5'd3, 5'd3,  5'd3,  1,0, 0);              // only EX/MEM valid
    apply(5'd0, 5'd0, 5'd0,  5'd0,  1,1, 0);              // x0 producer and consumer
    apply(5'd0, 5'd5, 5'd0,  5'd5,  1,1, 0);              // x0 consumer must not forward
    apply(5'd5, 5'd0, 5'd5,  5'd0,  1,1, 0);
    apply(5'd31,5'd31,5'd31, 5'd31, 1,1, 0);              // highest register index
    apply(5'd7, 5'd8, 5'd7,  5'd8,  1,1, 0);              // A from EX/MEM, B from MEM/WB
    apply(5'd7, 5'd8, 5'd8,  5'd7,  1,1, 0);              // crossed
    apply(5'd7, 5'd8, 5'd9,  5'd10, 1,1, 0);              // writers unrelated
    // exhaustive over a small register window (catches any index decode error)
    for (int r = 0; r < 4; r++)
      for (int x = 0; x < 4; x++)
        for (int w = 0; w < 4; w++)
          for (int m = 0; m < 4; m++)
            apply(5'(r), 5'(x), 5'(w), 5'(m), m[0], m[1], 0);

    // -------- V2/V5: 110 randomized ----------------------------------------------
    for (int i = 0; i < 110; i++) begin
      // bias towards small register numbers so dependencies actually occur
      logic [4:0] rd_pool = 5'($urandom_range(0, 5));
      apply(5'($urandom_range(0,5)), 5'($urandom_range(0,5)),
            rd_pool, 5'($urandom_range(0,5)),
            $urandom_range(0,1), $urandom_range(0,1), 1);
    end

    finish_report();
    $finish;
  end
endmodule
