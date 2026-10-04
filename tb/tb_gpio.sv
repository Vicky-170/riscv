// =============================================================================
// tb_gpio.sv - V0..V5 for gpio.sv
//   Reference model: OUT/DIR/IRQ_EN register shadow + a 2-FF synchroniser shadow
//   for gpio_i (mirrors the documented sampling latency exactly), driven from the
//   same input stimulus. Checks register RW, gpio_o/gpio_oe combinational pass-
//   through, input synchronisation latency, IN read-only behaviour, and the level
//   interrupt (|(synced_in & irq_en)).
// =============================================================================
module tb_gpio;
  `include "tb_common.svh"

  logic clk = 0, rst_n = 0;
  logic psel = 0, penable = 0, pwrite = 0; logic [11:0] paddr = 0;
  logic [31:0] pwdata = 0; logic [3:0] pstrb = 0;
  logic [31:0] prdata; logic pready, pslverr;
  logic [31:0] gpio_i = 0, gpio_o, gpio_oe; logic irq;

  always #5 clk = ~clk;
  always @(posedge clk) cyc++;

  gpio dut (.*);

  // ---- reference model --------------------------------------------------------------
  logic [31:0] m_out = 0, m_dir = 0, m_irqen = 0, m_s1 = 0, m_s2 = 0;
  function automatic logic [31:0] model_read(input logic [11:0] a);
    case (a[3:2])
      2'd0: return m_out;
      2'd1: return m_dir;
      2'd2: return m_s2;
      default: return m_irqen;
    endcase
  endfunction
  `include "apb_drv.svh"

  always @(posedge clk) begin
    if (!rst_n) begin m_out <= 0; m_dir <= 0; m_irqen <= 0; m_s1 <= 0; m_s2 <= 0; end
    else begin
      m_s1 <= gpio_i; m_s2 <= m_s1;
      if (psel && penable && pwrite) begin
        case (paddr[3:2])
          2'd0: m_out    <= merge(m_out,    pwdata, pstrb);
          2'd1: m_dir    <= merge(m_dir,    pwdata, pstrb);
          2'd3: m_irqen  <= merge(m_irqen,  pwdata, pstrb);
          default: ;                                    // IN read-only
        endcase
      end
    end
  end

  task automatic wr_field(input logic [11:0] a, input logic [31:0] d, input logic [3:0] s); apb_wr(a, d, s); endtask

  // ---- V3 assertions -----------------------------------------------------------------
  ap_pready:   assert property (@(posedge clk) disable iff (!rst_n) (psel && penable) |-> pready);
  ap_out_pass: assert property (@(posedge clk) disable iff (!rst_n) gpio_o  == m_out);
  ap_oe_pass:  assert property (@(posedge clk) disable iff (!rst_n) gpio_oe == m_dir);
  ap_irq:      assert property (@(posedge clk) disable iff (!rst_n) irq == |(m_s2 & m_irqen));
  ap_sync_delay: assert property (@(posedge clk) disable iff (!rst_n) m_s2 == $past(m_s1));

  initial begin
    logic [31:0] v;
    tb_init("gpio");
    cov_def(0,"out_write"); cov_def(1,"dir_write"); cov_def(2,"irqen_write"); cov_def(3,"in_read_only_attempt");
    cov_def(4,"irq_asserted"); cov_def(5,"irq_deasserted"); cov_def(6,"partial_strobe"); cov_def(7,"all_pins_high");
    cov_def(8,"all_pins_low"); cov_def(9,"sync_latency_observed");
    apb_idle(3); rst_n = 1; apb_idle(3);

    // ---- V1: reset values ----------------------------------------------------------------
    apb_rd(12'h00, v); chk("reset_out", 0, {32'd0, v});
    apb_rd(12'h04, v); chk("reset_dir", 0, {32'd0, v});
    apb_rd(12'h0C, v); chk("reset_irqen", 0, {32'd0, v});
    apb_rd(12'h08, v); chk("reset_in", 0, {32'd0, v});
    chk("reset_irq", 0, {63'd0, irq});

    // ---- V1: OUT / DIR write and pass-through -----------------------------------------------
    wr_field(12'h00, 32'hAAAA_5555, 4'hF); chk("out_passthrough", 64'hAAAA_5555, {32'd0, gpio_o}); cov_hit(0);
    wr_field(12'h04, 32'h0000_FFFF, 4'hF); chk("oe_passthrough", 64'h0000_FFFF, {32'd0, gpio_oe}); cov_hit(1);
    wr_field(12'h00, 32'hFFFF_FFFF, 4'hF); chk("out_all_high", 64'hFFFF_FFFF, {32'd0, gpio_o}); cov_hit(7);
    wr_field(12'h00, 32'h0000_0000, 4'hF); chk("out_all_low", 64'd0, {32'd0, gpio_o}); cov_hit(8);
    // partial strobes
    wr_field(12'h00, 32'h1234_5678, 4'hF);
    wr_field(12'h00, 32'h0000_00FF, 4'b0001); apb_rd(12'h00, v); chk("out_byte0", 64'h1234_56FF, {32'd0, v}); cov_hit(6);
    wr_field(12'h00, 32'hFF00_0000, 4'b1000); apb_rd(12'h00, v); chk("out_byte3", 64'hFF34_56FF, {32'd0, v});
    // ---- V1: IRQ_EN write and interrupt behaviour --------------------------------------------
    wr_field(12'h0C, 32'h0000_0001, 4'hF); cov_hit(2);
    gpio_i = 32'h0000_0000; apb_idle(4); chk("irq_low_input", 0, {63'd0, irq});
    gpio_i = 32'h0000_0001; apb_idle(4); chk("irq_high_input_enabled", 1, {63'd0, irq}); cov_hit(4);
    gpio_i = 32'h0000_0002; apb_idle(4); chk("irq_other_bit_not_enabled", 0, {63'd0, irq});
    wr_field(12'h0C, 32'h0000_0002, 4'hF);
    apb_idle(4); chk("irq_follows_enable_change", 1, {63'd0, irq});
    gpio_i = 32'd0; apb_idle(4); chk("irq_clears_with_input", 0, {63'd0, irq}); cov_hit(5);
    // multiple bits
    wr_field(12'h0C, 32'hFFFF_FFFF, 4'hF);
    gpio_i = 32'h8000_0001; apb_idle(4); chk_t("irq_multi_bit", irq == 1);
    gpio_i = 32'd0; apb_idle(4); wr_field(12'h0C, 32'd0, 4'hF);
    // ---- V1: 2-FF synchroniser latency, observed through IN ---------------------------------------
    gpio_i = 32'hCAFE_0000;
    @(negedge clk);                                     // one posedge: in_s1 updated, in_s2 still old
    chk("in_lags_one_cycle_min", 0, {32'd0, dut.in_s2});
    @(negedge clk);                                      // second posedge: in_s2 now reflects the new input
    chk("in_after_two_cycles_direct", 64'hCAFE_0000, {32'd0, dut.in_s2});
    apb_rd(12'h08, v); chk("in_after_two_cycles", 64'hCAFE_0000, {32'd0, v}); cov_hit(9);
    gpio_i = 32'd0; apb_idle(3);
    // ---- V1: IN is read-only: a write must have no effect ----------------------------------------
    apb_rd(12'h08, v);
    begin logic [31:0] prev_in = v; wr_field(12'h08, 32'hFFFF_FFFF, 4'hF); apb_rd(12'h08, v); chk("in_write_ignored", {32'd0, prev_in}, {32'd0, v}); end
    cov_hit(3);
    // OUT/DIR/IRQ_EN unaffected by IN write attempt
    apb_rd(12'h00, v); chk_t("out_unaffected_by_in_write", v != 32'hFFFF_FFFF);

    // ---- V2/V5: 100 randomized register + input transitions -------------------------------------
    apb_is_rand = 1;
    for (int i = 0; i < 100; i++) begin
      int sel = $urandom_range(0, 3);
      if ($urandom_range(0, 3) == 0) gpio_i = $urandom();
      case (sel)
        0: wr_field(12'h00, $urandom(), 4'($urandom_range(1, 15)));
        1: wr_field(12'h04, $urandom(), 4'($urandom_range(1, 15)));
        2: wr_field(12'h0C, $urandom(), 4'($urandom_range(1, 15)));
        default: apb_rd(12'h08, v);
      endcase
      if ($urandom_range(0, 2) == 0) apb_idle(1);
    end

    finish_report();
    $finish;
  end
endmodule
