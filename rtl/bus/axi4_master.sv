// =============================================================================
// axi4_master.sv - native request -> reduced-AXI4 master (one transaction at a time)
//
// Native side:
//   req_valid/req_ready  : command handshake (accepted only in IDLE)
//   read  : INCR burst of req_len+1 words        -> rsp_valid per R beat (rsp_last on RLAST)
//   write : single beat (AW+W together)          -> one rsp_valid on B (rsp_last=1)
//   rsp_err = RRESP/BRESP != OKAY.  The consumer must always accept rsp_valid
//   (RREADY is tied to "in R state").
// READ_ONLY=1 removes the write path (instruction-side master).
// All AXI outputs come straight from registers/state -> no combinational path
// from the AXI inputs to AXI outputs.
// =============================================================================
module axi4_master import rv32im_pkg::*; #(
  parameter bit READ_ONLY = 1'b0
) (
  input  logic        clk,
  input  logic        rst_n,
  // native command
  input  logic        req_valid,
  output logic        req_ready,
  input  logic        req_write,
  input  logic [31:0] req_addr,
  input  logic [7:0]  req_len,
  input  logic [31:0] req_wdata,
  input  logic [3:0]  req_wstrb,
  // native response
  output logic        rsp_valid,
  output logic [31:0] rsp_data,
  output logic        rsp_last,
  output logic        rsp_err,
  // AXI
  output axi_req_t    m_req,
  input  axi_rsp_t    m_rsp
);
  typedef enum logic [2:0] { M_IDLE, M_AR, M_R, M_W, M_B } m_state_e;
  m_state_e    st;
  logic [31:0] addr_q, wdata_q;
  logic [7:0]  len_q;
  logic [3:0]  wstrb_q;
  logic        aw_done, w_done;

  wire aw_hs = m_req.awvalid & m_rsp.awready;
  wire w_hs  = m_req.wvalid  & m_rsp.wready;

  assign req_ready = (st == M_IDLE);

  always_comb begin
    m_req         = AXI_REQ_IDLE;
    m_req.araddr  = addr_q;   m_req.arlen = len_q;  m_req.arsize = 3'b010;  m_req.arburst = AXI_BURST_INCR;
    m_req.awaddr  = addr_q;   m_req.awlen = 8'd0;   m_req.awsize = 3'b010;  m_req.awburst = AXI_BURST_INCR;
    m_req.wdata   = wdata_q;  m_req.wstrb = wstrb_q; m_req.wlast = 1'b1;
    m_req.arvalid = (st == M_AR);
    m_req.rready  = (st == M_R);
    m_req.awvalid = (st == M_W) & ~aw_done;
    m_req.wvalid  = (st == M_W) & ~w_done;
    m_req.bready  = (st == M_B);

    rsp_valid = ((st == M_R) & m_rsp.rvalid) | ((st == M_B) & m_rsp.bvalid);
    rsp_data  = m_rsp.rdata;
    rsp_last  = (st == M_B) | m_rsp.rlast;
    rsp_err   = (st == M_B) ? (m_rsp.bresp != AXI_RESP_OKAY) : (m_rsp.rresp != AXI_RESP_OKAY);
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      st <= M_IDLE; aw_done <= 1'b0; w_done <= 1'b0;
    end else begin
      case (st)
        M_IDLE: if (req_valid) begin
          addr_q  <= req_addr;
          len_q   <= req_len;
          wdata_q <= req_wdata;
          wstrb_q <= req_wstrb;
          aw_done <= 1'b0;
          w_done  <= 1'b0;
          st      <= (req_write && !READ_ONLY) ? M_W : M_AR;
        end
        M_AR: if (m_rsp.arready) st <= M_R;
        M_R:  if (m_rsp.rvalid && m_rsp.rlast) st <= M_IDLE;
        M_W: begin                                   // AW and W handshakes complete independently
          if (aw_hs) aw_done <= 1'b1;
          if (w_hs)  w_done  <= 1'b1;
          if ((aw_done | aw_hs) & (w_done | w_hs)) st <= M_B;
        end
        M_B:  if (m_rsp.bvalid) st <= M_IDLE;
        default: st <= M_IDLE;
      endcase
    end
  end

`ifndef SYNTHESIS
  // AXI stability rule: once valid is raised it stays (with stable payload) until ready
  logic        p_arv, p_arr, p_awv, p_awr;
  logic [31:0] p_araddr, p_awaddr;
  always @(posedge clk) begin
    if (rst_n) begin
      if (p_arv && !p_arr) assert (m_req.arvalid && m_req.araddr == p_araddr) else $error("axi_master: AR not stable");
      if (p_awv && !p_awr) assert (m_req.awvalid && m_req.awaddr == p_awaddr) else $error("axi_master: AW not stable");
    end
    p_arv <= m_req.arvalid; p_arr <= m_rsp.arready; p_araddr <= m_req.araddr;
    p_awv <= m_req.awvalid; p_awr <= m_rsp.awready; p_awaddr <= m_req.awaddr;
  end
`endif
endmodule
