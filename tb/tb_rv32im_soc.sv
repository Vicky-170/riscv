// =============================================================================
// tb_rv32im_soc.sv - V0..V5 for rv32im_soc.sv (the one integration level with no
// prior testbench: core + I$/D$ + AXI4 + interconnect + AXI-to-APB + boot ROM +
// SRAM + timer + UART + GPIO + interrupt controller, wired together exactly as
// rv32im_soc.sv does it, driven through its real external pins).
//
// Everything below this level (rv32im_core, memory_subsystem, each peripheral)
// already has its own dedicated, independent testbench; this one exists purely
// to catch top-level WIRING mistakes (memory map, peripheral select, interrupt
// source mapping, pin connections) that no lower-level testbench can see, by
// running real firmware and observing real pins.
//
// Firmware: tb/soc_asm/gen_soc_fw.py assembles sim/soc_test.hex (a small,
// hand-designed, disassembly-verified RV32I program - see that script's header
// comment for the phase-by-phase plan). It is NOT randomly generated; this is a
// directed system bring-up test. Checks:
//   V1 (directed): UART TX byte decoded off the real uart_txd pin, GPIO OUT/DIR
//     pins, GPIO IN synchroniser round-trip through SRAM, a real timer interrupt
//     taken via mtvec/mepc/MRET, a real external interrupt taken via the
//     interrupt controller's aggregation of ext_irq into MEIP, and the final
//     "firmware reached the end" marker.
//   V2/V5 (randomized): the same firmware re-run several times with randomized
//     GPIO input patterns and randomized external-interrupt assertion timing,
//     scoreboarded against the same expected markers.
//   V3: protocol/system assertions (no request during a taken interrupt, a
//     taken external interrupt implies the aggregator was actually pending).
// =============================================================================
module tb_rv32im_soc;
  `include "tb_common.svh"

  logic        clk = 0, rst_n = 0;
  logic        uart_rxd = 1'b1, uart_txd;
  logic [31:0] gpio_i = 32'd0, gpio_o, gpio_oe;
  logic [5:0]  ext_irq = 6'd0;

  localparam logic [15:0] FW_BAUD_DIV = 16'd4;     // must match tb/soc_asm/gen_soc_fw.py

  always #5 clk = ~clk;
  always @(posedge clk) cyc++;

  rv32im_soc #(
    .RESET_PC(32'h0000_0000), .ENABLE_BHT(1'b1), .ENABLE_BTB(1'b1),
    .MUL_IMPL(0), .ICACHE_ENABLE(1'b1), .DCACHE_ENABLE(1'b1),
    .ROM_WORDS(512), .SRAM_WORDS(64), .ROM_INIT_FILE("soc_test.hex")
  ) dut (
    .clk(clk), .rst_n(rst_n),
    .uart_rxd(uart_rxd), .uart_txd(uart_txd),
    .gpio_i(gpio_i), .gpio_o(gpio_o), .gpio_oe(gpio_oe),
    .ext_irq(ext_irq)
  );

  // ---- SRAM marker word indices (byte offset / 4), matching gen_soc_fw.py ------------------
  localparam int M_GPIOIN = 0, M_TIMER = 1, M_EXT = 2, M_DONE = 7;
  function automatic logic [31:0] marker(input int idx); return dut.u_mem.u_sram.mem[idx]; endfunction

  // ---- V3: system-level assertions -----------------------------------------------------------
  ap_no_dmem_on_irq: assert property (@(posedge clk) disable iff (!rst_n) dut.u_core.irq_take |-> !dut.u_core.dmem_req);
  ap_meip_needs_pending: assert property (@(posedge clk) disable iff (!rst_n)
                            dut.irq_meip |-> (|(dut.u_intc.irq_src & dut.u_intc.enable_q)));
  ap_ext_irq_reaches_intc: assert property (@(posedge clk) disable iff (!rst_n)
                            (ext_irq != 0) |-> (dut.u_intc.irq_src[7:2] == ext_irq));

  // ---- bit-level UART TX monitor (same technique as tb_uart.sv, independent of the RTL) ------
  mailbox #(logic [8:0]) tx_mbox = new();   // {frame_ok, data[7:0]}
  task automatic tx_monitor();
    forever begin
      logic [7:0] b; bit framing_ok;
      @(negedge uart_txd);
      repeat (FW_BAUD_DIV + 1) @(posedge clk);
      repeat (FW_BAUD_DIV / 2) @(posedge clk);
      for (int i = 0; i < 8; i++) begin
        b[i] = uart_txd;
        repeat (FW_BAUD_DIV + 1) @(posedge clk);
      end
      framing_ok = uart_txd;
      tx_mbox.put({framing_ok, b});
    end
  endtask

  // ---- one full firmware run ------------------------------------------------------------------
  task automatic run_soc(input logic [31:0] gpio_pattern, input int ext_irq_delay, input bit is_rand);
    logic [8:0] tx_got;
    int         g;
    bit         saw_timer, saw_ext;

    // reset
    rst_n = 0; uart_rxd = 1'b1; gpio_i = 32'd0; ext_irq = 6'd0;
    repeat (4) @(negedge clk);
    rst_n = 1;

    gpio_i = gpio_pattern;                            // present before Phase C's read

    // ---- Phase A: UART byte -----------------------------------------------------------------
    g = 0;
    while (tx_mbox.num() == 0 && g < 5000) begin @(posedge clk); g++; end
    if (g >= 5000) begin
      if (is_rand) rchk("uart_tx_TIMEOUT", 64'd1, 64'd0); else chk("uart_tx_TIMEOUT", 64'd1, 64'd0);
    end else begin
      tx_mbox.get(tx_got);
      if (is_rand) begin
        rchk("uart_tx_data", 64'h00A5, {56'd0, tx_got[7:0]});
        rchk("uart_tx_framing", 64'd1, {63'd0, tx_got[8]});
      end else begin
        chk("uart_tx_data", 64'h00A5, {56'd0, tx_got[7:0]});
        chk("uart_tx_framing", 64'd1, {63'd0, tx_got[8]});
      end
      cov_hit(0);
    end

    // ---- Phase B: GPIO OUT/DIR pins ---------------------------------------------------------
    // give the firmware a little time past the UART write to reach the GPIO writes
    repeat (300) @(negedge clk);
    if (is_rand) begin
      rchk("gpio_dir_pins", 64'h0000_00FF, {32'd0, gpio_oe});
      rchk("gpio_out_pins", 64'h0000_005A, {32'd0, gpio_o});
    end else begin
      chk("gpio_dir_pins", 64'h0000_00FF, {32'd0, gpio_oe});
      chk("gpio_out_pins", 64'h0000_005A, {32'd0, gpio_o});
    end
    cov_hit(1);

    // ---- Phase C: GPIO IN round-trip through SRAM -------------------------------------------
    g = 0;
    while (marker(M_GPIOIN) === 32'd0 && marker(M_GPIOIN) !== gpio_pattern && g < 2000) begin
      @(negedge clk); g++;
    end
    if (is_rand) rchk("gpio_in_roundtrip", {32'd0, gpio_pattern}, {32'd0, marker(M_GPIOIN)});
    else         chk("gpio_in_roundtrip", {32'd0, gpio_pattern}, {32'd0, marker(M_GPIOIN)});
    cov_hit(2);

    // ---- Phase D: timer interrupt -------------------------------------------------------------
    g = 0;
    while (marker(M_TIMER) !== 32'h11 && g < 3000) begin @(negedge clk); g++; end
    saw_timer = (marker(M_TIMER) === 32'h11);
    if (is_rand) rchk("timer_irq_handled", 64'd1, {63'd0, saw_timer});
    else         chk("timer_irq_handled", 64'd1, {63'd0, saw_timer});
    if (saw_timer) cov_hit(3);

    // ---- Phase E: external interrupt via INTC --------------------------------------------------
    repeat (ext_irq_delay) @(negedge clk);
    ext_irq[0] = 1'b1;
    g = 0;
    while (marker(M_EXT) !== 32'h22 && g < 3000) begin @(negedge clk); g++; end
    saw_ext = (marker(M_EXT) === 32'h22);
    if (is_rand) rchk("ext_irq_handled", 64'd1, {63'd0, saw_ext});
    else         chk("ext_irq_handled", 64'd1, {63'd0, saw_ext});
    if (saw_ext) cov_hit(4);
    ext_irq[0] = 1'b0;

    // ---- firmware reached the end --------------------------------------------------------------
    g = 0;
    while (marker(M_DONE) !== 32'h1 && g < 500) begin @(negedge clk); g++; end
    if (is_rand) rchk("firmware_done", 64'd1, {63'd0, marker(M_DONE) === 32'h1});
    else         chk("firmware_done", 64'd1, {63'd0, marker(M_DONE) === 32'h1});
    cov_hit(5);
    if (ext_irq_delay > 200) cov_hit(6);
    if (gpio_pattern != 0 && gpio_pattern != 32'hFFFF_FFFF) cov_hit(7);
  endtask

  initial begin
    tb_init("rv32im_soc");
    cov_def(0,"uart_tx_observed"); cov_def(1,"gpio_out_pins_correct"); cov_def(2,"gpio_in_roundtrip");
    cov_def(3,"timer_irq_end_to_end"); cov_def(4,"ext_irq_end_to_end"); cov_def(5,"firmware_completed");
    cov_def(6,"ext_irq_late_assert"); cov_def(7,"gpio_pattern_mixed_bits");
    fork tx_monitor(); join_none

    // -------- V1: one clean directed run ---------------------------------------------------------
    run_soc(32'hA5A5_5A5A, 20, 0);

    // -------- V2/V5: 15 randomized re-runs (pattern + interrupt timing) --------------------------
    for (int i = 0; i < 15; i++)
      run_soc($urandom(), $urandom_range(5, 400), 1);

    finish_report();
    $finish;
  end
endmodule
