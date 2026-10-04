// =============================================================================
// boot_rom.sv - read-only boot ROM, AXI slave
//   * INCR burst reads, one word per cycle after the AR handshake
//   * reads beyond WORDS (inside the 0x0xxx_xxxx region) -> SLVERR (data 0)
//   * any write is drained and answered with SLVERR (ROM is not writable)
//   * contents come from INIT_FILE ($readmemh, one 32-bit hex word per line)
// =============================================================================
module boot_rom import rv32im_pkg::*; #(
  parameter int    WORDS     = 1024,                 // 4 KiB default
  parameter string INIT_FILE = "rom_init.hex"
) (
  input  logic     clk,
  input  logic     rst_n,
  input  axi_req_t s_req,
  output axi_rsp_t s_rsp
);
  localparam int AW = $clog2(WORDS);

  logic [31:0] rom [WORDS];
  initial if (INIT_FILE != "") $readmemh(INIT_FILE, rom);

  // ---- read channel FSM -------------------------------------------------------------
  logic        rd_act;
  logic [29:0] wa_q;                                  // word address
  logic [7:0]  cnt_q;                                 // beats remaining - 1
  // RTL FIX #3 (Stage 4): only the in-region offset bits [25:AW] decide range; the region-select
  // bits [29:26] (addr[31:28]) are decoded by the interconnect.  Before, every access at the real
  // base address returned SLVERR.
  wire         in_range = (wa_q[25:AW] == '0);

  always_ff @(posedge clk) begin
    if (!rst_n) rd_act <= 1'b0;
    else if (!rd_act) begin
      if (s_req.arvalid) begin
        rd_act <= 1'b1;
        wa_q   <= s_req.araddr[31:2];
        cnt_q  <= s_req.arlen;
      end
    end else if (s_req.rready) begin
      wa_q <= wa_q + 30'd1;
      if (cnt_q == 8'd0) rd_act <= 1'b0;
      else               cnt_q  <= cnt_q - 8'd1;
    end
  end

  // ---- write channel: reject with SLVERR --------------------------------------------------
  axi_req_t werr_req;
  axi_rsp_t werr_rsp;
  always_comb begin
    werr_req         = s_req;
    werr_req.arvalid = 1'b0;                          // read side handled above
    werr_req.rready  = 1'b0;
  end
  axi_err_slave #(.RESP(AXI_RESP_SLVERR)) u_wr_reject (.clk(clk), .rst_n(rst_n), .req(werr_req), .rsp(werr_rsp));

  // ---- response assembly ----------------------------------------------------------------------
  always_comb begin
    s_rsp         = AXI_RSP_IDLE;
    s_rsp.arready = ~rd_act;
    s_rsp.rvalid  = rd_act;
    s_rsp.rdata   = in_range ? rom[wa_q[AW-1:0]] : 32'd0;
    s_rsp.rresp   = in_range ? AXI_RESP_OKAY : AXI_RESP_SLVERR;
    s_rsp.rlast   = (cnt_q == 8'd0);
    s_rsp.awready = werr_rsp.awready;
    s_rsp.wready  = werr_rsp.wready;
    s_rsp.bvalid  = werr_rsp.bvalid;
    s_rsp.bresp   = werr_rsp.bresp;
  end
endmodule
