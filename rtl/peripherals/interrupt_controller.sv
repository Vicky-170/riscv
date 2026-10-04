// =============================================================================
// interrupt_controller.sv - external interrupt aggregator (PLIC-lite), APB slave
//
//   offset  reg      access  description
//   0x00    PENDING  R       raw level of the 8 sources (a source clears at the peripheral)
//   0x04    ENABLE   RW      per-source enable (reset 0 = all masked)
//   0x08    CLAIM    R       1 + index of the lowest-numbered enabled pending source, 0 = none
//                            (fixed priority: source 0 highest).  No claim/complete handshake
//                            is needed because sources are level-sensitive.
//   meip = |(PENDING & ENABLE)  -> core mip.MEIP
// Source map used by the SoC: 0 UART, 1 GPIO, 2..7 external pins.
// =============================================================================
module interrupt_controller import rv32im_pkg::*; #(
  parameter int N_SRC = 8
) (
  input  logic             clk,
  input  logic             rst_n,
  input  logic             psel,
  input  logic             penable,
  input  logic             pwrite,
  input  logic [11:0]      paddr,
  input  logic [31:0]      pwdata,
  input  logic [3:0]       pstrb,
  output logic [31:0]      prdata,
  output logic             pready,
  output logic             pslverr,
  input  logic [N_SRC-1:0] irq_src,
  output logic             meip
);
  logic [N_SRC-1:0] enable_q, active;
  logic [31:0]      claim;

  wire       wr  = psel & penable & pwrite;
  wire [1:0] off = paddr[3:2];

  assign pready  = 1'b1;
  assign pslverr = 1'b0;
  assign active  = irq_src & enable_q;
  assign meip    = |active;

  always_comb begin                                     // lowest index wins
    claim = 32'd0;
    for (int i = N_SRC - 1; i >= 0; i--)
      if (active[i]) claim = 32'(i + 1);
  end

  always_ff @(posedge clk) begin
    if (!rst_n)                        enable_q <= '0;
    else if (wr && off == 2'd1) begin
      for (int b = 0; b < N_SRC; b++)
        if (pstrb[b/8]) enable_q[b] <= pwdata[b];
    end
  end

  always_comb begin
    case (off)
      2'd0:    prdata = 32'(irq_src);
      2'd1:    prdata = 32'(enable_q);
      2'd2:    prdata = claim;
      default: prdata = 32'd0;
    endcase
  end
endmodule
