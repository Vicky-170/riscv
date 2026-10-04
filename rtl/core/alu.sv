// =============================================================================
// alu.sv - RV32I ALU (area-efficient)
//   * one adder/subtractor shared by ADD/SUB/SLT/SLTU (and address/JALR math)
//   * one right shifter shared by SLL/SRL/SRA (left shift = reverse, shift, reverse)
// =============================================================================
module alu import rv32im_pkg::*; (
  input  logic [31:0] a,
  input  logic [31:0] b,
  input  alu_op_e     op,
  output logic [31:0] y
);
  // ---- shared adder / subtractor -------------------------------------------
  logic        sub, lt, ltu;
  logic [32:0] sum;
  assign sub = (op == ALU_SUB) | (op == ALU_SLT) | (op == ALU_SLTU);
  assign sum = {1'b0, a} + {1'b0, b ^ {32{sub}}} + {32'd0, sub};
  assign ltu = ~sum[32];                              // a<b unsigned <=> no carry out of a-b
  assign lt  = (a[31] ^ b[31]) ? a[31] : sum[31];     // signed compare

  // ---- shared shifter ------------------------------------------------------
  logic [31:0] a_rev, sh_in, sh_r, sh_r_rev, sh_out;
  logic [32:0] sh_full;
  logic        sh_fill;
  always_comb begin
    for (int i = 0; i < 32; i++) begin
      a_rev[i]    = a[31-i];
      sh_r_rev[i] = sh_r[31-i];
    end
  end
  assign sh_in   = (op == ALU_SLL) ? a_rev : a;
  assign sh_fill = (op == ALU_SRA) & a[31];           // arithmetic fill bit
  assign sh_full = $signed({sh_fill, sh_in}) >>> b[4:0];
  assign sh_r    = sh_full[31:0];
  assign sh_out  = (op == ALU_SLL) ? sh_r_rev : sh_r;

  // ---- result mux ----------------------------------------------------------
  always_comb begin
    case (op)
      ALU_ADD, ALU_SUB:            y = sum[31:0];
      ALU_SLT:                     y = {31'd0, lt};
      ALU_SLTU:                    y = {31'd0, ltu};
      ALU_XOR:                     y = a ^ b;
      ALU_OR:                      y = a | b;
      ALU_AND:                     y = a & b;
      ALU_SLL, ALU_SRL, ALU_SRA:   y = sh_out;
      default:                     y = sum[31:0];
    endcase
  end
endmodule
