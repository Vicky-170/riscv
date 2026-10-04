// =============================================================================
// branch_unit.sv - EX-stage branch/jump resolution
//   taken  : JAL/JALR always, conditional branches by funct3 compare
//   target : JALR = (rs1+imm)&~1 (supplied by ALU adder), else pc+imm
// =============================================================================
module branch_unit (
  input  logic [2:0]  funct3,
  input  logic [31:0] rs1,
  input  logic [31:0] rs2,
  input  logic        is_branch,
  input  logic        is_jal,
  input  logic        is_jalr,
  input  logic [31:0] pc,
  input  logic [31:0] imm,
  input  logic [31:0] jalr_sum,      // rs1 + imm from the ALU
  output logic        taken,
  output logic [31:0] target
);
  logic eq, lt, ltu, cond;
  assign eq  = (rs1 == rs2);
  assign lt  = ($signed(rs1) < $signed(rs2));
  assign ltu = (rs1 < rs2);

  always_comb begin
    case (funct3)
      3'b000:  cond = eq;      // BEQ
      3'b001:  cond = ~eq;     // BNE
      3'b100:  cond = lt;      // BLT
      3'b101:  cond = ~lt;     // BGE
      3'b110:  cond = ltu;     // BLTU
      3'b111:  cond = ~ltu;    // BGEU
      default: cond = 1'b0;
    endcase
  end

  assign taken  = is_jal | is_jalr | (is_branch & cond);
  assign target = is_jalr ? {jalr_sum[31:1], 1'b0} : (pc + imm);
endmodule
