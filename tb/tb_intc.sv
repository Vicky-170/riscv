// =============================================================================
// tb_intc.sv - V0..V5 for interrupt_controller.sv
//   Reference model: ENABLE register shadow + combinational PENDING/CLAIM/meip
//   derived independently from the documented map (PENDING=raw sources,
//   ENABLE=RW mask, CLAIM = 1+highest-priority enabled-and-pending source index
//   with source 0 highest priority, meip = |(PENDING & ENABLE)).
// =============================================================================
module tb_intc;
  `include "tb_common.svh"

  localparam int NS = 8;

  logic clk = 0, rst_n = 0;
  logic psel = 0, penable = 0, pwrite = 0; logic [11:0] paddr = 0;
  logic [31:0] pwdata = 0; logic [3:0] pstrb = 0;
  logic [31:0] prdata; logic pready, pslverr;
  logic [NS-1:0] irq_src = 0; logic meip;

  always #5 clk = ~clk;
  always @(posedge clk) cyc++;

  interrupt_controller #(.N_SRC(NS)) dut (.*);

  // ---- reference model -------------------------------------------------------------
  logic [NS-1:0] m_en = 0;
  function automatic logic [31:0] m_claim();
    logic [31:0] c = 0;
    for (int i = NS - 1; i >= 0; i--) if (irq_src[i] & m_en[i]) c = i + 1;
    return c;
  endfunction
  function automatic logic [31:0] model_read(input logic [11:0] a);
    case (a[3:2])
      2'd0: return 32'(irq_src);
      2'd1: return 32'(m_en);
      2'd2: return m_claim();
      default: return 32'd0;
    endcase
  endfunction
  `include "apb_drv.svh"

  always @(posedge clk) begin
    if (!rst_n) m_en <= 0;
    else if (psel && penable && pwrite && paddr[3:2] == 2'd1)
      for (int b = 0; b < NS; b++) if (pstrb[b/8]) m_en[b] <= pwdata[b];
  end

  task automatic wr_field(input logic [11:0] a, input logic [31:0] d, input logic [3:0] s); apb_wr(a, d, s); endtask

  // ---- V3 assertions -------------------------------------------------------------------
  ap_pready: assert property (@(posedge clk) disable iff (!rst_n) (psel && penable) |-> pready);
  ap_meip:   assert property (@(posedge clk) disable iff (!rst_n) meip == |(irq_src & m_en));
  ap_claim_zero_when_idle: assert property (@(posedge clk) disable iff (!rst_n)
                              (irq_src & m_en) == 0 |-> (dut.claim == 0));
  ap_claim_priority0: assert property (@(posedge clk) disable iff (!rst_n)
                              (irq_src[0] & m_en[0]) |-> (dut.claim == 32'd1));

  initial begin
    logic [31:0] v;
    tb_init("intc");
    cov_def(0,"meip_asserted"); cov_def(1,"meip_deasserted"); cov_def(2,"claim_zero_idle");
    cov_def(3,"claim_source0_priority"); cov_def(4,"claim_source7"); cov_def(5,"enable_write");
    cov_def(6,"disabled_source_ignored"); cov_def(7,"partial_strobe_enable"); cov_def(8,"multi_source_pending");
    apb_idle(3); rst_n = 1; apb_idle(2);

    // ---- V1: reset values ---------------------------------------------------------------
    apb_rd(12'h04, v); chk("reset_enable", 0, {32'd0, v});
    apb_rd(12'h08, v); chk("reset_claim", 0, {32'd0, v});
    chk("reset_meip", 0, {63'd0, meip}); cov_hit(2);

    // ---- V1: PENDING mirrors the raw sources regardless of ENABLE -----------------------------
    irq_src = 8'b0000_0001; apb_idle(2); apb_rd(12'h00, v); chk("pending_mirrors_raw", 64'h1, {32'd0, v});
    chk("meip_masked_by_default", 0, {63'd0, meip});
    irq_src = 8'b1010_0101; apb_idle(2); apb_rd(12'h00, v); chk("pending_mirrors_raw2", 64'hA5, {32'd0, v});
    irq_src = 0; apb_idle(2);

    // ---- V1: ENABLE write, meip follows enabled sources only ------------------------------
    wr_field(12'h04, 8'b0000_0001, 4'hF); cov_hit(5);
    irq_src = 8'b0000_0001; apb_idle(2); chk("meip_source0_enabled", 1, {63'd0, meip}); cov_hit(0);
    irq_src = 8'b0000_0010; apb_idle(2); chk("meip_source1_disabled", 0, {63'd0, meip}); cov_hit(6);
    irq_src = 0; apb_idle(2); chk("meip_clears", 0, {63'd0, meip}); cov_hit(1);
    wr_field(12'h04, 8'hFF, 4'hF);
    for (int s = 0; s < NS; s++) begin
      irq_src = 8'(1 << s); apb_idle(2);
      chk($sformatf("meip_source%0d", s), 1, {63'd0, meip});
      apb_rd(12'h08, v); chk($sformatf("claim_source%0d", s), 64'(s + 1), {32'd0, v});
    end
    irq_src = 0; apb_idle(2);
    cov_hit(4);

    // ---- V1: CLAIM priority: source 0 wins over all others -----------------------------------
    irq_src = 8'hFF; apb_idle(2); apb_rd(12'h08, v); chk("claim_priority_source0", 64'd1, {32'd0, v}); cov_hit(3);
    irq_src = 8'b1111_1110; apb_idle(2); apb_rd(12'h08, v); chk("claim_priority_source1", 64'd2, {32'd0, v});
    irq_src = 8'b1000_0000; apb_idle(2); apb_rd(12'h08, v); chk("claim_only_source7", 64'd8, {32'd0, v});
    irq_src = 0; apb_idle(2);
    // masking a high-priority source lets the next one claim
    wr_field(12'h04, 8'b1111_1110, 4'hF);                  // source0 disabled
    irq_src = 8'hFF; apb_idle(2); apb_rd(12'h08, v); chk("claim_skips_disabled_source0", 64'd2, {32'd0, v});
    irq_src = 0; apb_idle(2); wr_field(12'h04, 8'hFF, 4'hF);
    cov_hit(8);

    // ---- V1: partial-strobe ENABLE write --------------------------------------------------------
    wr_field(12'h04, 32'h0000_0000, 4'hF);
    wr_field(12'h04, 32'h0000_0001, 4'b0001); apb_rd(12'h04, v); chk("enable_byte_strobe", 64'h1, {32'd0, v}); cov_hit(7);

    // ---- V2/V5: 60 randomized source/enable combinations ------------------------------------------
    apb_is_rand = 1;
    for (int i = 0; i < 60; i++) begin
      if ($urandom_range(0, 1)) wr_field(12'h04, $urandom(), 4'($urandom_range(1, 15)));
      irq_src = 8'($urandom());
      apb_idle(2);
      apb_rd(12'h00, v); apb_rd(12'h04, v); apb_rd(12'h08, v);
    end

    finish_report();
    $finish;
  end
endmodule
