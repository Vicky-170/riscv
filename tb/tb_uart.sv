// =============================================================================
// tb_uart.sv - V0..V5 for uart.sv
//
// Reference model: independent bit-level UART transmitter/receiver processes
// driven by the DUT's own txd/rxd pins (not a copy of the RTL's shift-register
// implementation), plus a register shadow (STATUS/CTRL/BAUD) built from the
// documented map.  This is a true black-box check: the TB decodes what the DUT
// actually puts on the wire and compares it to what the APB side asked for, and
// injects wire-level bytes to check what the DUT receives.
// =============================================================================
module tb_uart;
  `include "tb_common.svh"

  logic clk = 0, rst_n = 0;
  logic psel = 0, penable = 0, pwrite = 0; logic [11:0] paddr = 0;
  logic [31:0] pwdata = 0; logic [3:0] pstrb = 0;
  logic [31:0] prdata; logic pready, pslverr;
  logic rxd = 1, txd, irq;

  localparam logic [15:0] BAUD = 16'd15;               // short divisor for fast simulation

  always #5 clk = ~clk;
  always @(posedge clk) cyc++;

  uart #(.BAUD_DIV_RESET(BAUD)) dut (.*);

  // ---- register shadow (for APB-side checks only) ------------------------------------
  bit m_tx_irq_en = 0, m_rx_irq_en = 0;
  logic [15:0] m_div = BAUD;
  function automatic logic [31:0] model_read(input logic [11:0] a);
    case (a[4:2])
      3'd2: return {28'd0, dut.frame_err, dut.overrun, dut.rx_valid, ~dut.tx_busy};  // STATUS mirrors live DUT flags (r/o-observed)
      3'd3: return {30'd0, m_rx_irq_en, m_tx_irq_en};
      3'd4: return {16'd0, m_div};
      3'd1: return {24'd0, dut.rx_data};                 // mirror the DUT's own captured byte (checked separately below)
      default: return 32'd0;                             // TXDATA is write-only in practice
    endcase
  endfunction
  `include "apb_drv.svh"

  task automatic ctrl_write(input bit txe, rxe);
    apb_wr(12'h0C, {30'd0, rxe, txe}, 4'hF); m_tx_irq_en = txe; m_rx_irq_en = rxe;
  endtask
  task automatic baud_write(input logic [15:0] d);
    apb_wr(12'h10, {16'd0, d}, 4'hF); m_div = d;
  endtask
  task automatic tx_start(input logic [7:0] b);
    apb_wr(12'h00, {24'd0, b}, 4'hF);
  endtask

  // ---- V3 assertions -----------------------------------------------------------------
  ap_pready: assert property (@(posedge clk) disable iff (!rst_n) (psel && penable) |-> pready);
  ap_idle_high: assert property (@(posedge clk) disable iff (!rst_n) (!dut.tx_busy) |-> txd);

  // ---- independent bit-level TX monitor: decode whatever the DUT drives on txd --------------
  mailbox #(logic [8:0]) tx_mbox = new();     // {frame_ok, data[7:0]}
  task automatic tx_monitor();
    forever begin
      logic [7:0] b; bit framing_ok;
      @(negedge txd);                                    // start bit begins
      repeat (m_div + 1) @(posedge clk);                  // sample mid-bit of each subsequent bit
      repeat (m_div / 2) @(posedge clk);
      for (int i = 0; i < 8; i++) begin
        b[i] = txd;
        repeat (m_div + 1) @(posedge clk);
      end
      framing_ok = txd;                                   // stop bit must read 1
      tx_mbox.put({framing_ok, b});
    end
  endtask

  task automatic expect_tx_byte(input logic [7:0] exp, input bit is_rand);
    logic [8:0] got; int g = 0; logic [31:0] st;
    while (tx_mbox.num() == 0 && g < 200000) begin @(posedge clk); g++; end
    if (g >= 200000) begin chk("tx_byte_TIMEOUT", 1, 0); return; end
    tx_mbox.get(got);
    if (is_rand) begin
      rchk("tx_byte_data", {56'd0, exp}, {56'd0, got[7:0]});
      rchk("tx_byte_framing", 1, {63'd0, got[8]});
    end else begin
      chk($sformatf("tx_byte_data exp=%02h", exp), {56'd0, exp}, {56'd0, got[7:0]});
      chk("tx_byte_framing", 1, {63'd0, got[8]});
    end
    cov_hit(0);
    // the monitor samples the stop bit slightly before the real frame ends; make sure the
    // hardware has actually finished (TX_READY) before the caller issues another TXDATA write,
    // or that write would be silently dropped by the DUT (still busy) - not a testbench artifact
    // that should be mistaken for an RTL bug.
    g = 0;
    do begin apb_rd(12'h08, st); if (!st[0]) begin @(posedge clk); g++; end end while (!st[0] && g < 400);
    if (g >= 400) chk("tx_ready_after_frame_TIMEOUT", 1, 0);
  endtask

  // ---- independent bit-level RX driver: bit-bangs rxd, DUT must decode it -------------------
  task automatic rx_send_byte(input logic [7:0] b, input bit bad_stop = 0);
    rxd = 0; repeat (m_div + 1) @(posedge clk);            // start bit
    for (int i = 0; i < 8; i++) begin rxd = b[i]; repeat (m_div + 1) @(posedge clk); end
    rxd = bad_stop ? 1'b0 : 1'b1;                          // stop bit (or a deliberately bad one)
    repeat (m_div + 1) @(posedge clk);
    rxd = 1;                                                // idle
  endtask

  task automatic wait_rx_valid(input int maxw);
    int g = 0; logic [31:0] st;
    while (g < maxw) begin
      apb_rd(12'h08, st);
      if (st[1]) return;
      repeat (m_div) @(posedge clk); g++;
    end
    chk("rx_valid_TIMEOUT", 1, 0);
  endtask

  task automatic check_rx_byte(input logic [7:0] exp, input bit is_rand);
    logic [31:0] st, rd;
    wait_rx_valid(400);
    apb_rd(12'h08, st);
    if (is_rand) rchk("rx_valid_flag", 1, {63'd0, st[1]});
    else         chk("rx_valid_flag", 1, {63'd0, st[1]});
    apb_rd(12'h04, rd);
    if (is_rand) rchk("rx_data", {56'd0, exp}, {56'd0, rd[7:0]});
    else         chk($sformatf("rx_data exp=%02h", exp), {56'd0, exp}, {56'd0, rd[7:0]});
    apb_rd(12'h08, st);
    if (is_rand) rchk("rx_valid_cleared_by_read", 0, {63'd0, st[1]});
    else         chk("rx_valid_cleared_by_read", 0, {63'd0, st[1]});
    cov_hit(1);
  endtask

  task automatic clear_flag(input int bit_idx);             // W1C on STATUS
    apb_wr(12'h08, (32'd1 << bit_idx), 4'hF);
  endtask

  initial begin
    logic [31:0] v;
    tb_init("uart");
    cov_def(0,"tx_byte_observed"); cov_def(1,"rx_byte_received"); cov_def(2,"tx_irq");
    cov_def(3,"rx_irq"); cov_def(4,"overrun_flag"); cov_def(5,"frame_err_flag");
    cov_def(6,"overrun_cleared"); cov_def(7,"frame_err_cleared"); cov_def(8,"baud_change");
    cov_def(9,"tx_ready_while_idle"); cov_def(10,"back_to_back_rx");
    fork tx_monitor(); join_none
    apb_idle(3); rst_n = 1; apb_idle(2);

    // ---- V1: reset values --------------------------------------------------------------
    apb_rd(12'h08, v); chk("reset_tx_ready", 1, {63'd0, v[0]});
    chk("reset_rx_valid", 0, {63'd0, v[1]});
    apb_rd(12'h10, v); chk("reset_baud", {48'd0, BAUD}, {48'd0, v});
    chk("reset_txd_idle", 1, {63'd0, txd}); cov_hit(9);

    // ---- V1: single byte TX, several values -------------------------------------------------
    tx_start(8'h55); expect_tx_byte(8'h55, 0);
    tx_start(8'h00); expect_tx_byte(8'h00, 0);
    tx_start(8'hFF); expect_tx_byte(8'hFF, 0);
    tx_start(8'hA5); expect_tx_byte(8'hA5, 0);
    // TXDATA write while busy must be ignored
    tx_start(8'h81);
    apb_rd(12'h08, v); chk_t("tx_busy_after_start", v[0] == 0);
    tx_start(8'h99);                                          // should be dropped
    expect_tx_byte(8'h81, 0);
    // ---- V1: single byte RX -------------------------------------------------------------------
    rx_send_byte(8'h3C); check_rx_byte(8'h3C, 0);
    rx_send_byte(8'h00); check_rx_byte(8'h00, 0);
    rx_send_byte(8'hFF); check_rx_byte(8'hFF, 0);
    // ---- V1: back-to-back RX -----------------------------------------------------------------------
    rx_send_byte(8'h11); check_rx_byte(8'h11, 0);
    rx_send_byte(8'h22); check_rx_byte(8'h22, 0); cov_hit(10);
    // ---- V1: overrun: second byte arrives before the first is read -----------------------------------
    rx_send_byte(8'hAA); wait_rx_valid(400);
    rx_send_byte(8'hBB);                                       // arrives while RX_VALID still set: dropped, OVERRUN set
    apb_rd(12'h08, v); chk("overrun_set", 1, {63'd0, v[2]}); cov_hit(4);
    apb_rd(12'h04, v); chk("overrun_kept_first_byte", 64'hAA, {32'd0, v});
    clear_flag(2); apb_rd(12'h08, v); chk("overrun_cleared", 0, {63'd0, v[2]}); cov_hit(6);
    apb_rd(12'h08, v);                                          // drain any stale RX_VALID
    if (v[1]) apb_rd(12'h04, v);
    // ---- V1: framing error: bad stop bit --------------------------------------------------------------
    rx_send_byte(8'h5A, 1);                                    // bad stop bit
    apb_idle(4);
    apb_rd(12'h08, v); chk("frame_err_set", 1, {63'd0, v[3]}); cov_hit(5);
    clear_flag(3); apb_rd(12'h08, v); chk("frame_err_cleared", 0, {63'd0, v[3]}); cov_hit(7);
    // ---- V1: interrupts --------------------------------------------------------------------------------------
    ctrl_write(1, 0); apb_idle(2); chk_t("tx_irq_while_idle", irq == 1); cov_hit(2);
    ctrl_write(0, 0); apb_idle(2); chk_t("tx_irq_disabled", irq == 0);
    ctrl_write(0, 1); rx_send_byte(8'h44); wait_rx_valid(400); chk_t("rx_irq_on_valid", irq == 1); cov_hit(3);
    apb_rd(12'h04, v); apb_idle(2); chk_t("rx_irq_clears_on_read", irq == 0);
    ctrl_write(0, 0);
    // ---- V1: baud-rate change takes effect on the next transaction -----------------------------------------
    baud_write(16'd7); cov_hit(8);
    tx_start(8'hC3); expect_tx_byte(8'hC3, 0);
    baud_write(BAUD);

    // ---- V2/V5: 100 randomized TX/RX bytes --------------------------------------------------------
    for (int i = 0; i < 60; i++) begin
      logic [7:0] b = 8'($urandom());
      tx_start(b); expect_tx_byte(b, 1);
    end
    for (int i = 0; i < 40; i++) begin
      logic [7:0] b = 8'($urandom());
      rx_send_byte(b); check_rx_byte(b, 1);
    end

    finish_report();
    $finish;
  end
endmodule
