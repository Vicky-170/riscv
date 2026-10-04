// =============================================================================
// tb_register_file.sv - V0..V5 for register_file.sv
//   Scoreboard: an independent shadow array in the TB.  Checks x0 behaviour,
//   both read ports, and the same-cycle write-through (WB -> ID) bypass.
//   110 randomized register-dependency cases.
// =============================================================================
module tb_register_file;
  `include "tb_common.svh"

  logic        clk = 0, rst_n = 0, we;
  logic [4:0]  raddr1, raddr2, waddr;
  logic [31:0] rdata1, rdata2, wdata;

  always #5 clk = ~clk;
  always @(posedge clk) cyc++;

  register_file #(.RESET_REGS(1'b1)) dut (
    .clk(clk), .rst_n(rst_n), .raddr1(raddr1), .raddr2(raddr2),
    .rdata1(rdata1), .rdata2(rdata2), .we(we), .waddr(waddr), .wdata(wdata)
  );

  logic [31:0] shadow [32];                          // independent reference state

  // ---- assertions (V3) ---------------------------------------------------------
  ap_x0_read1: assert property (@(posedge clk) disable iff (!rst_n)
                                (raddr1 == 5'd0) |-> (rdata1 == 32'd0));
  ap_x0_read2: assert property (@(posedge clk) disable iff (!rst_n)
                                (raddr2 == 5'd0) |-> (rdata2 == 32'd0));

  // read and compare both ports against the shadow, honouring the write bypass
  task automatic rd_chk(input logic [4:0] r1, r2, input bit is_rand);
    logic [31:0] e1, e2;
    raddr1 = r1; raddr2 = r2;
    #1;
    e1 = (r1 == 0) ? 32'd0 : ((we && waddr == r1 && waddr != 0) ? wdata : shadow[r1]);
    e2 = (r2 == 0) ? 32'd0 : ((we && waddr == r2 && waddr != 0) ? wdata : shadow[r2]);
    if (is_rand) begin
      rchk($sformatf("rd_x%0d", r1), {32'd0, e1}, {32'd0, rdata1});
      rchk($sformatf("rd_x%0d", r2), {32'd0, e2}, {32'd0, rdata2});
    end else begin
      chk($sformatf("port1 x%0d", r1), {32'd0, e1}, {32'd0, rdata1});
      chk($sformatf("port2 x%0d", r2), {32'd0, e2}, {32'd0, rdata2});
    end
    if (r1 == 0 || r2 == 0) cov_hit(0);
    if (we && (waddr == r1 || waddr == r2) && waddr != 0) cov_hit(1);   // bypass exercised
    if (r1 == r2) cov_hit(2);
  endtask

  task automatic wr(input logic [4:0] rd, input logic [31:0] d);
    @(negedge clk);                                  // drive away from the active edge
    we = 1'b1; waddr = rd; wdata = d;
    if (rd != 0) shadow[rd] = d; else cov_hit(3);    // x0 write must be dropped
    cov_hit(4);
  endtask

  task automatic nowr(); @(negedge clk); we = 1'b0; waddr = 5'd0; wdata = 32'd0; cov_hit(5); endtask

  initial begin
    tb_init("register_file");
    cov_def(0,"read_x0"); cov_def(1,"write_through_bypass"); cov_def(2,"same_reg_both_ports");
    cov_def(3,"write_to_x0"); cov_def(4,"write_enabled"); cov_def(5,"write_disabled");
    for (int i = 0; i < 32; i++) shadow[i] = 32'd0;

    nowr(); raddr1 = 0; raddr2 = 0;
    repeat (2) @(posedge clk);
    rst_n = 1;
    @(posedge clk);

    // -------- V1 directed --------------------------------------------------------
    // after reset every register reads zero
    for (int r = 0; r < 32; r++) begin nowr(); rd_chk(5'(r), 5'(31-r), 0); @(posedge clk); end

    // write each register with a unique pattern, then read it all back
    for (int r = 1; r < 32; r++) begin wr(5'(r), 32'hA5A5_0000 + 32'(r)); @(posedge clk); end
    nowr();
    for (int r = 0; r < 32; r++) begin rd_chk(5'(r), 5'(r), 0); @(posedge clk); end

    // x0 must stay zero even when written
    wr(5'd0, 32'hFFFF_FFFF); rd_chk(5'd0, 5'd1, 0); @(posedge clk);
    nowr(); rd_chk(5'd0, 5'd0, 0); @(posedge clk);
    chk("x0_after_write", 64'd0, {32'd0, rdata1});

    // write-through bypass: read the same register in the write cycle
    wr(5'd7, 32'hCAFE_0007); rd_chk(5'd7, 5'd7, 0); @(posedge clk);
    nowr(); rd_chk(5'd7, 5'd7, 0); @(posedge clk);   // and after the write lands

    // we=0 must not change state
    @(negedge clk); we = 1'b0; waddr = 5'd7; wdata = 32'hDEAD_DEAD; @(posedge clk);
    nowr(); rd_chk(5'd7, 5'd7, 0); @(posedge clk);

    // back-to-back writes to the same register (last one wins)
    wr(5'd9, 32'h1111_1111); @(posedge clk);
    wr(5'd9, 32'h2222_2222); @(posedge clk);
    nowr(); rd_chk(5'd9, 5'd9, 0); @(posedge clk);

    // -------- V2/V5: 110 randomized dependency cases ------------------------------
    for (int i = 0; i < 110; i++) begin
      logic [4:0] rd = 5'($urandom_range(0, 31));
      if ($urandom_range(0, 3) != 0) wr(rd, $urandom()); else nowr();
      // deliberately read the register being written half the time -> bypass path
      rd_chk(($urandom_range(0,1) ? rd : 5'($urandom_range(0,31))),
             5'($urandom_range(0, 31)), 1);
      @(posedge clk);
    end

    finish_report();
    $finish;
  end
endmodule
