// =============================================================================
// forwarding_unit.sv - EX operand bypass select
//   0 = ID/EX register value, 1 = EX/MEM result, 2 = MEM/WB result.
//   Youngest producer wins (EX/MEM over MEM/WB); x0 is never forwarded.
//   Loads/CSR reads are "late" producers - the hazard unit guarantees a consumer
//   is never in EX while such a producer sits in EX/MEM.
// =============================================================================
module forwarding_unit (
  input  logic [4:0] ex_rs1,
  input  logic [4:0] ex_rs2,
  input  logic       exmem_reg_write,
  input  logic [4:0] exmem_rd,
  input  logic       memwb_reg_write,
  input  logic [4:0] memwb_rd,
  output logic [1:0] fwd_a,
  output logic [1:0] fwd_b
);
  always_comb begin
    fwd_a = 2'd0;
    fwd_b = 2'd0;
    if (memwb_reg_write && memwb_rd != 5'd0 && memwb_rd == ex_rs1) fwd_a = 2'd2;
    if (memwb_reg_write && memwb_rd != 5'd0 && memwb_rd == ex_rs2) fwd_b = 2'd2;
    if (exmem_reg_write && exmem_rd != 5'd0 && exmem_rd == ex_rs1) fwd_a = 2'd1;
    if (exmem_reg_write && exmem_rd != 5'd0 && exmem_rd == ex_rs2) fwd_b = 2'd1;
  end
endmodule
