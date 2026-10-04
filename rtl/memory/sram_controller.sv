// =============================================================================
// sram_controller.sv - AXI slave in front of a word-organised byte-writable SRAM
//   * INCR burst read (1 word/cycle) and INCR burst write, byte strobes honoured
//   * accesses beyond WORDS (inside the 0x1xxx_xxxx region) -> SLVERR
//   * the array below is behavioural (flops).  For the physical flow swap the
//     `mem` array for an OpenRAM/SRAM macro (synchronous read => the S_RD state
//     needs one extra wait cycle before rvalid; not implemented here).
// =============================================================================
module sram_controller import rv32im_pkg::*; #(
  parameter int WORDS = 1024                          // 4 KiB default
) (
  input  logic     clk,
  input  logic     rst_n,
  input  axi_req_t s_req,
  output axi_rsp_t s_rsp
);
  localparam int AW = $clog2(WORDS);

  typedef enum logic [1:0] { S_IDLE, S_RD, S_WR, S_B } s_state_e;
  s_state_e    st;
  logic [29:0] wa_q;                                  // word address of current beat
  logic [7:0]  cnt_q;
  logic        bad_q;                                 // a write beat was out of range

  logic [31:0] mem [WORDS];
  // RTL FIX #3 (Stage 4): only the in-region offset bits [25:AW] decide range; the region-select
  // bits [29:26] (addr[31:28]) are decoded by the interconnect.  Before, every access at the real
  // base address returned SLVERR.
  wire         in_range = (wa_q[25:AW] == '0);
  wire         wr_en    = (st == S_WR) & s_req.wvalid & in_range;

`ifndef SYNTHESIS
  initial for (int i = 0; i < WORDS; i++) mem[i] = 32'd0;
`endif

  // ---- byte-enable write -------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (wr_en) begin
      for (int b = 0; b < 4; b++)
        if (s_req.wstrb[b]) mem[wa_q[AW-1:0]][8*b +: 8] <= s_req.wdata[8*b +: 8];
    end
  end

  // ---- channel handshakes ---------------------------------------------------------------
  always_comb begin
    s_rsp = AXI_RSP_IDLE;
    case (st)
      S_IDLE: begin
        s_rsp.arready = s_req.arvalid;
        s_rsp.awready = s_req.awvalid & ~s_req.arvalid;
      end
      S_RD: begin
        s_rsp.rvalid = 1'b1;
        s_rsp.rdata  = in_range ? mem[wa_q[AW-1:0]] : 32'd0;
        s_rsp.rresp  = in_range ? AXI_RESP_OKAY : AXI_RESP_SLVERR;
        s_rsp.rlast  = (cnt_q == 8'd0);
      end
      S_WR: s_rsp.wready = 1'b1;
      S_B: begin
        s_rsp.bvalid = 1'b1;
        s_rsp.bresp  = bad_q ? AXI_RESP_SLVERR : AXI_RESP_OKAY;
      end
      default: ;
    endcase
  end

  always_ff @(posedge clk) begin
    if (!rst_n) st <= S_IDLE;
    else begin
      case (st)
        S_IDLE: begin
          if (s_req.arvalid) begin
            wa_q <= s_req.araddr[31:2]; cnt_q <= s_req.arlen; st <= S_RD;
          end else if (s_req.awvalid) begin
            wa_q <= s_req.awaddr[31:2]; bad_q <= 1'b0; st <= S_WR;
          end
        end
        S_RD: if (s_req.rready) begin
          wa_q <= wa_q + 30'd1;
          if (cnt_q == 8'd0) st <= S_IDLE;
          else               cnt_q <= cnt_q - 8'd1;
        end
        S_WR: if (s_req.wvalid) begin
          if (!in_range) bad_q <= 1'b1;
          wa_q <= wa_q + 30'd1;
          if (s_req.wlast) st <= S_B;
        end
        S_B: if (s_req.bready) st <= S_IDLE;
        default: st <= S_IDLE;
      endcase
    end
  end
endmodule
