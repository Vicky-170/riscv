// =============================================================================
// uart.sv - 8N1 UART (single-byte TX/RX buffers), APB slave
//
//   offset  reg      access  description
//   0x00    TXDATA   W       [7:0] write starts transmission if TX is ready (ignored otherwise)
//   0x04    RXDATA   R       [7:0] received byte; the read clears RX_VALID
//   0x08    STATUS   R/W1C   [0] TX_READY  [1] RX_VALID  [2] OVERRUN (W1C)  [3] FRAME_ERR (W1C)
//   0x0C    CTRL     RW      [0] TX_IRQ_EN (irq while TX_READY)  [1] RX_IRQ_EN (irq while RX_VALID)
//   0x10    BAUD     RW      [15:0] divisor; one bit lasts (BAUD+1) clk cycles
//   RX: 2-FF synchroniser, start-bit qualified at mid-bit, samples mid-bit,
//       stop-bit low => FRAME_ERR, byte arriving while RX_VALID => OVERRUN (byte dropped).
// =============================================================================
module uart import rv32im_pkg::*; #(
  parameter logic [15:0] BAUD_DIV_RESET = 16'd433      // 50 MHz / 115200 - 1
) (
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
  input  logic        rxd,
  output logic        txd,
  output logic        irq
);
  assign pready  = 1'b1;
  assign pslverr = 1'b0;

  wire       acc = psel & penable;
  wire       wr  = acc & pwrite;
  wire       rd  = acc & ~pwrite;
  wire [2:0] off = paddr[4:2];

  logic [15:0] div_q;
  logic        tx_irq_en, rx_irq_en;

  // ------------------------------------------------------------------ TX
  logic        tx_busy;
  logic [9:0]  tx_shift;                                 // {stop, data[7:0], start}, LSB first
  logic [3:0]  tx_bit;
  logic [15:0] tx_cnt;
  wire         tx_start = wr && off == 3'd0 && pstrb[0] && !tx_busy;

  assign txd = tx_busy ? tx_shift[0] : 1'b1;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      tx_busy <= 1'b0; tx_shift <= 10'h3FF; tx_bit <= 4'd0; tx_cnt <= 16'd0;
    end else if (tx_start) begin
      tx_shift <= {1'b1, pwdata[7:0], 1'b0};
      tx_busy  <= 1'b1;
      tx_bit   <= 4'd0;
      tx_cnt   <= div_q;
    end else if (tx_busy) begin
      if (tx_cnt == 16'd0) begin                         // bit period elapsed
        tx_cnt   <= div_q;
        tx_shift <= {1'b1, tx_shift[9:1]};
        tx_bit   <= tx_bit + 4'd1;
        if (tx_bit == 4'd9) tx_busy <= 1'b0;             // stop bit finished
      end else tx_cnt <= tx_cnt - 16'd1;
    end
  end

  // ------------------------------------------------------------------ RX
  logic        rx_s1, rx_s2, rx_busy, rx_valid, overrun, frame_err;
  logic [3:0]  rx_bit;
  logic [15:0] rx_cnt;
  logic [7:0]  rx_shift, rx_data;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      rx_s1 <= 1'b1; rx_s2 <= 1'b1; rx_busy <= 1'b0; rx_valid <= 1'b0;
      overrun <= 1'b0; frame_err <= 1'b0; rx_bit <= 4'd0; rx_cnt <= 16'd0;
      rx_shift <= 8'd0; rx_data <= 8'd0;
    end else begin
      rx_s1 <= rxd;
      rx_s2 <= rx_s1;

      // software side effects first, hardware events below take priority
      if (rd && off == 3'd1) rx_valid <= 1'b0;
      if (wr && off == 3'd2 && pstrb[0]) begin
        if (pwdata[2]) overrun   <= 1'b0;
        if (pwdata[3]) frame_err <= 1'b0;
      end

      if (!rx_busy) begin
        if (!rx_s2) begin                                // falling edge: start bit
          rx_busy <= 1'b1;
          rx_cnt  <= {1'b0, div_q[15:1]};                // wait half a bit -> middle of start bit
          rx_bit  <= 4'd0;
        end
      end else if (rx_cnt != 16'd0) begin
        rx_cnt <= rx_cnt - 16'd1;
      end else begin
        rx_cnt <= div_q;
        if (rx_bit == 4'd0) begin                        // middle of start bit
          if (rx_s2) rx_busy <= 1'b0;                    // glitch, abort
          else       rx_bit  <= 4'd1;
        end else if (rx_bit <= 4'd8) begin               // data bits d0..d7
          rx_shift <= {rx_s2, rx_shift[7:1]};
          rx_bit   <= rx_bit + 4'd1;
        end else begin                                   // stop bit
          rx_busy <= 1'b0;
          if (rx_s2) begin
            if (rx_valid && !(rd && off == 3'd1)) overrun <= 1'b1;
            else begin rx_data <= rx_shift; rx_valid <= 1'b1; end
          end else frame_err <= 1'b1;
        end
      end
    end
  end

  // ------------------------------------------------------------------ control regs
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      div_q <= BAUD_DIV_RESET; tx_irq_en <= 1'b0; rx_irq_en <= 1'b0;
    end else if (wr) begin
      case (off)
        3'd3: if (pstrb[0]) begin tx_irq_en <= pwdata[0]; rx_irq_en <= pwdata[1]; end
        3'd4: begin
          if (pstrb[0]) div_q[7:0]  <= pwdata[7:0];
          if (pstrb[1]) div_q[15:8] <= pwdata[15:8];
        end
        default: ;
      endcase
    end
  end

  always_comb begin
    case (off)
      3'd1:    prdata = {24'd0, rx_data};
      3'd2:    prdata = {28'd0, frame_err, overrun, rx_valid, ~tx_busy};
      3'd3:    prdata = {30'd0, rx_irq_en, tx_irq_en};
      3'd4:    prdata = {16'd0, div_q};
      default: prdata = 32'd0;
    endcase
  end

  assign irq = (~tx_busy & tx_irq_en) | (rx_valid & rx_irq_en);
endmodule
