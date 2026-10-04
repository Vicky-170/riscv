// Minimal isolated repro: exact 8-instruction sequence from rand_alu program #23
//   [0] ADDI x1, x1, 746        x1 = 0+746 = 746
//   [1] SUB  x8, x3, x2         x8 = 0
//   [2] SUB  x4, x3, x5         x4 = 0
//   [3] ADD  x5, x1, x5         x5 = 746+0 = 746   (self-referencing: x5 is dest AND src2)
//   [4] ADDI x5, x5, 1791       x5 = 746+1791 = 2537   <-- immediately consumes [3]'s result
//   [5] SUB  x1, x5, x1         x1 = 2537-746 = 1791
//   [6] ADD  x2, x3, x7         x2 = 0
//   [7] ADDI x3, x3, 268        x3 = 268
module repro23 import rv32im_pkg::*;;
  logic        clk = 0, rst_n = 0;
  logic [31:0] imem_addr, imem_rdata; logic imem_ready, imem_err, imem_inval;
  logic        dmem_req, dmem_we; logic [31:0] dmem_addr, dmem_wdata, dmem_rdata;
  logic [3:0]  dmem_be; logic dmem_ready, dmem_err, dmem_busy;
  logic        irq_msip=0, irq_mtip=0, irq_meip=0, evt_i=0, evt_d=0;

  always #5 clk = ~clk;

  rv32im_core #(.RESET_PC(32'h0), .ENABLE_BHT(1), .ENABLE_BTB(1), .MUL_IMPL(0), .RESET_REGS(1'b1)) dut (
    .clk(clk), .rst_n(rst_n),
    .imem_addr(imem_addr), .imem_rdata(imem_rdata), .imem_ready(imem_ready), .imem_err(imem_err), .imem_inval(imem_inval),
    .dmem_req(dmem_req), .dmem_we(dmem_we), .dmem_addr(dmem_addr), .dmem_wdata(dmem_wdata), .dmem_be(dmem_be),
    .dmem_rdata(dmem_rdata), .dmem_ready(dmem_ready), .dmem_err(dmem_err), .dmem_busy(dmem_busy),
    .irq_msip(irq_msip), .irq_mtip(irq_mtip), .irq_meip(irq_meip),
    .evt_icache_miss(evt_i), .evt_dcache_miss(evt_d)
  );

  logic [31:0] imem [64];
  assign imem_ready = 1'b1;
  assign imem_rdata = imem[imem_addr[27:2] % 64];
  assign imem_err   = 1'b0;
  assign dmem_ready = dmem_req;   // combinational: irrelevant, no mem ops in this program
  assign dmem_err   = 1'b0;
  assign dmem_busy  = 1'b0;
  assign dmem_rdata = 32'd0;

  initial begin
    for (int i = 0; i < 64; i++) imem[i] = 32'h0000_0013;   // NOP fill
    imem[0] = 32'h2ea08093;   // ADDI x1,x1,746
    imem[1] = 32'h40218433;   // SUB  x8,x3,x2
    imem[2] = 32'h40518233;   // SUB  x4,x3,x5
    imem[3] = 32'h005082b3;   // ADD  x5,x1,x5
    imem[4] = 32'h6ff28293;   // ADDI x5,x5,1791
    imem[5] = 32'h401280b3;   // SUB  x1,x5,x1
    imem[6] = 32'h00718133;   // ADD  x2,x3,x7
    imem[7] = 32'h10c18193;   // ADDI x3,x3,268

    repeat (3) @(negedge clk);
    rst_n = 1;

    for (int c = 0; c < 40; c++) begin
      @(negedge clk); #1;
      $display("c=%0d pc_if=%08h idex.pc=%08h idex.rs1=%0d idex.rs2=%0d idex.rs1v=%0d idex.rs2v=%0d fwda=%0d fwdb=%0d ex_a=%0d ex_b=%0d alu_y=%0d ex_result=%0d | exmem.rd=%0d exmem.rw=%0b exmem.alu=%0d | memwb.rd=%0d memwb.rw=%0b memwb.data=%0d | x1=%0d x5=%0d | idex_hold=%0b pc_hold=%0d ifid_hold=%0b mem_stall=%0b ex_busy=%0b load_use=%0b idex_flush=%0b",
        c, imem_addr, dut.idex_q.pc, dut.idex_q.rs1, dut.idex_q.rs2, dut.idex_q.rs1_val, dut.idex_q.rs2_val,
        dut.fwd_a, dut.fwd_b, dut.alu_a, dut.alu_b, dut.alu_y, dut.ex_result,
        dut.exmem_q.rd, dut.exmem_q.ctrl.reg_write, dut.exmem_q.alu_result,
        dut.memwb_q.rd, dut.memwb_q.reg_write, dut.memwb_q.data,
        dut.u_rf.rf[1], dut.u_rf.rf[5],
        dut.idex_hold, dut.pc_hold, dut.ifid_hold, dut.mem_stall, dut.ex_busy, dut.load_use, dut.idex_flush);
      $display("   valid: ifid=%0b idex=%0b exmem=%0b | ifid.pc=%08h ifid.instr=%08h", dut.ifid_q.valid, dut.idex_q.valid, dut.exmem_q.valid, dut.ifid_q.pc, dut.ifid_q.instr);
    end
    $display("FINAL x1=%0d x2=%0d x3=%0d x4=%0d x5=%0d x8=%0d", dut.u_rf.rf[1], dut.u_rf.rf[2], dut.u_rf.rf[3], dut.u_rf.rf[4], dut.u_rf.rf[5], dut.u_rf.rf[8]);
    $finish;
  end
endmodule
