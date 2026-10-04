// =============================================================================
// pipeline_regs.sv - IF/ID, ID/EX, EX/MEM, MEM/WB registers
//
// Convention (all four): flush > en.
//   * reset / flush clear ONLY the "control" part (valid, ctrl, exc, reg_write):
//     a bubble is a register with valid=0 and all side-effect controls at 0.
//   * the data payload has no reset/clear (saves area); en=1 loads it, en=0 holds it.
// =============================================================================

module if_id_reg import rv32im_pkg::*; (
  input  logic clk, rst_n, en, flush,
  input  if_id_t d,
  output if_id_t q
);
  always_ff @(posedge clk) begin
    if (!rst_n || flush) begin
      q.valid <= 1'b0;
      q.exc   <= 1'b0;
    end else if (en) begin
      q.valid <= d.valid;
      q.exc   <= d.exc;
    end
    if (en) begin
      q.exc_cause   <= d.exc_cause;
      q.pred_taken  <= d.pred_taken;
      q.pc          <= d.pc;
      q.instr       <= d.instr;
      q.pred_target <= d.pred_target;
    end
  end
endmodule

module id_ex_reg import rv32im_pkg::*; (
  input  logic clk, rst_n, en, flush,
  input  id_ex_t d,
  output id_ex_t q
);
  always_ff @(posedge clk) begin
    if (!rst_n || flush) begin
      q.valid <= 1'b0;
      q.ctrl  <= '0;
      q.exc   <= 1'b0;
    end else if (en) begin
      q.valid <= d.valid;
      q.ctrl  <= d.ctrl;
      q.exc   <= d.exc;
    end
    if (en) begin
      q.exc_cause   <= d.exc_cause;
      q.pred_taken  <= d.pred_taken;
      q.pc          <= d.pc;
      q.rs1_val     <= d.rs1_val;
      q.rs2_val     <= d.rs2_val;
      q.imm         <= d.imm;
      q.tval        <= d.tval;
      q.pred_target <= d.pred_target;
      q.rs1         <= d.rs1;
      q.rs2         <= d.rs2;
      q.rd          <= d.rd;
      q.funct3      <= d.funct3;
    end
  end
endmodule

module ex_mem_reg import rv32im_pkg::*; (
  input  logic clk, rst_n, en, flush,
  input  ex_mem_t d,
  output ex_mem_t q
);
  always_ff @(posedge clk) begin
    if (!rst_n || flush) begin
      q.valid <= 1'b0;
      q.ctrl  <= '0;
      q.exc   <= 1'b0;
    end else if (en) begin
      q.valid <= d.valid;
      q.ctrl  <= d.ctrl;
      q.exc   <= d.exc;
    end
    if (en) begin
      q.exc_cause  <= d.exc_cause;
      q.csr_we     <= d.csr_we;
      q.pc         <= d.pc;
      q.alu_result <= d.alu_result;
      q.store_data <= d.store_data;
      q.tval       <= d.tval;
      q.rd         <= d.rd;
      q.funct3     <= d.funct3;
      q.csr_addr   <= d.csr_addr;
    end
  end
endmodule

module mem_wb_reg import rv32im_pkg::*; (
  input  logic clk, rst_n, en, flush,
  input  mem_wb_t d,
  output mem_wb_t q
);
  always_ff @(posedge clk) begin
    if (!rst_n || flush)  q.reg_write <= 1'b0;
    else if (en)          q.reg_write <= d.reg_write;
    if (en) begin
      q.rd   <= d.rd;
      q.data <= d.data;
    end
  end
endmodule
