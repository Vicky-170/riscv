// =============================================================================
// tb_alu.sv - V0..V5 for alu.sv
//   Reference model (ref_alu) uses plain SV operators, structurally independent
//   of the DUT's shared adder / reversed-shifter implementation.
//   Directed corner cases + 120 randomized cases (biased operand pool).
// =============================================================================
module tb_alu import rv32im_pkg::*;;
  `include "tb_common.svh"

  logic        clk = 0;
  logic [31:0] a, b, y;
  alu_op_e     op;

  always #5 clk = ~clk;
  always @(posedge clk) cyc++;

  alu dut (.a(a), .b(b), .op(op), .y(y));

  // ---- independent reference model -------------------------------------------
  function automatic logic [31:0] ref_alu(input logic [31:0] ra, rb, input alu_op_e rop);
    case (rop)
      ALU_ADD:  return ra + rb;
      ALU_SUB:  return ra - rb;
      ALU_SLL:  return ra << rb[4:0];
      ALU_SLT:  return ($signed(ra) < $signed(rb)) ? 32'd1 : 32'd0;
      ALU_SLTU: return (ra < rb) ? 32'd1 : 32'd0;
      ALU_XOR:  return ra ^ rb;
      ALU_SRL:  return ra >> rb[4:0];
      ALU_SRA:  return $signed(ra) >>> rb[4:0];
      ALU_OR:   return ra | rb;
      ALU_AND:  return ra & rb;
      default:  return 32'hDEAD_BEEF;
    endcase
  endfunction

  // ---- apply one vector ------------------------------------------------------
  task automatic apply(input logic [31:0] va, vb, input alu_op_e vop, input bit is_rand);
    string nm;
    a = va; b = vb; op = vop;
    #1;                                              // settle combinational logic
    cov_hit(int'(vop));                              // bin per ALU op
    if (y == 32'd0)  cov_hit(16);
    if (y[31])       cov_hit(17);
    if (vb[4:0] == 0) cov_hit(18);
    if (vb[4:0] == 31) cov_hit(19);
    nm = $sformatf("op=%0d a=%0h b=%0h", int'(vop), va, vb);
    if (is_rand) rchk($sformatf("op%0d", int'(vop)), {32'd0, ref_alu(va, vb, vop)}, {32'd0, y});
    else         chk(nm, {32'd0, ref_alu(va, vb, vop)}, {32'd0, y});
    @(posedge clk);
  endtask

  // biased operand pool: corners appear far more often than uniform random would give
  function automatic logic [31:0] pick();
    int unsigned s = $urandom_range(0, 9);
    case (s)
      0: return 32'h0000_0000;
      1: return 32'hFFFF_FFFF;
      2: return 32'h8000_0000;                        // INT_MIN
      3: return 32'h7FFF_FFFF;                        // INT_MAX
      4: return 32'd1;
      5: return 32'h0000_001F;
      6: return 32'h0000_0020;
      default: return $urandom();
    endcase
  endfunction

  alu_op_e all_ops [10];

  initial begin
    tb_init("alu");
    all_ops = '{ALU_ADD, ALU_SUB, ALU_SLL, ALU_SLT, ALU_SLTU, ALU_XOR, ALU_SRL, ALU_SRA, ALU_OR, ALU_AND};
    cov_def(0,"ADD"); cov_def(1,"SUB"); cov_def(2,"SLL"); cov_def(3,"SLT"); cov_def(4,"SLTU");
    cov_def(5,"XOR"); cov_def(6,"SRL"); cov_def(7,"SRA"); cov_def(8,"OR"); cov_def(9,"AND");
    cov_def(16,"result_zero"); cov_def(17,"result_negative");
    cov_def(18,"shamt_0"); cov_def(19,"shamt_31");

    // -------- V1: directed corner cases for every op -----------------------------
    begin
      logic [31:0] corners [8];
      corners = '{32'h0000_0000, 32'hFFFF_FFFF, 32'h8000_0000, 32'h7FFF_FFFF,
                  32'h0000_0001, 32'h0000_001F, 32'hDEAD_BEEF, 32'h5A5A_5A5A};
      foreach (all_ops[o])
        foreach (corners[i])
          foreach (corners[j])
            apply(corners[i], corners[j], all_ops[o], 0);
    end
    // shift amounts 0..31 on both shift-right ops and SLL (b[4:0] wrap check)
    for (int s = 0; s < 32; s++) begin
      apply(32'hF0F0_8001, 32'(s),          ALU_SRA, 0);
      apply(32'hF0F0_8001, 32'(s) | 32'h20, ALU_SRL, 0);   // upper bits of b ignored
      apply(32'h0000_0003, 32'(s),          ALU_SLL, 0);
    end
    // signed vs unsigned compare boundary
    apply(32'h8000_0000, 32'h0000_0001, ALU_SLT,  0);      // signed: -2^31 < 1 -> 1
    apply(32'h8000_0000, 32'h0000_0001, ALU_SLTU, 0);      // unsigned: big > 1 -> 0
    apply(32'hFFFF_FFFF, 32'h0000_0000, ALU_SLT,  0);
    apply(32'hFFFF_FFFF, 32'h0000_0000, ALU_SLTU, 0);
    apply(32'h7FFF_FFFF, 32'h0000_0001, ALU_ADD,  0);      // signed overflow wraps
    apply(32'h0000_0000, 32'h0000_0001, ALU_SUB,  0);      // borrow

    // -------- V2/V5: 120 randomized cases against the reference model ------------
    for (int i = 0; i < 120; i++)
      apply(pick(), pick(), all_ops[$urandom_range(0, 9)], 1);

    finish_report();
    $finish;
  end
endmodule
