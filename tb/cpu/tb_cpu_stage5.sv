// =============================================================================
// tb_cpu_stage5.sv - Stage 5 CPU-level / architectural verification
//
// Reuses the proven memory model and golden RV32IM interpreter from Stage 4's
// tb_rv32im_core.sv (same core, same retire-triggered scoreboard technique,
// already fixed for RTL bug #4). This is NOT a module-level scoreboard reused
// blindly: the golden model is an independent instruction-set interpreter with
// its own PC/register/CSR state, structurally decoupled from the DUT's pipeline
// implementation - exactly the CPU-level reference model this stage requires.
//
// What is NEW for Stage 5 (not present in Stage 4):
//   * tb/cpu/gen_cpu_programs.py assembles ONE continuous 22,333-word program:
//       - 1200 randomized architectural sequences (12-20 instrs each, forward-
//         branch-only so the random block is structurally guaranteed to
//         terminate), covering ALU/imm/M-extension/load-store/CSR/branch mixed
//         together with real register and memory dependencies
//       - 9 hand-designed benchmark programs with real (bounded, disassembly-
//         verified) loops: Fibonacci, factorial, GCD, array sum, bubble sort,
//         memcopy, XOR checksum, a branch-heavy classifier, a MUL->DIV->REM chain
//   * The whole 22,333-word program runs in ONE continuous execution (a single
//     reset at t=0, no reset between segments) - this is a stronger, more
//     realistic test than Stage 4's per-program-reset core test, and doubles as
//     a long-running-execution / continuous-retirement stress test.
//   * 1209 checkpoints (one per segment boundary): every time the DUT retires
//     the instruction at a checkpoint PC, all 31 GPRs are compared against the
//     golden model - "periodic architectural checkpoints... to catch the first
//     divergence" per the Stage 5 spec, rather than only a final check.
//   * Variable D-side latency (dlat) is swept across segments (0, 2, 5, 9
//     cycles) to fold AXI/D-cache-stall-style backpressure into the same run
//     (module-level AXI protocol fidelity is already Stage 4's job; here the
//     concern is whether the CPU's architectural state survives varying stall
//     durations, which is what CPU-level verification is actually about).
//   * A dedicated directed scenario appended after the main run re-exercises
//     "interrupt taken while a long D-side stall is in flight" end to end.
// =============================================================================
module tb_cpu_stage5 import rv32im_pkg::*;;
  `include "tb_common.svh"

  logic        clk = 0, rst_n = 0;
  logic [31:0] imem_addr, imem_rdata; logic imem_ready, imem_err, imem_inval;
  logic        dmem_req, dmem_we; logic [31:0] dmem_addr, dmem_wdata, dmem_rdata;
  logic [3:0]  dmem_be; logic dmem_ready, dmem_err, dmem_busy;
  logic        irq_msip = 0, irq_mtip = 0, irq_meip = 0;
  logic        evt_icache_miss, evt_dcache_miss;

  always #5 clk = ~clk;
  always @(posedge clk) cyc++;

  rv32im_core #(.RESET_PC(32'h0000_0000), .ENABLE_BHT(1), .ENABLE_BTB(1), .MUL_IMPL(0),
               .RESET_REGS(1'b1)) dut (.*);

  // ============================================================== memory model (Stage 4 pattern)
  localparam int IMEM_WORDS = 32768, DMEM_WORDS = 2048;
  logic [31:0] imem [IMEM_WORDS];
  logic [31:0] dmem [DMEM_WORDS];
  int unsigned dlat = 0;
  logic [31:0] mmio_reg = 32'hE000_0000;

  wire i_oor = (imem_addr[27:2] >= IMEM_WORDS) || (imem_addr[31:28] != 4'h0);
  assign imem_ready = rst_n;
  assign imem_rdata = i_oor ? 32'd0 : imem[imem_addr[27:2] % IMEM_WORDS];
  assign imem_err    = imem_ready && i_oor;

  typedef enum logic [1:0] { D_IDLE, D_WAIT, D_DONE } d_state_e;
  d_state_e d_st = D_IDLE;
  int d_cnt = 0;
  logic d_is_mmio, d_oor;
  assign d_is_mmio = (dmem_addr[31:28] == 4'h4);
  assign d_oor     = !d_is_mmio && ((dmem_addr[27:2] >= DMEM_WORDS) || (dmem_addr[31:28] != 4'h0));
  assign dmem_busy  = (d_st != D_IDLE);
  assign dmem_ready = (d_st == D_DONE);
  assign dmem_err   = (d_st == D_DONE) && d_oor;
  assign dmem_rdata = d_is_mmio ? mmio_reg : (d_oor ? 32'd0 : dmem[dmem_addr[27:2] % DMEM_WORDS]);
  always @(posedge clk) begin
    if (!rst_n) begin d_st <= D_IDLE; d_cnt <= 0; end
    else begin
      case (d_st)
        D_IDLE: if (dmem_req) begin
          d_cnt <= (d_is_mmio ? 1 : dlat);
          d_st <= ((d_is_mmio ? 1 : dlat) == 0) ? D_DONE : D_WAIT;
        end
        D_WAIT: if (d_cnt == 0) d_st <= D_DONE; else d_cnt <= d_cnt - 1;
        D_DONE: begin
          if (dmem_we && !d_oor && !d_is_mmio)
            for (int b = 0; b < 4; b++) if (dmem_be[b]) dmem[dmem_addr[27:2] % DMEM_WORDS][8*b +: 8] <= dmem_wdata[8*b +: 8];
          d_st <= D_IDLE;
        end
        default: d_st <= D_IDLE;
      endcase
    end
  end

  // ============================================================== golden reference model (Stage 4 pattern)
  logic [31:0] g_rf [32]; logic [31:0] g_pc;
  logic        g_mie, g_mpie; logic [31:0] g_mtvec, g_mepc, g_mcause, g_mtval, g_mscratch;
  logic        g_msie, g_mtie, g_meie;
  logic [63:0] g_cycle, g_instret;

  function automatic void g_reset();
    for (int i = 0; i < 32; i++) g_rf[i] = 0;
    g_pc = 32'h0000_0000; g_mie = 0; g_mpie = 0; g_mtvec = 0; g_mepc = 0; g_mcause = 0; g_mtval = 0;
    g_mscratch = 0; g_msie = 0; g_mtie = 0; g_meie = 0; g_cycle = 0; g_instret = 0;
  endfunction

  function automatic logic [31:0] g_mem_r(input logic [31:0] a);
    if (a[31:28] == 4'h4) return mmio_reg;
    return (a[27:2] < DMEM_WORDS) ? dmem[a[27:2] % DMEM_WORDS] : 32'd0;
  endfunction
  task automatic g_mem_w(input logic [31:0] a, input logic [31:0] d, input logic [3:0] be);
    if (a[31:28] == 4'h4) return;
    if (a[27:2] < DMEM_WORDS)
      for (int b = 0; b < 4; b++) if (be[b]) dmem[a[27:2] % DMEM_WORDS][8*b +: 8] <= d[8*b +: 8];
  endtask

  function automatic logic [31:0] sra32(input logic [31:0] a, input logic [4:0] n);
    logic signed [31:0] sa; sa = a; return sa >>> n;
  endfunction
  function automatic void g_wb(input logic [4:0] r, input logic [31:0] v); if (r != 0) g_rf[r] = v; endfunction
  function automatic logic [31:0] g_csr_r(input logic [11:0] a);
    case (a)
      12'h300: return {19'd0, 2'b11, 3'd0, g_mpie, 3'd0, g_mie, 3'd0};
      12'h304: return {20'd0, g_meie, 3'd0, g_mtie, 3'd0, g_msie, 3'd0};
      12'h305: return g_mtvec;
      12'h340: return g_mscratch;
      12'h341: return g_mepc;
      12'h342: return g_mcause;
      12'h343: return g_mtval;
      12'hB00, 12'hC00: return g_cycle[31:0];
      12'hB02, 12'hC02: return g_instret[31:0];
      default: return 32'd0;
    endcase
  endfunction
  task automatic g_csr_w(input logic [11:0] a, input logic [31:0] v);
    case (a)
      12'h300: begin g_mie = v[3]; g_mpie = v[7]; end
      12'h304: begin g_msie = v[3]; g_mtie = v[7]; g_meie = v[11]; end
      12'h305: g_mtvec = {v[31:2], 2'b00};
      12'h340: g_mscratch = v;
      12'h341: g_mepc = {v[31:2], 2'b00};
      12'h342: g_mcause = v;
      12'h343: g_mtval = v;
      default: ;
    endcase
  endtask

  task automatic g_step(input bit msip, mtip, meip);
    logic [31:0] instr, imm, rs1v, rs2v, res, addr; logic [4:0] rd, rs1, rs2;
    logic [6:0]  op; logic [2:0] f3; logic [6:0] f7; bit taken; logic [31:0] target;
    bit trap; logic [31:0] cause, tval;
    g_cycle++;
    if (g_mie && ((meip && g_meie) || (msip && g_msie) || (mtip && g_mtie))) begin
      cause = (meip && g_meie) ? 32'h8000_000B : (msip && g_msie) ? 32'h8000_0003 : 32'h8000_0007;
      g_mepc = g_pc; g_mcause = cause; g_mtval = 0; g_mpie = g_mie; g_mie = 0;
      g_pc = g_mtvec; g_instret++; return;
    end
    instr = imem[(g_pc >> 2) % IMEM_WORDS];
    op = instr[6:0]; f3 = instr[14:12]; f7 = instr[31:25]; rd = instr[11:7]; rs1 = instr[19:15]; rs2 = instr[24:20];
    rs1v = g_rf[rs1]; rs2v = g_rf[rs2];
    trap = 0; cause = 0; tval = 0;
    case (op)
      OP_LUI:   begin res = {instr[31:12], 12'd0}; g_wb(rd, res); g_pc = g_pc + 4; end
      OP_AUIPC: begin res = g_pc + {instr[31:12], 12'd0}; g_wb(rd, res); g_pc = g_pc + 4; end
      OP_JAL: begin
        imm = {{11{instr[31]}}, instr[31], instr[19:12], instr[20], instr[30:21], 1'b0};
        g_wb(rd, g_pc + 4); g_pc = g_pc + imm;
      end
      OP_JALR: begin
        imm = {{20{instr[31]}}, instr[31:20]};
        target = (rs1v + imm) & ~32'd1;
        g_wb(rd, g_pc + 4); g_pc = target;
      end
      OP_BRANCH: begin
        imm = {{19{instr[31]}}, instr[31], instr[7], instr[30:25], instr[11:8], 1'b0};
        case (f3)
          3'b000: taken = (rs1v == rs2v);
          3'b001: taken = (rs1v != rs2v);
          3'b100: taken = ($signed(rs1v) < $signed(rs2v));
          3'b101: taken = ($signed(rs1v) >= $signed(rs2v));
          3'b110: taken = (rs1v < rs2v);
          default: taken = (rs1v >= rs2v);
        endcase
        g_pc = taken ? (g_pc + imm) : (g_pc + 4);
      end
      OP_LOAD: begin
        logic [31:0] mv; logic [7:0] mb; logic [15:0] mh;
        imm = {{20{instr[31]}}, instr[31:20]};
        addr = rs1v + imm;
        mv = g_mem_r(addr); mb = mv[8*addr[1:0] +: 8]; mh = addr[1] ? mv[31:16] : mv[15:0];
        case (f3)
          3'b000: res = {{24{mb[7]}}, mb};
          3'b100: res = {24'd0, mb};
          3'b001: res = {{16{mh[15]}}, mh};
          3'b101: res = {16'd0, mh};
          default: res = mv;
        endcase
        g_wb(rd, res); g_pc = g_pc + 4;
      end
      OP_STORE: begin
        imm = {{20{instr[31]}}, instr[31:25], instr[11:7]};
        addr = rs1v + imm;
        case (f3)
          3'b000: g_mem_w(addr, {4{rs2v[7:0]}}, 4'b0001 << addr[1:0]);
          3'b001: g_mem_w(addr, {2{rs2v[15:0]}}, addr[1] ? 4'b1100 : 4'b0011);
          default: g_mem_w(addr, rs2v, 4'hF);
        endcase
        g_pc = g_pc + 4;
      end
      OP_IMM: begin
        imm = {{20{instr[31]}}, instr[31:20]};
        case (f3)
          3'b000: res = rs1v + imm;
          3'b010: res = ($signed(rs1v) < $signed(imm)) ? 32'd1 : 32'd0;
          3'b011: res = (rs1v < imm) ? 32'd1 : 32'd0;
          3'b100: res = rs1v ^ imm;
          3'b110: res = rs1v | imm;
          3'b111: res = rs1v & imm;
          3'b001: res = rs1v << imm[4:0];
          default: res = f7[5] ? sra32(rs1v, imm[4:0]) : (rs1v >> imm[4:0]);
        endcase
        g_wb(rd, res); g_pc = g_pc + 4;
      end
      OP_REG: begin
        if (f7 == 7'b0000001) begin
          logic signed [63:0] sp; logic [63:0] up; logic signed [31:0] xs, ys;
          xs = $signed(rs1v); ys = $signed(rs2v);
          case (f3)
            3'b000: begin sp = $signed({{32{rs1v[31]}}, rs1v}) * $signed({{32{rs2v[31]}}, rs2v}); res = sp[31:0]; end
            3'b001: begin sp = $signed({{32{rs1v[31]}}, rs1v}) * $signed({{32{rs2v[31]}}, rs2v}); res = sp[63:32]; end
            3'b010: begin sp = $signed({{32{rs1v[31]}}, rs1v}) * $signed({1'b0, rs2v}); res = sp[63:32]; end
            3'b011: begin up = {32'd0, rs1v} * {32'd0, rs2v}; res = up[63:32]; end
            3'b100: begin
              if (rs2v == 0) res = 32'hFFFF_FFFF;
              else if (rs1v == 32'h8000_0000 && rs2v == 32'hFFFF_FFFF) res = 32'h8000_0000;
              else res = $signed(xs / ys);
            end
            3'b101: res = (rs2v == 0) ? 32'hFFFF_FFFF : (rs1v / rs2v);
            3'b110: begin
              if (rs2v == 0) res = rs1v;
              else if (rs1v == 32'h8000_0000 && rs2v == 32'hFFFF_FFFF) res = 32'd0;
              else res = $signed(xs % ys);
            end
            default: res = (rs2v == 0) ? rs1v : (rs1v % rs2v);
          endcase
        end else begin
          case (f3)
            3'b000: res = f7[5] ? (rs1v - rs2v) : (rs1v + rs2v);
            3'b001: res = rs1v << rs2v[4:0];
            3'b010: res = ($signed(rs1v) < $signed(rs2v)) ? 32'd1 : 32'd0;
            3'b011: res = (rs1v < rs2v) ? 32'd1 : 32'd0;
            3'b100: res = rs1v ^ rs2v;
            3'b101: res = f7[5] ? sra32(rs1v, rs2v[4:0]) : (rs1v >> rs2v[4:0]);
            3'b110: res = rs1v | rs2v;
            default: res = rs1v & rs2v;
          endcase
        end
        g_wb(rd, res); g_pc = g_pc + 4;
      end
      OP_FENCE: g_pc = g_pc + 4;
      OP_SYSTEM: begin
        if (f3 == 3'b000) begin
          case (instr[31:20])
            12'h000: begin trap = 1; cause = 11; tval = 0; end
            12'h001: begin trap = 1; cause = 3;  tval = 0; end
            12'h302: begin g_mie = g_mpie; g_mpie = 1; g_pc = g_mepc; end
            default: g_pc = g_pc + 4;
          endcase
        end else begin
          logic [31:0] csr_old, opnd, nv;
          csr_old = g_csr_r(instr[31:20]);
          opnd = f3[2] ? {27'd0, rs1} : rs1v;
          case (f3[1:0])
            2'b01: nv = opnd;
            2'b10: nv = csr_old | opnd;
            default: nv = csr_old & ~opnd;
          endcase
          if (!(f3[1:0] inside {2'b10, 2'b11} && opnd == 0)) g_csr_w(instr[31:20], nv);
          g_wb(rd, csr_old); g_pc = g_pc + 4;
        end
      end
      default: g_pc = g_pc + 4;
    endcase
    if (!trap) g_instret++;
    if (trap) begin
      g_mepc = g_pc; g_mcause = cause; g_mtval = tval; g_mpie = g_mie; g_mie = 0; g_pc = g_mtvec;
    end
  endtask

  // ============================================================== retire monitor & checkpoints
  wire dut_retire_pulse = dut.exmem_q.valid && !dut.mem_stall &&
                          (dut.exmem_q.ctrl.reg_write || dut.exmem_q.ctrl.mem_write ||
                           dut.mem_mret || (dut.exmem_q.ctrl.is_mret & dut.trap_take) ||
                           (!dut.exmem_q.ctrl.reg_write && !dut.exmem_q.ctrl.mem_write &&
                            !dut.exmem_q.ctrl.is_mret && !dut.trap_take && !dut.exmem_q.exc));
  wire dut_trap_pulse = dut.trap_take;

  logic [31:0] ckpt [4096];
  int          n_ckpt = 0, ckpt_ptr = 0;
  int          n_checks = 0, n_mismatch = 0, n_pc_chk = 0, n_pc_bad = 0;

  // ---- V3: CPU-level architectural assertions -----------------------------------------------
  ap_x0_zero: assert property (@(posedge clk) disable iff (!rst_n) dut.u_rf.rf[0] == 32'd0);
  ap_no_commit_after_flush: assert property (@(posedge clk) disable iff (!rst_n)
      dut.mem_redirect |=> (!dut.ifid_q.valid && !dut.idex_q.valid && !dut.exmem_q.valid));
  ap_no_dmem_on_irq: assert property (@(posedge clk) disable iff (!rst_n) dut.irq_take |-> !dut.dmem_req);
  ap_stall_holds_state: assert property (@(posedge clk) disable iff (!rst_n)
      dut.mem_stall |=> $stable(dut.exmem_q.pc));

  logic [31:0] snap [32];
  bit          ck_pending = 0;
  string       ck_tag;
  // Compare a snapshot of the golden state (taken when the checkpoint instruction retired
  // in MEM) against the DUT's architectural view one cycle later, when that instruction sits
  // in WB: architectural view = regfile overlaid with the pending MEM/WB write.
  task automatic compare_snap(input string tag);
    logic [31:0] act;
    for (int r = 1; r < 32; r++) begin
      act = (dut.memwb_q.reg_write && dut.memwb_q.rd == 5'(r)) ? dut.memwb_q.data : dut.u_rf.rf[r];
      n_checks++;
      if (act !== snap[r]) n_mismatch++;
      rchk($sformatf("%s_x%0d", tag, r), {32'd0, snap[r]}, {32'd0, act});
    end
  endtask

  task automatic compare_now(input string tag);
    logic [31:0] act;
    for (int r = 1; r < 32; r++) begin
      act = dut.u_rf.rf[r];
      n_checks++;
      if (act !== g_rf[r]) n_mismatch++;
      rchk($sformatf("%s_x%0d", tag, r), {32'd0, g_rf[r]}, {32'd0, act});
    end
  endtask

  // ============================================================== main run: one continuous stream
  initial begin
    int seg = 0;
    int idx;
    logic [31:0] expect_tbl [16];
    tb_init("cpu_stage5");
    cov_def(0,"alu_reg"); cov_def(1,"alu_imm"); cov_def(2,"m_extension"); cov_def(3,"load");
    cov_def(4,"store"); cov_def(5,"branch_taken"); cov_def(6,"branch_nottaken"); cov_def(7,"csr_access");
    cov_def(8,"benchmark_checkpoint"); cov_def(9,"random_checkpoint"); cov_def(10,"load_use_stall");
    cov_def(11,"dcache_stall_model"); cov_def(12,"long_running_1000plus_instr");

    $readmemh("cpu_stage5_ckpt.hex", ckpt);
    idx = 0;
    while (ckpt[idx] !== 32'hFFFF_FFFF && idx < 4096) idx++;
    n_ckpt = idx;

    $readmemh("cpu_stage5.hex", imem);
    for (int i = 0; i < DMEM_WORDS; i++) dmem[i] = 32'd0;

    rst_n = 0; repeat (4) @(negedge clk); g_reset(); rst_n = 1;

    while (ckpt_ptr < n_ckpt) begin
      @(negedge clk);
      // sweep D-side latency across the run to fold stall/backpressure coverage in
      dlat = (cyc[13:12] == 2'd0) ? 0 : (cyc[13:12] == 2'd1) ? 2 : (cyc[13:12] == 2'd2) ? 5 : 9;
      #1;
      if (dut_retire_pulse) begin
        if (dut.exmem_q.ctrl.is_md)                          cov_hit(2);
        else if (dut.exmem_q.ctrl.mem_read)                  cov_hit(3);
        else if (dut.exmem_q.ctrl.mem_write)                 cov_hit(4);
        else if (dut.exmem_q.ctrl.csr_en)                    cov_hit(7);
        else if (dut.exmem_q.ctrl.is_branch)                 cov_hit(dut.ex_taken ? 5 : 6);
        else if (dut.exmem_q.ctrl.reg_write && !dut.exmem_q.ctrl.is_jal && !dut.exmem_q.ctrl.is_jalr)
          cov_hit(dut.idex_q.ctrl.op_b_imm ? 1 : 0);
        if (dut.load_use) cov_hit(10);
        if (dlat != 0)    cov_hit(11);
        if (seg > 1000)   cov_hit(12);
      end
      if (ck_pending) begin compare_snap(ck_tag); ck_pending = 0; end
      // PC lock-step: the retiring instruction's PC must equal the golden model's next PC
      if (dut_retire_pulse && !dut_trap_pulse) begin
        n_pc_chk++;
        if (dut.exmem_q.pc !== g_pc) begin
          n_pc_bad++;
          if (n_pc_bad <= 3)
            $display("[cpu_stage5] PC-DIVERGE cycle=%0d seg=%0d dut_pc=%08h golden_pc=%08h instr@dut=%08h",
                     cyc, seg, dut.exmem_q.pc, g_pc, imem[(dut.exmem_q.pc>>2)%IMEM_WORDS]);
        end
      end
      if (dut_retire_pulse || dut_trap_pulse) g_step(irq_msip, irq_mtip, irq_meip);
      if (dut_retire_pulse && dut.exmem_q.pc == ckpt[ckpt_ptr]) begin
        seg++;
        if (seg <= 1200) cov_hit(9); else cov_hit(8);
        for (int r = 0; r < 32; r++) snap[r] = g_rf[r];
        ck_tag = $sformatf("seg%0d", seg); ck_pending = 1;
        ckpt_ptr++;
      end
      if (cyc > 400000) begin   // safety valve: a hung DUT/program must fail, never hang the regression
        chk("SAFETY_TIMEOUT", 64'd1, 64'd0);
        $display("[cpu_stage5] TIMEOUT at seg=%0d ckpt_ptr=%0d/%0d dut_pc=%08h golden_pc=%08h", seg, ckpt_ptr, n_ckpt, dut.exmem_q.pc, g_pc);
        break;
      end
    end

    @(negedge clk); #1; if (ck_pending) begin compare_snap(ck_tag); ck_pending = 0; end
    chk("all_checkpoints_reached", 64'(n_ckpt), 64'(ckpt_ptr));
    chk("zero_mismatches", 64'd0, 64'(n_mismatch));
    chk("pc_lockstep_zero_divergence", 64'd0, 64'(n_pc_bad));
    $display("[cpu_stage5] PC lock-step checks: %0d, divergences: %0d", n_pc_chk, n_pc_bad);
    $display("[cpu_stage5] %0d checkpoints, %0d register comparisons, %0d mismatches",
              ckpt_ptr, n_checks, n_mismatch);

    // ---- final-answer cross-check for the 9 benchmarks (independent of the golden model) ----
    $readmemh("cpu_stage5_expect.hex", expect_tbl);
    chk("bench_fibonacci",    {32'd0, expect_tbl[0]}, {32'd0, dmem[200]});
    chk("bench_factorial",    {32'd0, expect_tbl[1]}, {32'd0, dmem[201]});
    chk("bench_gcd",          {32'd0, expect_tbl[2]}, {32'd0, dmem[202]});
    chk("bench_array_sum",    {32'd0, expect_tbl[3]}, {32'd0, dmem[203]});
    chk("bench_checksum",     {32'd0, expect_tbl[6]}, {32'd0, dmem[206]});
    chk("bench_branch_heavy", {32'd0, expect_tbl[7]}, {32'd0, dmem[207]});
    chk("bench_muldiv_chain", {32'd0, expect_tbl[8]}, {32'd0, dmem[208]});
    begin
      bit sorted = 1;
      for (int k = 0; k < 5; k++) if (dmem[240+k] > dmem[241+k]) sorted = 0;
      chk("bench_bubble_sort_ascending", 64'd1, {63'd0, sorted});
    end
    begin
      bit copied = 1;
      for (int k = 0; k < 8; k++) if (dmem[260+k] !== dmem[270+k]) copied = 0;
      chk("bench_memcopy_matches", 64'd1, {63'd0, copied});
    end

    // ---- dedicated directed scenario: interrupt taken while a long D-side stall is in flight ----
    begin
      logic [31:0] prog2 [40];
      for (int i = 0; i < 40; i++) prog2[i] = 32'h0000_0013;
      prog2[0]  = {12'd80, 5'd0, 3'b000, 5'd7, OP_IMM};          // ADDI x7,x0,80 (mtvec = word 20)
      prog2[1]  = {12'h305, 5'd7, 3'b001, 5'd0, OP_SYSTEM};      // CSRRW mtvec,x7
      prog2[2]  = {12'd8, 5'd0, 3'b000, 5'd6, OP_IMM};           // ADDI x6,x0,8 (MIE)
      prog2[3]  = {12'h300, 5'd6, 3'b001, 5'd0, OP_SYSTEM};      // CSRRW mstatus,x6
      prog2[4]  = {12'd128, 5'd0, 3'b000, 5'd6, OP_IMM};         // ADDI x6,x0,128 (MTIE)
      prog2[5]  = {12'h304, 5'd6, 3'b001, 5'd0, OP_SYSTEM};      // CSRRW mie,x6
      prog2[6]  = {12'd0, 5'd0, 3'b000, 5'd1, OP_IMM};           // ADDI x1,x0,0
      prog2[7]  = {12'd0, 5'd1, 3'b010, 5'd2, OP_LOAD};          // LW x2,0(x1) <- long stall while irq asserts
      prog2[8]  = {12'd11, 5'd0, 3'b000, 5'd9, OP_IMM};          // ADDI x9,x0,11 (post-irq marker)
      prog2[20] = {12'd55, 5'd0, 3'b000, 5'd8, OP_IMM};          // handler: ADDI x8,x0,55
      prog2[21] = {12'h341, 5'd0, 3'b010, 5'd6, OP_SYSTEM};      // CSRRS x6,x0,mepc
      prog2[22] = {12'd4, 5'd6, 3'b000, 5'd6, OP_IMM};           // ADDI x6,x6,4
      prog2[23] = {12'h341, 5'd6, 3'b001, 5'd0, OP_SYSTEM};      // CSRRW mepc,x6
      prog2[24] = 32'h3020_0073;                                  // MRET

      dlat = 8;
      for (int i = 0; i < 40; i++) imem[i] = prog2[i];
      rst_n = 0; repeat (4) @(negedge clk); g_reset(); rst_n = 1;
      for (int c = 0; c < 60; c++) begin
        @(negedge clk);
        if (c == 20) irq_mtip = 1;
        #1;
        if (dut_retire_pulse || dut_trap_pulse) g_step(irq_msip, irq_mtip, irq_meip);
        if (c == 40) irq_mtip = 0;
      end
      repeat (5) @(negedge clk);
      compare_now("irq_during_stall");
      cov_hit(11);
      dlat = 0;
    end

    finish_report();
    $finish;
  end
endmodule
