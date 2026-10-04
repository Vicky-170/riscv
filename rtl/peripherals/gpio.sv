// =============================================================================
// gpio.sv - 32-bit GPIO, APB slave
//
//   offset  reg      access  description
//   0x00    OUT      RW      output data (reset 0)
//   0x04    DIR      RW      1 = pin driven as output (gpio_oe), reset 0 = all inputs
//   0x08    IN       R       synchronised pin values (2-FF)
//   0x0C    IRQ_EN   RW      per-pin enable; irq = |(IN & IRQ_EN)  (level, active high)
// =============================================================================
module gpio import rv32im_pkg::*; (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        psel,
  input  logic        penable,
  input  logic        pwrite,
  input  logic [11:0] paddr,
  input  logic [31:0] pwdata,
  input  logic [3:0]  pstrb,
  output logic [31:0] prdata,
  output logic        pready,
  output logic        pslverr,
  input  logic [31:0] gpio_i,
  output logic [31:0] gpio_o,
  output logic [31:0] gpio_oe,
  output logic        irq
);
  logic [31:0] out_q, dir_q, irq_en_q, in_s1, in_s2;
  wire         wr  = psel & penable & pwrite;
  wire [1:0]   off = paddr[3:2];

  assign pready  = 1'b1;
  assign pslverr = 1'b0;
  assign gpio_o  = out_q;
  assign gpio_oe = dir_q;
  assign irq     = |(in_s2 & irq_en_q);

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      out_q <= 32'd0; dir_q <= 32'd0; irq_en_q <= 32'd0; in_s1 <= 32'd0; in_s2 <= 32'd0;
    end else begin
      in_s1 <= gpio_i;
      in_s2 <= in_s1;
      if (wr) begin
        case (off)
          2'd0: out_q    <= apply_be(out_q,    pwdata, pstrb);
          2'd1: dir_q    <= apply_be(dir_q,    pwdata, pstrb);
          2'd3: irq_en_q <= apply_be(irq_en_q, pwdata, pstrb);
          default: ;                                   // IN is read-only
        endcase
      end
    end
  end

  always_comb begin
    case (off)
      2'd0:    prdata = out_q;
      2'd1:    prdata = dir_q;
      2'd2:    prdata = in_s2;
      default: prdata = irq_en_q;
    endcase
  end
endmodule
