// =============================================================================
// axi_to_apb.sv - AXI4-Lite-style slave -> APB4 master bridge
//
//   * single-beat only (arlen/awlen must be 0; the D-cache never bursts to MMIO)
//   * a write is accepted when AWVALID and WVALID are both present
//   * peripheral select = address[15:12] (one-hot psel, NUM_PERIPH slots);
//     an unmapped slot returns DECERR without an APB access
//   * APB SETUP -> ACCESS (wait for PREADY) -> AXI response; PSLVERR -> SLVERR
//   * reads have priority over writes
// =============================================================================
module axi_to_apb import rv32im_pkg::*; #(
  parameter int NUM_PERIPH = 4
) (
  input  logic                        clk,
  input  logic                        rst_n,
  input  axi_req_t                    s_req,
  output axi_rsp_t                    s_rsp,
  // APB master
  output logic [NUM_PERIPH-1:0]       psel,
  output logic                        penable,
  output logic                        pwrite,
  output logic [11:0]                 paddr,
  output logic [31:0]                 pwdata,
  output logic [3:0]                  pstrb,
  input  logic [NUM_PERIPH*32-1:0]    prdata,          // flattened per-peripheral read data
  input  logic [NUM_PERIPH-1:0]       pready,
  input  logic [NUM_PERIPH-1:0]       pslverr
);
  typedef enum logic [2:0] { B_IDLE, B_SETUP, B_ACCESS, B_RESP_R, B_RESP_W } b_state_e;
  b_state_e    st;
  logic [31:0] addr_q, wdata_q, rdata_q;
  logic [3:0]  strb_q;
  logic        wr_q;
  logic [1:0]  resp_q;

  localparam logic [3:0] NP = 4'(NUM_PERIPH);
  wire [3:0] sel      = addr_q[15:12];
  wire       sel_ok   = (sel < NP);
  wire       take_rd  = (st == B_IDLE) & s_req.arvalid;
  wire       take_wr  = (st == B_IDLE) & ~s_req.arvalid & s_req.awvalid & s_req.wvalid;

  // ---- APB outputs -----------------------------------------------------------------
  always_comb begin
    psel    = '0;
    if (st == B_SETUP || st == B_ACCESS) psel[sel[$clog2(NUM_PERIPH)-1:0]] = sel_ok;
    penable = (st == B_ACCESS);
    pwrite  = wr_q;
    paddr   = addr_q[11:0];
    pwdata  = wdata_q;
    pstrb   = wr_q ? strb_q : 4'b0000;
  end

  // ---- AXI responses --------------------------------------------------------------------
  always_comb begin
    s_rsp         = AXI_RSP_IDLE;
    s_rsp.arready = take_rd;
    s_rsp.awready = take_wr;
    s_rsp.wready  = take_wr;
    s_rsp.rvalid  = (st == B_RESP_R);
    s_rsp.rdata   = rdata_q;
    s_rsp.rresp   = resp_q;
    s_rsp.rlast   = 1'b1;
    s_rsp.bvalid  = (st == B_RESP_W);
    s_rsp.bresp   = resp_q;
  end

  // ---- read-data mux (selected slot) --------------------------------------------------------
  logic [31:0] sel_rdata;
  logic        sel_ready, sel_err;
  always_comb begin
    sel_rdata = 32'd0; sel_ready = 1'b1; sel_err = 1'b0;
    for (int i = 0; i < NUM_PERIPH; i++) begin
      if (sel == i[3:0]) begin
        sel_rdata = prdata[32*i +: 32];
        sel_ready = pready[i];
        sel_err   = pslverr[i];
      end
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) st <= B_IDLE;
    else begin
      case (st)
        B_IDLE: begin
          if (take_rd) begin
            addr_q <= s_req.araddr; wr_q <= 1'b0; st <= B_SETUP;
          end else if (take_wr) begin
            addr_q <= s_req.awaddr; wdata_q <= s_req.wdata; strb_q <= s_req.wstrb;
            wr_q <= 1'b1; st <= B_SETUP;
          end
        end
        B_SETUP: begin
          if (sel_ok) st <= B_ACCESS;
          else begin                                       // unmapped slot: no APB access
            rdata_q <= 32'd0; resp_q <= AXI_RESP_DECERR;
            st <= wr_q ? B_RESP_W : B_RESP_R;
          end
        end
        B_ACCESS: if (sel_ready) begin
          rdata_q <= sel_rdata;
          resp_q  <= sel_err ? AXI_RESP_SLVERR : AXI_RESP_OKAY;
          st      <= wr_q ? B_RESP_W : B_RESP_R;
        end
        B_RESP_R: if (s_req.rready) st <= B_IDLE;
        B_RESP_W: if (s_req.bready) st <= B_IDLE;
        default:  st <= B_IDLE;
      endcase
    end
  end

`ifndef SYNTHESIS
  always @(posedge clk) if (rst_n) begin
    assert (!(take_rd && s_req.arlen != 8'd0)) else $error("axi_to_apb: burst read not supported");
    assert (!(take_wr && !s_req.wlast))        else $error("axi_to_apb: burst write not supported");
    assert ($onehot0(psel))                    else $error("axi_to_apb: psel not one-hot");
  end
`endif
endmodule
