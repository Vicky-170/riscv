// =============================================================================
// register_file.sv - 32x32 RV32 integer register file
//   * 2 async read ports, 1 write port; x0 is not stored and reads as zero
//   * write-through bypass: a same-cycle write is visible to the read ports
//     (covers producer-in-WB / consumer-in-ID)
//   * RESET_REGS=0 (default) saves area: registers are not reset in hardware;
//     simulation zero-fills them so no X reaches software.
// =============================================================================
module register_file #(
  parameter bit RESET_REGS = 1'b0
) (
  input  logic        clk,
  input  logic        rst_n,
  input  logic [4:0]  raddr1,
  input  logic [4:0]  raddr2,
  output logic [31:0] rdata1,
  output logic [31:0] rdata2,
  input  logic        we,
  input  logic [4:0]  waddr,
  input  logic [31:0] wdata
);
  logic [31:0] rf [1:31];                       // x0 intentionally absent

  always_ff @(posedge clk) begin
    if (RESET_REGS && !rst_n) begin
      for (int i = 1; i < 32; i++) rf[i] <= 32'd0;
    end else if (we && waddr != 5'd0) begin
      rf[waddr] <= wdata;
    end
  end

  assign rdata1 = (raddr1 == 5'd0) ? 32'd0 : ((we && waddr == raddr1) ? wdata : rf[raddr1]);
  assign rdata2 = (raddr2 == 5'd0) ? 32'd0 : ((we && waddr == raddr2) ? wdata : rf[raddr2]);

`ifndef SYNTHESIS
  initial for (int i = 1; i < 32; i++) rf[i] = 32'd0;   // X-free simulation
  always @(posedge clk) if (rst_n) begin
    assert (!(raddr1 == 5'd0) || rdata1 == 32'd0) else $error("regfile: x0 read1 != 0");
    assert (!(raddr2 == 5'd0) || rdata2 == 32'd0) else $error("regfile: x0 read2 != 0");
  end
`endif
endmodule
