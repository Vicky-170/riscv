// =============================================================================
// tb_branch_unit.sv - V0..V5 for branch_unit.sv
//   Reference model computes the condition from $signed/unsigned comparisons and
//   the target from the spec (JALR = (rs1+imm) with bit0 cleared, else pc+imm).
//   110 randomized branch/jump cases.
// =============================================================================
module tb_branch_unit;
  `include "tb_common.svh"

  logic        clk = 0;
  logic [2:0]  funct3;
  logic [31:0] rs1, rs2, pc, imm, jalr_sum, target;
  logic        is_branch, is_jal, is_jalr, taken;

  always #5 clk = ~clk;
  always @(posedge clk) cyc++;

  branch_unit dut (.funct3(funct3), .rs1(rs1), .rs2(rs2),
                   .is_branch(is_branch), .is_jal(is_jal), .is_jalr(is_jalr),
                   .pc(pc), .imm(imm), .jalr_sum(jalr_sum),
                   .taken(taken), .target(target));

  function automatic bit ref_cond(input logic [2:0] f3, input logic [31:0] a, b);
    case (f3)
      3'b000: return (a == b);
      3'b001: return (a != b);
      3'b100: return ($signed(a) <  $signed(b));
      3'b101: return ($signed(a) >= $signed(b));
      3'b110: return (a <  b);
      3'b111: return (a >= b);
      default: return 1'b0;                          // 010/011 are not branch encodings
    endcase
  endfunction

  task automatic apply(input logic [2:0] f3, input logic [31:0] a, b, vpc, vimm,
                       input bit br, jal, jalr, input bit is_rand);
    bit          exp_taken;
    logic [31:0] exp_target;
    funct3 = f3; rs1 = a; rs2 = b; pc = vpc; imm = vimm;
    is_branch = br; is_jal = jal; is_jalr = jalr;
    jalr_sum  = a + vimm;                            // as the ALU would produce it
    #1;
    exp_taken  = jal | jalr | (br & ref_cond(f3, a, b));
    exp_target = jalr ? ((a + vimm) & ~32'd1) : (vpc + vimm);
    if (br)   cov_hit({29'd0, f3});                  // bins 0..7 per funct3
    if (jal)  cov_hit(8);
    if (jalr) cov_hit(9);
    if (exp_taken) cov_hit(10); else cov_hit(11);
    if (exp_target[1]) cov_hit(12);                  // misaligned target
    if (is_rand) begin
      rchk("taken",  {63'd0, exp_taken}, {63'd0, taken});
      rchk("target", {32'd0, exp_target}, {32'd0, target});
    end else begin
      chk($sformatf("taken f3=%0d", f3),  {63'd0, exp_taken}, {63'd0, taken});
      chk($sformatf("target f3=%0d", f3), {32'd0, exp_target}, {32'd0, target});
    end
    @(posedge clk);
  endtask

  initial begin
    tb_init("branch_unit");
    cov_def(0,"BEQ"); cov_def(1,"BNE"); cov_def(4,"BLT"); cov_def(5,"BGE");
    cov_def(6,"BLTU"); cov_def(7,"BGEU"); cov_def(8,"JAL"); cov_def(9,"JALR");
    cov_def(10,"taken"); cov_def(11,"not_taken"); cov_def(12,"misaligned_target");

    // -------- V1 directed: every condition, equal / less / greater --------------
    begin
      logic [31:0] pairs [6][2];
      logic [2:0]  f3s [6];
      pairs = '{'{32'd5, 32'd5}, '{32'd5, 32'd7}, '{32'd7, 32'd5},
                '{32'h8000_0000, 32'd1}, '{32'd1, 32'h8000_0000}, '{32'hFFFF_FFFF, 32'd0}};
      f3s   = '{3'b000, 3'b001, 3'b100, 3'b101, 3'b110, 3'b111};
      foreach (f3s[i])
        foreach (pairs[p])
          apply(f3s[i], pairs[p][0], pairs[p][1], 32'h0000_1000, 32'h0000_0010, 1,0,0, 0);
    end
    // no control-flow instruction -> never taken
    apply(3'b000, 32'd5, 32'd5, 32'h1000, 32'h10, 0,0,0, 0);
    // JAL / JALR always taken, JALR clears bit 0
    apply(3'b000, 32'd0,          32'd0, 32'h1000, 32'h0020, 0,1,0, 0);
    apply(3'b000, 32'h0000_2001,  32'd0, 32'h1000, 32'h0003, 0,0,1, 0);   // odd sum
    apply(3'b000, 32'h0000_2000,  32'd0, 32'h1000, 32'h0002, 0,0,1, 0);   // -> bit1 set
    // negative offsets (backward branch)
    apply(3'b000, 32'd1, 32'd1, 32'h0000_1000, 32'hFFFF_FFF0, 1,0,0, 0);
    apply(3'b000, 32'd0, 32'd0, 32'h0000_0000, 32'hFFFF_FFFC, 1,0,0, 0);  // wrap below 0
    // misaligned targets
    apply(3'b000, 32'd0, 32'd0, 32'h1000, 32'h0002, 1,0,0, 0);
    apply(3'b000, 32'h0000_1002, 32'd0, 32'h1000, 32'h0000, 0,0,1, 0);

    // -------- V2/V5: 110 randomized -----------------------------------------------
    for (int i = 0; i < 110; i++) begin
      int unsigned k = $urandom_range(0, 9);
      logic [2:0]  f3 = (k < 2) ? 3'(k) : 3'(4 + (k % 4));
      logic [31:0] a  = ($urandom_range(0,2) == 0) ? 32'h8000_0000 : $urandom();
      logic [31:0] b  = ($urandom_range(0,2) == 0) ? a : $urandom();
      bit jal  = ($urandom_range(0, 9) == 0);
      bit jalr = (!jal) && ($urandom_range(0, 9) == 0);
      apply(f3, a, b, $urandom() & ~32'd3, $urandom(), !jal && !jalr, jal, jalr, 1);
    end

    finish_report();
    $finish;
  end
endmodule
