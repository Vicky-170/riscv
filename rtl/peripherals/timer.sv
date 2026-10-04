// =============================================================================
// timer.sv - machine timer + software-interrupt register (CLINT-lite), APB slave
//
//   offset  reg        access  description
//   0x00    CTRL       RW      [0] EN: counter runs while 1 (reset: 0)
//   0x04    MSIP       RW      [0] software interrupt pending -> irq_sw
//   0x08    MTIME_LO   RW      free-running counter, low word
//   0x0C    MTIME_HI   RW      high word (read hi/lo/hi for a consistent 64-bit value)
//   0x10    MTIMECMP_LO RW     compare, low word  (reset: all ones => no interrupt)
//   0x14    MTIMECMP_HI RW     compare, high word
//   irq_timer = EN && (mtime >= mtimecmp), level, cleared by writing a larger mtimecmp.
// Zero wait states, no error responses (unmapped offsets read 0, writes ignored).
// =============================================================================
module timer import rv32im_pkg::*; (
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
  output logic        irq_timer,
  output logic        irq_sw
);
  logic        en, msip;
  logic [63:0] mtime, mtimecmp;

  wire       wr  = psel & penable & pwrite;
  wire [3:0] off = paddr[5:2];

  assign pready  = 1'b1;
  assign pslverr = 1'b0;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      en <= 1'b0; msip <= 1'b0; mtime <= 64'd0; mtimecmp <= '1;
    end else begin
      if (en) mtime <= mtime + 64'd1;
      if (wr) begin                                   // writes override the increment
        case (off)
          4'h0: if (pstrb[0]) en   <= pwdata[0];
          4'h1: if (pstrb[0]) msip <= pwdata[0];
          4'h2: mtime[31:0]      <= apply_be(mtime[31:0],      pwdata, pstrb);
          4'h3: mtime[63:32]     <= apply_be(mtime[63:32],     pwdata, pstrb);
          4'h4: mtimecmp[31:0]   <= apply_be(mtimecmp[31:0],   pwdata, pstrb);
          4'h5: mtimecmp[63:32]  <= apply_be(mtimecmp[63:32],  pwdata, pstrb);
          default: ;
        endcase
      end
    end
  end

  always_comb begin
    case (off)
      4'h0:    prdata = {31'd0, en};
      4'h1:    prdata = {31'd0, msip};
      4'h2:    prdata = mtime[31:0];
      4'h3:    prdata = mtime[63:32];
      4'h4:    prdata = mtimecmp[31:0];
      4'h5:    prdata = mtimecmp[63:32];
      default: prdata = 32'd0;
    endcase
  end

  assign irq_timer = en & (mtime >= mtimecmp);
  assign irq_sw    = msip;
endmodule
