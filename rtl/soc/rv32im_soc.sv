// =============================================================================
// rv32im_soc.sv - SoC top: core + memory subsystem + APB peripherals
//
//   Memory map            0x0000_0000  boot ROM        0x1000_0000  SRAM
//                         0x4000_0000  timer  (+0x1000 UART, +0x2000 GPIO, +0x3000 INTC)
//   Interrupts to core    MSIP <- timer.msip   MTIP <- timer compare   MEIP <- INTC
//   INTC sources          0 UART, 1 GPIO, 2..7 ext_irq[0..5]
// All top-level parameters select the PPA variants (predictor, mul, caches, sizes).
// =============================================================================
module rv32im_soc import rv32im_pkg::*; #(
  // core
  parameter logic [31:0] RESET_PC          = 32'h0000_0000,
  parameter bit          ENABLE_BHT        = 1'b1,
  parameter bit          ENABLE_BTB        = 1'b1,
  parameter int          BHT_ENTRIES       = 64,
  parameter int          BTB_ENTRIES       = 16,
  parameter int          MUL_IMPL          = 0,
  parameter bit          OPERAND_ISOLATION = 1'b0,
  // caches / memories
  parameter bit          ICACHE_ENABLE     = 1'b1,
  parameter bit          DCACHE_ENABLE     = 1'b1,
  parameter int          ICACHE_LINES      = 64,
  parameter int          ICACHE_LINE_BYTES = 16,
  parameter int          DCACHE_LINES      = 64,
  parameter int          DCACHE_LINE_BYTES = 16,
  parameter int          ROM_WORDS         = 1024,
  parameter int          SRAM_WORDS        = 1024,
  parameter string       ROM_INIT_FILE     = "rom_init.hex",
  // peripherals
  parameter logic [15:0] UART_BAUD_DIV     = 16'd433
) (
  input  logic        clk,
  input  logic        rst_n,
  // UART
  input  logic        uart_rxd,
  output logic        uart_txd,
  // GPIO
  input  logic [31:0] gpio_i,
  output logic [31:0] gpio_o,
  output logic [31:0] gpio_oe,
  // external interrupt sources
  input  logic [5:0]  ext_irq
);
  // ---------------------------------------------------------------- core <-> memory
  logic [31:0] imem_addr, imem_rdata, dmem_addr, dmem_wdata, dmem_rdata;
  logic        imem_ready, imem_err, imem_inval;
  logic        dmem_req, dmem_we, dmem_ready, dmem_err, dmem_busy;
  logic [3:0]  dmem_be;
  logic        evt_imiss, evt_dmiss;
  logic        irq_msip, irq_mtip, irq_meip;

  rv32im_core #(
    .RESET_PC(RESET_PC), .ENABLE_BHT(ENABLE_BHT), .ENABLE_BTB(ENABLE_BTB),
    .BHT_ENTRIES(BHT_ENTRIES), .BTB_ENTRIES(BTB_ENTRIES),
    .MUL_IMPL(MUL_IMPL), .OPERAND_ISOLATION(OPERAND_ISOLATION)
  ) u_core (
    .clk(clk), .rst_n(rst_n),
    .imem_addr(imem_addr), .imem_rdata(imem_rdata), .imem_ready(imem_ready),
    .imem_err(imem_err), .imem_inval(imem_inval),
    .dmem_req(dmem_req), .dmem_we(dmem_we), .dmem_addr(dmem_addr), .dmem_wdata(dmem_wdata),
    .dmem_be(dmem_be), .dmem_rdata(dmem_rdata), .dmem_ready(dmem_ready),
    .dmem_err(dmem_err), .dmem_busy(dmem_busy),
    .irq_msip(irq_msip), .irq_mtip(irq_mtip), .irq_meip(irq_meip),
    .evt_icache_miss(evt_imiss), .evt_dcache_miss(evt_dmiss)
  );

  axi_req_t per_req;
  axi_rsp_t per_rsp;

  memory_subsystem #(
    .ICACHE_ENABLE(ICACHE_ENABLE), .DCACHE_ENABLE(DCACHE_ENABLE),
    .ICACHE_LINES(ICACHE_LINES), .ICACHE_LINE_BYTES(ICACHE_LINE_BYTES),
    .DCACHE_LINES(DCACHE_LINES), .DCACHE_LINE_BYTES(DCACHE_LINE_BYTES),
    .ROM_WORDS(ROM_WORDS), .SRAM_WORDS(SRAM_WORDS), .ROM_INIT_FILE(ROM_INIT_FILE)
  ) u_mem (
    .clk(clk), .rst_n(rst_n),
    .imem_addr(imem_addr), .imem_rdata(imem_rdata), .imem_ready(imem_ready),
    .imem_err(imem_err), .imem_inval(imem_inval),
    .dmem_req(dmem_req), .dmem_we(dmem_we), .dmem_addr(dmem_addr), .dmem_wdata(dmem_wdata),
    .dmem_be(dmem_be), .dmem_rdata(dmem_rdata), .dmem_ready(dmem_ready),
    .dmem_err(dmem_err), .dmem_busy(dmem_busy),
    .evt_icache_miss(evt_imiss), .evt_dcache_miss(evt_dmiss),
    .per_req(per_req), .per_rsp(per_rsp)
  );

  // ---------------------------------------------------------------- AXI -> APB
  logic [3:0]   psel;
  logic         penable, pwrite;
  logic [11:0]  paddr;
  logic [31:0]  pwdata;
  logic [3:0]   pstrb;
  logic [127:0] prdata;                       // {intc, gpio, uart, timer}
  logic [3:0]   pready, pslverr;

  axi_to_apb #(.NUM_PERIPH(4)) u_apb (
    .clk(clk), .rst_n(rst_n), .s_req(per_req), .s_rsp(per_rsp),
    .psel(psel), .penable(penable), .pwrite(pwrite), .paddr(paddr),
    .pwdata(pwdata), .pstrb(pstrb), .prdata(prdata), .pready(pready), .pslverr(pslverr)
  );

  // ---------------------------------------------------------------- peripherals
  logic uart_irq, gpio_irq;

  timer u_timer (
    .clk(clk), .rst_n(rst_n),
    .psel(psel[PERIPH_TIMER]), .penable(penable), .pwrite(pwrite), .paddr(paddr),
    .pwdata(pwdata), .pstrb(pstrb),
    .prdata(prdata[32*PERIPH_TIMER +: 32]), .pready(pready[PERIPH_TIMER]), .pslverr(pslverr[PERIPH_TIMER]),
    .irq_timer(irq_mtip), .irq_sw(irq_msip)
  );

  uart #(.BAUD_DIV_RESET(UART_BAUD_DIV)) u_uart (
    .clk(clk), .rst_n(rst_n),
    .psel(psel[PERIPH_UART]), .penable(penable), .pwrite(pwrite), .paddr(paddr),
    .pwdata(pwdata), .pstrb(pstrb),
    .prdata(prdata[32*PERIPH_UART +: 32]), .pready(pready[PERIPH_UART]), .pslverr(pslverr[PERIPH_UART]),
    .rxd(uart_rxd), .txd(uart_txd), .irq(uart_irq)
  );

  gpio u_gpio (
    .clk(clk), .rst_n(rst_n),
    .psel(psel[PERIPH_GPIO]), .penable(penable), .pwrite(pwrite), .paddr(paddr),
    .pwdata(pwdata), .pstrb(pstrb),
    .prdata(prdata[32*PERIPH_GPIO +: 32]), .pready(pready[PERIPH_GPIO]), .pslverr(pslverr[PERIPH_GPIO]),
    .gpio_i(gpio_i), .gpio_o(gpio_o), .gpio_oe(gpio_oe), .irq(gpio_irq)
  );

  interrupt_controller #(.N_SRC(8)) u_intc (
    .clk(clk), .rst_n(rst_n),
    .psel(psel[PERIPH_INTC]), .penable(penable), .pwrite(pwrite), .paddr(paddr),
    .pwdata(pwdata), .pstrb(pstrb),
    .prdata(prdata[32*PERIPH_INTC +: 32]), .pready(pready[PERIPH_INTC]), .pslverr(pslverr[PERIPH_INTC]),
    .irq_src({ext_irq, gpio_irq, uart_irq}), .meip(irq_meip)
  );
endmodule
