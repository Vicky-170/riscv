// =============================================================================
// decoder.sv - RV32IM + Zicsr + FENCE/FENCE.I + MRET decoder (purely combinational)
//   * Every unsupported/invalid encoding sets ctrl.illegal and clears all other
//     side-effect controls.
//   * ECALL/EBREAK are flagged here and turned into exceptions in ID.
//   * WFI is decoded as a NOP.  Compressed (instr[1:0] != 2'b11) is illegal.
// =============================================================================
module decoder import rv32im_pkg::*; (
  input  logic [31:0] instr,
  output ctrl_t       ctrl
);
  logic [6:0] opcode, f7;
  logic [2:0] f3;
  logic [4:0] rd, rs1;

  assign opcode = instr[6:0];
  assign f3     = instr[14:12];
  assign f7     = instr[31:25];
  assign rd     = instr[11:7];
  assign rs1    = instr[19:15];

  always_comb begin
    ctrl = '0;                                   // NOP defaults (alu ADD, A=rs1, B=rs2)

    if (instr[1:0] != 2'b11) begin
      ctrl.illegal = 1'b1;
    end else begin
      case (opcode)
        OP_LUI:   begin ctrl.reg_write = 1'b1; ctrl.op_a_sel = A_ZERO; ctrl.op_b_imm = 1'b1; end
        OP_AUIPC: begin ctrl.reg_write = 1'b1; ctrl.op_a_sel = A_PC;   ctrl.op_b_imm = 1'b1; end
        OP_JAL:   begin ctrl.reg_write = 1'b1; ctrl.is_jal = 1'b1; end

        OP_JALR: begin                            // target = rs1 + imm (ALU adder)
          if (f3 == 3'b000) begin
            ctrl.reg_write = 1'b1; ctrl.is_jalr = 1'b1; ctrl.use_rs1 = 1'b1; ctrl.op_b_imm = 1'b1;
          end else ctrl.illegal = 1'b1;
        end

        OP_BRANCH: begin
          if (f3 != 3'b010 && f3 != 3'b011) begin
            ctrl.is_branch = 1'b1; ctrl.use_rs1 = 1'b1; ctrl.use_rs2 = 1'b1;
          end else ctrl.illegal = 1'b1;
        end

        OP_LOAD: begin                            // LB LH LW LBU LHU
          if (f3 == 3'b000 || f3 == 3'b001 || f3 == 3'b010 || f3 == 3'b100 || f3 == 3'b101) begin
            ctrl.mem_read = 1'b1; ctrl.reg_write = 1'b1; ctrl.wb_sel = WB_LOAD;
            ctrl.use_rs1 = 1'b1;  ctrl.op_b_imm = 1'b1;
          end else ctrl.illegal = 1'b1;
        end

        OP_STORE: begin                           // SB SH SW
          if (f3 == 3'b000 || f3 == 3'b001 || f3 == 3'b010) begin
            ctrl.mem_write = 1'b1; ctrl.use_rs1 = 1'b1; ctrl.use_rs2 = 1'b1; ctrl.op_b_imm = 1'b1;
          end else ctrl.illegal = 1'b1;
        end

        OP_IMM: begin
          ctrl.reg_write = 1'b1; ctrl.use_rs1 = 1'b1; ctrl.op_b_imm = 1'b1;
          case (f3)
            3'b000: ctrl.alu_op = ALU_ADD;
            3'b010: ctrl.alu_op = ALU_SLT;
            3'b011: ctrl.alu_op = ALU_SLTU;
            3'b100: ctrl.alu_op = ALU_XOR;
            3'b110: ctrl.alu_op = ALU_OR;
            3'b111: ctrl.alu_op = ALU_AND;
            3'b001: begin ctrl.alu_op = ALU_SLL; if (f7 != 7'b0000000) ctrl.illegal = 1'b1; end
            3'b101: begin
              ctrl.alu_op = f7[5] ? ALU_SRA : ALU_SRL;
              if (f7 != 7'b0000000 && f7 != 7'b0100000) ctrl.illegal = 1'b1;
            end
            default: ctrl.illegal = 1'b1;
          endcase
        end

        OP_REG: begin
          ctrl.reg_write = 1'b1; ctrl.use_rs1 = 1'b1; ctrl.use_rs2 = 1'b1;
          if (f7 == 7'b0000001) begin
            ctrl.is_md = 1'b1;                    // MUL/MULH/MULHSU/MULHU/DIV/DIVU/REM/REMU
          end else if (f7 == 7'b0000000 || (f7 == 7'b0100000 && (f3 == 3'b000 || f3 == 3'b101))) begin
            case (f3)
              3'b000: ctrl.alu_op = f7[5] ? ALU_SUB : ALU_ADD;
              3'b001: ctrl.alu_op = ALU_SLL;
              3'b010: ctrl.alu_op = ALU_SLT;
              3'b011: ctrl.alu_op = ALU_SLTU;
              3'b100: ctrl.alu_op = ALU_XOR;
              3'b101: ctrl.alu_op = f7[5] ? ALU_SRA : ALU_SRL;
              3'b110: ctrl.alu_op = ALU_OR;
              default: ctrl.alu_op = ALU_AND;
            endcase
          end else ctrl.illegal = 1'b1;
        end

        OP_FENCE: begin                           // FENCE = NOP, FENCE.I = I$ invalidate
          if (f3 == 3'b000)      ; // nop
          else if (f3 == 3'b001) ctrl.is_fencei = 1'b1;
          else                   ctrl.illegal = 1'b1;
        end

        OP_SYSTEM: begin
          if (f3 == 3'b000) begin
            case (instr[31:20])
              12'h000: if (rs1 == 5'd0 && rd == 5'd0) ctrl.is_ecall  = 1'b1; else ctrl.illegal = 1'b1;
              12'h001: if (rs1 == 5'd0 && rd == 5'd0) ctrl.is_ebreak = 1'b1; else ctrl.illegal = 1'b1;
              // MRET/WFI have fixed encodings: rd and rs1 must be zero, otherwise
              // the encoding is reserved -> illegal (RTL FIX #1, Stage 4).
              12'h302: if (rs1 == 5'd0 && rd == 5'd0) ctrl.is_mret = 1'b1; else ctrl.illegal = 1'b1;
              12'h105: if (rs1 != 5'd0 || rd != 5'd0) ctrl.illegal = 1'b1;   // WFI -> NOP
              default: ctrl.illegal = 1'b1;
            endcase
          end else if (f3 != 3'b100) begin        // CSRRW/S/C and immediate forms
            ctrl.csr_en = 1'b1; ctrl.reg_write = 1'b1; ctrl.wb_sel = WB_CSR;
            ctrl.use_rs1 = ~f3[2];                // reg forms read rs1; imm forms use zimm
          end else ctrl.illegal = 1'b1;
        end

        default: ctrl.illegal = 1'b1;
      endcase
    end

    // Illegal instructions must have no side effects.
    if (ctrl.illegal) begin
      ctrl = '0;
      ctrl.illegal = 1'b1;
    end
  end
endmodule
