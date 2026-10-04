// =============================================================================
// memory_subsystem.sv - I-cache + D-cache + AXI masters + interconnect + ROM + SRAM
//
//   core imem --> icache --> axi4_master(RO) --\
//                                               +--> axi4_interconnect --> ROM   (0x0xxx_xxxx)
//   core dmem --> dcache --> axi4_master ------/                       --> SRAM  (0x1xxx_xxxx)
//                                                                      --> per_*  (0x4xxx_xxxx, exported)
//                                                                      --> DECERR (anything else)
// The peripheral AXI port is exported so the SoC top can attach axi_to_apb.
// =============================================================================
module memory_subsystem import rv32im_pkg::*; #(
  parameter bit    ICACHE_ENABLE     = 1'b1,
  parameter bit    DCACHE_ENABLE     = 1'b1,
  parameter int    ICACHE_LINES      = 64,
  parameter int    ICACHE_LINE_BYTES = 16,
  parameter int    DCACHE_LINES      = 64,
  parameter int    DCACHE_LINE_BYTES = 16,
  parameter int    ROM_WORDS         = 1024,
  parameter int    SRAM_WORDS        = 1024,
  parameter string ROM_INIT_FILE     = "rom_init.hex"
) (
  input  logic        clk,
  input  logic        rst_n,
  // core instruction port
  input  logic [31:0] imem_addr,
  output logic [31:0] imem_rdata,
  output logic        imem_ready,
  output logic        imem_err,
  input  logic        imem_inval,
  // core data port
  input  logic        dmem_req,
  input  logic        dmem_we,
  input  logic [31:0] dmem_addr,
  input  logic [31:0] dmem_wdata,
  input  logic [3:0]  dmem_be,
  output logic [31:0] dmem_rdata,
  output logic        dmem_ready,
  output logic        dmem_err,
  output logic        dmem_busy,
  // performance events
  output logic        evt_icache_miss,
  output logic        evt_dcache_miss,
  // peripheral AXI port (to axi_to_apb)
  output axi_req_t    per_req,
  input  axi_rsp_t    per_rsp
);
  // ---- native request/response wires ------------------------------------------------
  logic        i_req_valid, i_req_ready, i_rsp_valid, i_rsp_last, i_rsp_err;
  logic [31:0] i_req_addr, i_rsp_data;
  logic [7:0]  i_req_len;

  logic        d_req_valid, d_req_ready, d_req_write, d_rsp_valid, d_rsp_last, d_rsp_err;
  logic [31:0] d_req_addr, d_req_wdata, d_rsp_data;
  logic [7:0]  d_req_len;
  logic [3:0]  d_req_wstrb;

  // ---- AXI wires -----------------------------------------------------------------------
  axi_req_t m0_req, m1_req, s0_req, s1_req;
  axi_rsp_t m0_rsp, m1_rsp, s0_rsp, s1_rsp;

  // ---- caches -----------------------------------------------------------------------------
  icache #(.ENABLE(ICACHE_ENABLE), .LINES(ICACHE_LINES), .LINE_BYTES(ICACHE_LINE_BYTES)) u_icache (
    .clk(clk), .rst_n(rst_n),
    .cpu_addr(imem_addr), .cpu_rdata(imem_rdata), .cpu_ready(imem_ready), .cpu_err(imem_err),
    .inval(imem_inval),
    .req_valid(i_req_valid), .req_ready(i_req_ready), .req_addr(i_req_addr), .req_len(i_req_len),
    .rsp_valid(i_rsp_valid), .rsp_data(i_rsp_data), .rsp_last(i_rsp_last), .rsp_err(i_rsp_err),
    .miss_evt(evt_icache_miss)
  );

  dcache #(.ENABLE(DCACHE_ENABLE), .LINES(DCACHE_LINES), .LINE_BYTES(DCACHE_LINE_BYTES)) u_dcache (
    .clk(clk), .rst_n(rst_n),
    .cpu_req(dmem_req), .cpu_we(dmem_we), .cpu_addr(dmem_addr), .cpu_wdata(dmem_wdata), .cpu_be(dmem_be),
    .cpu_rdata(dmem_rdata), .cpu_ready(dmem_ready), .cpu_err(dmem_err), .cpu_busy(dmem_busy),
    .req_valid(d_req_valid), .req_ready(d_req_ready), .req_write(d_req_write), .req_addr(d_req_addr),
    .req_len(d_req_len), .req_wdata(d_req_wdata), .req_wstrb(d_req_wstrb),
    .rsp_valid(d_rsp_valid), .rsp_data(d_rsp_data), .rsp_last(d_rsp_last), .rsp_err(d_rsp_err),
    .miss_evt(evt_dcache_miss)
  );

  // ---- AXI masters ---------------------------------------------------------------------------
  axi4_master #(.READ_ONLY(1'b1)) u_i_master (
    .clk(clk), .rst_n(rst_n),
    .req_valid(i_req_valid), .req_ready(i_req_ready), .req_write(1'b0), .req_addr(i_req_addr),
    .req_len(i_req_len), .req_wdata(32'd0), .req_wstrb(4'd0),
    .rsp_valid(i_rsp_valid), .rsp_data(i_rsp_data), .rsp_last(i_rsp_last), .rsp_err(i_rsp_err),
    .m_req(m0_req), .m_rsp(m0_rsp)
  );

  axi4_master #(.READ_ONLY(1'b0)) u_d_master (
    .clk(clk), .rst_n(rst_n),
    .req_valid(d_req_valid), .req_ready(d_req_ready), .req_write(d_req_write), .req_addr(d_req_addr),
    .req_len(d_req_len), .req_wdata(d_req_wdata), .req_wstrb(d_req_wstrb),
    .rsp_valid(d_rsp_valid), .rsp_data(d_rsp_data), .rsp_last(d_rsp_last), .rsp_err(d_rsp_err),
    .m_req(m1_req), .m_rsp(m1_rsp)
  );

  // ---- fabric + slaves -----------------------------------------------------------------------
  axi4_interconnect u_xbar (
    .clk(clk), .rst_n(rst_n),
    .m0_req(m0_req), .m0_rsp(m0_rsp),
    .m1_req(m1_req), .m1_rsp(m1_rsp),
    .s0_req(s0_req), .s0_rsp(s0_rsp),
    .s1_req(s1_req), .s1_rsp(s1_rsp),
    .s2_req(per_req), .s2_rsp(per_rsp)
  );

  boot_rom #(.WORDS(ROM_WORDS), .INIT_FILE(ROM_INIT_FILE)) u_rom (
    .clk(clk), .rst_n(rst_n), .s_req(s0_req), .s_rsp(s0_rsp)
  );

  sram_controller #(.WORDS(SRAM_WORDS)) u_sram (
    .clk(clk), .rst_n(rst_n), .s_req(s1_req), .s_rsp(s1_rsp)
  );
endmodule
