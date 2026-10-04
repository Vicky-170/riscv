// =============================================================================
// pc_unit.sv - fetch program counter
//   priority: redirect > BTB prediction > PC+4.  PC[1:0] is always 0 (no C-ext).
//   The PC only steps when the fetched instruction is accepted (advance) or a
//   redirect arrives; a redirect always wins over a stall.
// =============================================================================
module pc_unit #(
  parameter logic [31:0] RESET_PC = 32'h0000_0000
) (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        advance,          // instruction at pc accepted by IF/ID
  input  logic        redirect_valid,   // trap / mispredict / early-decode redirect
  input  logic [31:0] redirect_pc,
  input  logic        pred_taken,       // BTB+BHT prediction for current pc
  input  logic [31:0] pred_target,
  output logic [31:0] pc,
  output logic [31:0] pc_plus4
);
  logic [31:0] pc_next;

  assign pc_plus4 = pc + 32'd4;

  always_comb begin
    if (redirect_valid)    pc_next = redirect_pc;
    else if (pred_taken)   pc_next = pred_target;
    else                   pc_next = pc_plus4;
    pc_next[1:0] = 2'b00;                       // enforce IALIGN=32
  end

  always_ff @(posedge clk) begin
    if (!rst_n)                        pc <= RESET_PC;
    else if (redirect_valid | advance) pc <= pc_next;
  end
endmodule
