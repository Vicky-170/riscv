// =============================================================================
// axi4_interconnect.sv - 2 masters (I$, D$) x 3 slaves (ROM, SRAM, PERIPH) + DECERR
//
// Shared-bus style: one master owns the fabric for the whole transaction
// (address decode is registered at grant time), which keeps the design small
// and deadlock-free.  Arbitration: round-robin between M0 (I$) and M1 (D$).
// A master must not raise ARVALID and AWVALID simultaneously (our masters never do).
//
// Address decode (address[31:28]):
//   0x0 -> S0 boot ROM   0x1 -> S1 SRAM   0x4 -> S2 peripherals   else -> DECERR
// Cost: 1 arbitration cycle per transaction.
// =============================================================================

// ------------------------------------------------------------------ error responder
module axi_err_slave import rv32im_pkg::*; #(
  parameter logic [1:0] RESP = AXI_RESP_DECERR
) (
  input  logic     clk,
  input  logic     rst_n,
  input  axi_req_t req,
  output axi_rsp_t rsp
);
  typedef enum logic [1:0] { E_IDLE, E_RD, E_WR, E_B } e_state_t;
  e_state_t   st;
  logic [7:0] cnt;

  always_comb begin
    rsp = AXI_RSP_IDLE;
    case (st)
      E_IDLE: begin
        rsp.arready = req.arvalid;
        rsp.awready = req.awvalid & ~req.arvalid;
      end
      E_RD: begin rsp.rvalid = 1'b1; rsp.rresp = RESP; rsp.rlast = (cnt == 8'd0); end
      E_WR: rsp.wready = 1'b1;                              // swallow every write beat
      E_B:  begin rsp.bvalid = 1'b1; rsp.bresp = RESP; end
      default: ;
    endcase
  end

  always_ff @(posedge clk) begin
    if (!rst_n) st <= E_IDLE;
    else begin
      case (st)
        E_IDLE: if (req.arvalid)      begin cnt <= req.arlen; st <= E_RD; end
                else if (req.awvalid) st <= E_WR;
        E_RD:   if (req.rready) begin
                  if (cnt == 8'd0) st <= E_IDLE; else cnt <= cnt - 8'd1;
                end
        E_WR:   if (req.wvalid && req.wlast) st <= E_B;
        E_B:    if (req.bready) st <= E_IDLE;
        default: st <= E_IDLE;
      endcase
    end
  end
endmodule

// ------------------------------------------------------------------ interconnect
module axi4_interconnect import rv32im_pkg::*; (
  input  logic     clk,
  input  logic     rst_n,
  input  axi_req_t m0_req,  output axi_rsp_t m0_rsp,      // instruction side
  input  axi_req_t m1_req,  output axi_rsp_t m1_rsp,      // data side
  output axi_req_t s0_req,  input  axi_rsp_t s0_rsp,      // boot ROM
  output axi_req_t s1_req,  input  axi_rsp_t s1_rsp,      // SRAM
  output axi_req_t s2_req,  input  axi_rsp_t s2_rsp       // peripheral bridge
);
  // ---- grant state --------------------------------------------------------------
  logic       act, gm, gwr, last_gm;
  logic [1:0] gs;                                          // 0 ROM, 1 SRAM, 2 PERIPH, 3 DECERR

  function automatic logic [1:0] decode(input logic [31:0] a);
    case (a[31:28])
      REGION_ROM:    decode = 2'd0;
      REGION_SRAM:   decode = 2'd1;
      REGION_PERIPH: decode = 2'd2;
      default:       decode = 2'd3;
    endcase
  endfunction

  // ---- arbitration (only used while idle) -----------------------------------------
  logic     m0_want, m1_want, pick_m1;
  axi_req_t pick_req, mreq, e_req;
  axi_rsp_t mrsp, e_rsp;

  assign m0_want  = m0_req.arvalid | m0_req.awvalid;
  assign m1_want  = m1_req.arvalid | m1_req.awvalid;
  assign pick_m1  = m1_want & (~m0_want | ~last_gm);       // round-robin when both want
  assign pick_req = pick_m1 ? m1_req : m0_req;

  assign mreq = gm ? m1_req : m0_req;                      // granted master's request

  logic done;
  assign done = gwr ? (mrsp.bvalid & mreq.bready)
                    : (mrsp.rvalid & mreq.rready & mrsp.rlast);

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      act <= 1'b0; gm <= 1'b0; gwr <= 1'b0; gs <= 2'd0; last_gm <= 1'b1;
    end else if (!act) begin
      if (m0_want | m1_want) begin
        act     <= 1'b1;
        gm      <= pick_m1;
        last_gm <= pick_m1;
        gwr     <= ~pick_req.arvalid & pick_req.awvalid;                       // reads have priority
        gs      <= decode(pick_req.arvalid ? pick_req.araddr : pick_req.awaddr);
      end
    end else if (done) begin
      act <= 1'b0;
    end
  end

  // ---- request routing --------------------------------------------------------------
  assign s0_req = (act && gs == 2'd0) ? mreq : AXI_REQ_IDLE;
  assign s1_req = (act && gs == 2'd1) ? mreq : AXI_REQ_IDLE;
  assign s2_req = (act && gs == 2'd2) ? mreq : AXI_REQ_IDLE;
  assign e_req  = (act && gs == 2'd3) ? mreq : AXI_REQ_IDLE;

  // ---- response routing ---------------------------------------------------------------
  always_comb begin
    case (gs)
      2'd0:    mrsp = s0_rsp;
      2'd1:    mrsp = s1_rsp;
      2'd2:    mrsp = s2_rsp;
      default: mrsp = e_rsp;
    endcase
  end
  assign m0_rsp = (act && !gm) ? mrsp : AXI_RSP_IDLE;
  assign m1_rsp = (act &&  gm) ? mrsp : AXI_RSP_IDLE;

  axi_err_slave #(.RESP(AXI_RESP_DECERR)) u_decerr (.clk(clk), .rst_n(rst_n), .req(e_req), .rsp(e_rsp));

`ifndef SYNTHESIS
  always @(posedge clk) if (rst_n) begin
    assert (!(m0_req.arvalid && m0_req.awvalid)) else $error("axi_ic: M0 raised AR and AW together");
    assert (!(m1_req.arvalid && m1_req.awvalid)) else $error("axi_ic: M1 raised AR and AW together");
  end
`endif
endmodule
