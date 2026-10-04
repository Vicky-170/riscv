// =============================================================================
// immediate_gen.sv - I/S/B/U/J immediate extraction (format chosen from opcode)
//   SYSTEM (CSR) instructions use the I-type path: imm[11:0] = CSR address.
// =============================================================================
module immediate_gen import rv32im_pkg::*; (
  input  logic [31:0] instr,
  output logic [31:0] imm
);
  always_comb begin
    case (instr[6:0])
      OP_STORE:          imm = {{20{instr[31]}}, instr[31:25], instr[11:7]};                          // S
      OP_BRANCH:         imm = {{19{instr[31]}}, instr[31], instr[7], instr[30:25], instr[11:8], 1'b0}; // B
      OP_LUI, OP_AUIPC:  imm = {instr[31:12], 12'd0};                                                 // U
      OP_JAL:            imm = {{11{instr[31]}}, instr[31], instr[19:12], instr[20], instr[30:21], 1'b0}; // J
      default:           imm = {{20{instr[31]}}, instr[31:20]};                                       // I
    endcase
  end
endmodule
