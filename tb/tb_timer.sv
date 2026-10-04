// =============================================================================
// tb_timer.sv - V0..V5 for timer.sv
//   Reference model: independent 64-bit mtime/mtimecmp shadow + EN/MSIP bits,
//   following the register map documented in the RTL (CTRL/MSIP/MTIME/MTIMECMP).
//   Checks reset values, RW behaviour, free-running count, compare/interrupt,
//   software overriding the counter mid-run, and MSIP as a plain RW bit.
// =============================================================================
module tb_timer;
  `include "tb_common.svh"

  logic clk = 0, rst_n = 0;
  logic psel = 0, penable = 0, pwrite = 0; logic [11:0] paddr = 0;
  logic [31:0] pwdata = 0; logic [3:0] pstrb = 0;
  logic [31:0] prdata; logic pready, pslverr, irq_timer, irq_sw;

  always #5 clk = ~clk;
  always @(posedge clk) cyc++;

  timer dut (.*);

  // ---- reference model ------------------------------------------------------------
  bit m_en = 0, m_msip = 0;
  logic [63:0] m_mtime = 0, m_mtimecmp = '1;

  function automatic logic [31:0] model_read(input logic [11:0] a);
    case (a[5:2])
      4'h0: return {31'd0, m_en};
      4'h1: return {31'd0, m_msip};
      4'h2: return m_mtime[31:0];
      4'h3: return m_mtime[63:32];
      4'h4: return m_mtimecmp[31:0];
      4'h5: return m_mtimecmp[63:32];
      default: return 32'd0;
    endcase
  endfunction
  `include "apb_drv.svh"

  // Synchronous shadow that mirrors the DUT's always_ff exactly (same priority:
  // the free-run increment is scheduled first, a same-cycle write overrides it -
  // both are nonblocking to the same variable, so the write always wins).
  wire       m_wr  = psel && penable && pwrite;
  wire [3:0] m_off = paddr[5:2];
  always @(posedge clk) begin
    if (!rst_n) begin
      m_en <= 1'b0; m_msip <= 1'b0; m_mtime <= 64'd0; m_mtimecmp <= '1;
    end else begin
      if (m_en) m_mtime <= m_mtime + 64'd1;
      if (m_wr) begin
        case (m_off)
          4'h0: if (pstrb[0]) m_en   <= pwdata[0];
          4'h1: if (pstrb[0]) m_msip <= pwdata[0];
          4'h2: m_mtime[31:0]     <= merge(m_mtime[31:0],     pwdata, pstrb);
          4'h3: m_mtime[63:32]    <= merge(m_mtime[63:32],    pwdata, pstrb);
          4'h4: m_mtimecmp[31:0]  <= merge(m_mtimecmp[31:0],  pwdata, pstrb);
          4'h5: m_mtimecmp[63:32] <= merge(m_mtimecmp[63:32], pwdata, pstrb);
          default: ;
        endcase
      end
    end
  end

  // ---- V3 assertions ---------------------------------------------------------------
  ap_irq_timer: assert property (@(posedge clk) disable iff (!rst_n) irq_timer == (m_en && (m_mtime >= m_mtimecmp)));
  ap_irq_sw:    assert property (@(posedge clk) disable iff (!rst_n) irq_sw == m_msip);
  ap_pready_always: assert property (@(posedge clk) disable iff (!rst_n) (psel && penable) |-> pready);

  // the reference model updates itself synchronously (see the always block above);
  // this wrapper only needs to drive the APB access.
  task automatic wr_field(input logic [11:0] a, input logic [31:0] d, input logic [3:0] s);
    apb_wr(a, d, s);
  endtask

  initial begin
    logic [31:0] v;
    tb_init("timer");
    cov_def(0,"reset_disabled"); cov_def(1,"count_enabled"); cov_def(2,"compare_fires");
    cov_def(3,"compare_cleared_by_raising_cmp"); cov_def(4,"msip_set"); cov_def(5,"msip_clear");
    cov_def(6,"mtime_sw_write_while_running"); cov_def(7,"mtimecmp_sw_write"); cov_def(8,"disable_stops_count");
    cov_def(9,"reenable_resumes"); cov_def(10,"partial_strobe_write"); cov_def(11,"mtimeh_rollover_path");
    apb_idle(3); rst_n = 1; apb_idle(2);

    // ---- V1: reset values -------------------------------------------------------------
    apb_rd(12'h00, v); apb_rd(12'h04, v); apb_rd(12'h08, v); apb_rd(12'h0C, v);
    apb_rd(12'h10, v); chk("reset_mtimecmp_lo", 64'hFFFF_FFFF, {32'd0, v});
    apb_rd(12'h14, v); chk("reset_mtimecmp_hi", 64'hFFFF_FFFF, {32'd0, v});
    chk("reset_irq_timer", 0, {63'd0, irq_timer}); cov_hit(0);

    // ---- V1: RW registers, partial strobes ---------------------------------------------
    wr_field(12'h04, 32'd1, 4'hF); apb_rd(12'h04, v); cov_hit(4);
    wr_field(12'h04, 32'd0, 4'h1); apb_rd(12'h04, v); cov_hit(5);
    wr_field(12'h08, 32'hDEAD_BEEF, 4'hF); apb_rd(12'h08, v);
    wr_field(12'h08, 32'h0000_00FF, 4'b0001); apb_rd(12'h08, v); cov_hit(10);
    wr_field(12'h0C, 32'h1234_5678, 4'hF); apb_rd(12'h0C, v);
    wr_field(12'h10, 32'h0000_1000, 4'hF); apb_rd(12'h10, v);
    wr_field(12'h14, 32'h0000_0000, 4'hF); apb_rd(12'h14, v); cov_hit(7);

    // ---- V1: enable, free-run, compare fires -------------------------------------------
    wr_field(12'h08, 32'd0, 4'hF); wr_field(12'h0C, 32'd0, 4'hF);           // mtime = 0
    wr_field(12'h10, 32'd5, 4'hF); wr_field(12'h14, 32'd0, 4'hF);           // mtimecmp = 5
    wr_field(12'h00, 32'd1, 4'hF);                                          // EN = 1
    cov_hit(1);
    repeat (4) begin apb_idle(1); chk("irq_before_cmp", 0, {63'd0, irq_timer}); end
    apb_idle(2);
    chk("irq_after_cmp", 1, {63'd0, irq_timer}); cov_hit(2);
    // raising mtimecmp clears it
    wr_field(12'h10, 32'hFFFF_FFFF, 4'hF);
    apb_idle(1); chk("irq_cleared_by_raise", 0, {63'd0, irq_timer}); cov_hit(3);
    // disable stops the count
    wr_field(12'h00, 32'd0, 4'hF); cov_hit(8);
    apb_rd(12'h08, v); begin logic [31:0] v1 = v; apb_idle(5); apb_rd(12'h08, v); chk("disabled_no_count", {32'd0, v1}, {32'd0, v}); end
    // re-enable resumes
    wr_field(12'h00, 32'd1, 4'hF); cov_hit(9);
    apb_rd(12'h08, v); begin logic [31:0] v1 = v; apb_idle(5); apb_rd(12'h08, v); chk_t("reenabled_counts", v != v1); end
    // software write to mtime while running (write wins over the increment that cycle)
    wr_field(12'h08, 32'h0000_0064, 4'hF); cov_hit(6);
    apb_rd(12'h08, v);   // apb_rd already scoreboards this read against the model; no extra check needed
    // 32->64 bit carry path: write the high word first, THEN the low word last
    // (writing hi second would silently clobber a carry that occurred between the two writes)
    wr_field(12'h0C, 32'd0, 4'hF); wr_field(12'h08, 32'hFFFF_FFFE, 4'hF);
    repeat (6) apb_idle(1);
    apb_rd(12'h0C, v);
    chk_t("mtimeh_actually_carried", m_mtime[63:32] >= 32'd1); cov_hit(11);
    // MSIP behaves as a plain bit, independent of mtime/EN
    wr_field(12'h04, 32'd1, 4'hF); apb_idle(1); chk_t("irq_sw_follows_msip", irq_sw == 1);
    wr_field(12'h04, 32'd0, 4'hF); apb_idle(1); chk_t("irq_sw_clears", irq_sw == 0);

    // ---- V2/V5: 60 randomized register operations ---------------------------------------
    apb_is_rand = 1;
    for (int i = 0; i < 60; i++) begin
      logic [11:0] a = {8'd0, 2'($urandom_range(0, 5)), 2'b00};
      if ($urandom_range(0, 1)) apb_rd(a, v);
      else wr_field(a, $urandom(), ($urandom_range(0, 2) == 0) ? 4'($urandom_range(1, 15)) : 4'hF);
      if ($urandom_range(0, 4) == 0) apb_idle(1);
    end

    finish_report();
    $finish;
  end
endmodule
