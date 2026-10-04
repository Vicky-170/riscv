// =============================================================================
// rv32im_core.sv - 5-stage in-order RV32IM core (IF ID EX MEM WB)
//
// Key micro-architecture decisions (details in docs/RTL_CHECKPOINTS.md):
//  * Precise traps are TAKEN IN MEM.  Exceptions found earlier (fetch fault,
//    illegal, ecall/ebreak, misaligned jump target) ride along the pipeline
//    with the instruction; MEM adds load/store/CSR faults and interrupts.
//    Nothing architectural (memory, CSR, regfile) is written before MEM commit.
//  * CSR instructions execute in MEM (non-speculative) -> "late" producers,
//    handled by the load-use interlock exactly like loads.
//  * Branches resolve in EX.  Prediction: BTB+BHT in IF (default), BHT-only in
//    ID, or static not-taken - selected by ENABLE_BHT / ENABLE_BTB.
//  * While EX/MEM/WB are frozen, ID/EX operands are refreshed with the
//    forwarded values so bypassed data is not lost when the producer retires.
//  * Interrupts are taken only when the MEM instruction has not started a
//    D-cache transaction (dmem_busy = 0), so a bus transfer is never abandoned.
// =============================================================================
module rv32im_core import rv32im_pkg::*; #(
  parameter logic [31:0] RESET_PC          = 32'h0000_0000,
  parameter bit          ENABLE_BHT        = 1'b1,
  parameter bit          ENABLE_BTB        = 1'b1,
  parameter int          BHT_ENTRIES       = 64,
  parameter int          BTB_ENTRIES       = 16,
  parameter int          MUL_IMPL          = 0,      // 0: 1-cycle mul, 1: iterative
  parameter bit          OPERAND_ISOLATION = 1'b0,   // zero md operands when not an M op
  parameter bit          RESET_REGS        = 1'b0
) (
  input  logic        clk,
  input  logic        rst_n,
  // instruction port (I-cache): combinational hit, ready=0 while refilling
  output logic [31:0] imem_addr,
  input  logic [31:0] imem_rdata,
  input  logic        imem_ready,
  input  logic        imem_err,
  output logic        imem_inval,        // FENCE.I
  // data port (D-cache): request held stable until ready
  output logic        dmem_req,
  output logic        dmem_we,
  output logic [31:0] dmem_addr,
  output logic [31:0] dmem_wdata,        // already replicated across byte lanes
  output logic [3:0]  dmem_be,
  input  logic [31:0] dmem_rdata,
  input  logic        dmem_ready,
  input  logic        dmem_err,
  input  logic        dmem_busy,
  // interrupts (level)
  input  logic        irq_msip,
  input  logic        irq_mtip,
  input  logic        irq_meip,
  // performance events (1-cycle pulses)
  input  logic        evt_icache_miss,
  input  logic        evt_dcache_miss
);
  localparam bit EARLY_ID = ENABLE_BHT && !ENABLE_BTB;   // BHT-only: redirect from ID

  // ---------------------------------------------------------------- pipeline registers
  if_id_t  ifid_d,  ifid_q;
  id_ex_t  idex_d,  idex_in, idex_q;
  ex_mem_t exmem_d, exmem_q;
  mem_wb_t memwb_d, memwb_q;

  // ---------------------------------------------------------------- control wires
  logic mem_stall, ex_busy, load_use;
  logic pc_hold, ifid_hold, idex_hold, exmem_hold;
  logic ifid_flush, idex_flush, exmem_flush, memwb_flush;
  logic trap_take, mem_redirect, ex_redirect, id_redirect;
  logic [31:0] mem_redirect_pc, ex_redirect_pc, id_redirect_pc;

  // =====================================================================
  // IF stage
  // =====================================================================
  logic [31:0] pc_if, pc_plus4_if, pred_target_if;
  logic        pred_taken_if, redirect_valid;
  logic [31:0] redirect_pc;

  assign redirect_valid = mem_redirect | ex_redirect | id_redirect;
  assign redirect_pc    = mem_redirect ? mem_redirect_pc :
                          ex_redirect  ? ex_redirect_pc  : id_redirect_pc;

  pc_unit #(.RESET_PC(RESET_PC)) u_pc (
    .clk(clk), .rst_n(rst_n),
    .advance(imem_ready & ~pc_hold),
    .redirect_valid(redirect_valid), .redirect_pc(redirect_pc),
    .pred_taken(pred_taken_if), .pred_target(pred_target_if),
    .pc(pc_if), .pc_plus4(pc_plus4_if)
  );
  assign imem_addr = pc_if;

  // predictor (trained from EX, see below)
  logic        id_bht_taken;
  logic        bp_upd_valid, bp_upd_is_cond, bp_upd_taken;
  logic [31:0] bp_upd_pc, bp_upd_target;

  branch_predictor #(
    .ENABLE_BHT(ENABLE_BHT), .ENABLE_BTB(ENABLE_BTB),
    .BHT_ENTRIES(BHT_ENTRIES), .BTB_ENTRIES(BTB_ENTRIES)
  ) u_bp (
    .clk(clk), .rst_n(rst_n),
    .if_pc(pc_if), .if_pred_taken(pred_taken_if), .if_pred_target(pred_target_if),
    .id_pc(ifid_q.pc), .id_bht_taken(id_bht_taken),
    .upd_valid(bp_upd_valid), .upd_is_cond(bp_upd_is_cond),
    .upd_pc(bp_upd_pc), .upd_taken(bp_upd_taken), .upd_target(bp_upd_target)
  );

  always_comb begin
    ifid_d            = '0;
    ifid_d.valid      = imem_ready & ~id_redirect;   // early-ID redirect squashes the incoming fetch
    ifid_d.exc        = imem_ready & imem_err;
    ifid_d.exc_cause  = CAUSE_INSN_ACCESS;
    ifid_d.pc         = pc_if;
    ifid_d.instr      = imem_rdata;
    ifid_d.pred_taken = pred_taken_if;
    ifid_d.pred_target= pred_target_if;
  end

  if_id_reg u_ifid (.clk(clk), .rst_n(rst_n), .en(~ifid_hold), .flush(ifid_flush), .d(ifid_d), .q(ifid_q));

  // =====================================================================
  // ID stage
  // =====================================================================
  ctrl_t       dctrl, id_ctrl;
  logic [31:0] id_imm, rf_rs1, rf_rs2;

  decoder       u_dec (.instr(ifid_q.instr), .ctrl(dctrl));
  immediate_gen u_imm (.instr(ifid_q.instr), .imm(id_imm));

  // exception detection in ID (fetch fault > illegal > ebreak > ecall)
  logic        id_exc;
  logic [3:0]  id_cause;
  logic [31:0] id_tval;
  always_comb begin
    id_exc = 1'b0; id_cause = 4'd0; id_tval = 32'd0;
    if (ifid_q.valid) begin
      if (ifid_q.exc)         begin id_exc = 1'b1; id_cause = ifid_q.exc_cause; id_tval = ifid_q.pc;    end
      else if (dctrl.illegal) begin id_exc = 1'b1; id_cause = CAUSE_ILLEGAL;    id_tval = ifid_q.instr; end
      else if (dctrl.is_ebreak) begin id_exc = 1'b1; id_cause = CAUSE_BREAKPOINT; id_tval = ifid_q.pc;  end
      else if (dctrl.is_ecall)  begin id_exc = 1'b1; id_cause = CAUSE_ECALL_M;    id_tval = 32'd0;      end
    end
  end
  // RTL FIX #4 (Stage 4): a bubble (ifid_q.valid=0, e.g. during pipeline warm-up or after a
  // flush) must present ctrl=0 downstream per the documented invariant in pipeline_regs.sv
  // ("a bubble is a register with valid=0 and all side-effect controls at 0"). Without the
  // explicit !ifid_q.valid gate here, an invalid stage's leftover/undefined instruction bits
  // could still decode to a nonzero ctrl (e.g. reg_write=1 with some rd), which the id_ex_reg
  // would then latch alongside valid=0 - and forwarding_unit, which correctly trusts ctrl.reg_write
  // without re-checking valid (matching its own tested contract), could forward garbage data
  // from that bubble into a real instruction's ALU operand.
  assign id_ctrl = (id_exc || !ifid_q.valid) ? '0 : dctrl;   // excepting/invalid instruction becomes a side-effect-free bubble

  register_file #(.RESET_REGS(RESET_REGS)) u_rf (
    .clk(clk), .rst_n(rst_n),
    .raddr1(ifid_q.instr[19:15]), .raddr2(ifid_q.instr[24:20]),
    .rdata1(rf_rs1), .rdata2(rf_rs2),
    .we(memwb_q.reg_write), .waddr(memwb_q.rd), .wdata(memwb_q.data)
  );

  // early (ID-stage) prediction for BHT-only mode: JAL always, branches by BHT
  logic id_early_taken;
  assign id_early_taken  = EARLY_ID & ifid_q.valid & ~id_exc &
                           (id_ctrl.is_jal | (id_ctrl.is_branch & id_bht_taken));
  assign id_redirect     = id_early_taken & ~ifid_hold;      // fire once, when the branch leaves ID
  assign id_redirect_pc  = ifid_q.pc + id_imm;

  always_comb begin
    idex_d             = '0;
    idex_d.valid       = ifid_q.valid;
    idex_d.ctrl        = id_ctrl;
    idex_d.exc         = id_exc;
    idex_d.exc_cause   = id_cause;
    idex_d.pred_taken  = EARLY_ID ? id_early_taken : ifid_q.pred_taken;
    idex_d.pred_target = EARLY_ID ? id_redirect_pc : ifid_q.pred_target;
    idex_d.pc          = ifid_q.pc;
    idex_d.rs1_val     = rf_rs1;
    idex_d.rs2_val     = rf_rs2;
    idex_d.imm         = id_imm;
    idex_d.tval        = id_tval;
    idex_d.rs1         = ifid_q.instr[19:15];
    idex_d.rs2         = ifid_q.instr[24:20];
    idex_d.rd          = ifid_q.instr[11:7];
    idex_d.funct3      = ifid_q.instr[14:12];
  end

  // =====================================================================
  // EX stage
  // =====================================================================
  logic [1:0]  fwd_a, fwd_b;
  logic [31:0] ex_rs1_f, ex_rs2_f;                    // operands after forwarding
  logic [31:0] alu_a, alu_b, alu_y, ex_result, md_result, csr_operand;
  logic        ex_taken, md_ready;
  logic [31:0] ex_target, pc4_ex;

  forwarding_unit u_fwd (
    .ex_rs1(idex_q.rs1), .ex_rs2(idex_q.rs2),
    .exmem_reg_write(exmem_q.ctrl.reg_write), .exmem_rd(exmem_q.rd),
    .memwb_reg_write(memwb_q.reg_write),      .memwb_rd(memwb_q.rd),
    .fwd_a(fwd_a), .fwd_b(fwd_b)
  );

  always_comb begin
    case (fwd_a)
      2'd1:    ex_rs1_f = exmem_q.alu_result;
      2'd2:    ex_rs1_f = memwb_q.data;
      default: ex_rs1_f = idex_q.rs1_val;
    endcase
    case (fwd_b)
      2'd1:    ex_rs2_f = exmem_q.alu_result;
      2'd2:    ex_rs2_f = memwb_q.data;
      default: ex_rs2_f = idex_q.rs2_val;
    endcase
  end

  // ALU operand select
  always_comb begin
    case (idex_q.ctrl.op_a_sel)
      A_PC:    alu_a = idex_q.pc;
      A_ZERO:  alu_a = 32'd0;
      default: alu_a = ex_rs1_f;
    endcase
    alu_b = idex_q.ctrl.op_b_imm ? idex_q.imm : ex_rs2_f;
  end

  alu u_alu (.a(alu_a), .b(alu_b), .op(idex_q.ctrl.alu_op), .y(alu_y));

  branch_unit u_br (
    .funct3(idex_q.funct3), .rs1(ex_rs1_f), .rs2(ex_rs2_f),
    .is_branch(idex_q.ctrl.is_branch), .is_jal(idex_q.ctrl.is_jal), .is_jalr(idex_q.ctrl.is_jalr),
    .pc(idex_q.pc), .imm(idex_q.imm), .jalr_sum(alu_y),
    .taken(ex_taken), .target(ex_target)
  );

  // multiply / divide (operand isolation removes toggling when not an M op)
  logic [31:0] md_a, md_b;
  assign md_a = (OPERAND_ISOLATION && !idex_q.ctrl.is_md) ? 32'd0 : ex_rs1_f;
  assign md_b = (OPERAND_ISOLATION && !idex_q.ctrl.is_md) ? 32'd0 : ex_rs2_f;

  muldiv_unit #(.MUL_IMPL(MUL_IMPL)) u_md (
    .clk(clk), .rst_n(rst_n), .flush(mem_redirect),
    .req(idex_q.valid & idex_q.ctrl.is_md), .op(idex_q.funct3),
    .a(md_a), .b(md_b), .ack(~mem_stall),
    .ready(md_ready), .result(md_result)
  );
  assign ex_busy = idex_q.valid & idex_q.ctrl.is_md & ~md_ready;

  assign pc4_ex      = idex_q.pc + 32'd4;
  assign csr_operand = idex_q.funct3[2] ? {27'd0, idex_q.rs1} : ex_rs1_f;   // zimm or rs1

  always_comb begin
    if (idex_q.ctrl.is_jal | idex_q.ctrl.is_jalr) ex_result = pc4_ex;       // link address
    else if (idex_q.ctrl.is_md)                   ex_result = md_result;
    else if (idex_q.ctrl.csr_en)                  ex_result = csr_operand;  // CSR write operand -> MEM
    else                                          ex_result = alu_y;
  end

  // ---- branch resolution --------------------------------------------------------
  logic ex_fire, ex_misalign, ex_mispred, ex_is_cf, ex_train;
  assign ex_fire     = idex_q.valid & ~idex_q.exc & ~mem_stall & ~ex_busy;   // instruction advances now
  assign ex_is_cf    = idex_q.ctrl.is_branch | idex_q.ctrl.is_jal | idex_q.ctrl.is_jalr;
  assign ex_misalign = ex_fire & ex_taken & ex_target[1];                    // target not 4-byte aligned
  assign ex_mispred  = ex_fire & ~ex_misalign &
                       ((ex_taken ^ idex_q.pred_taken) |
                        (ex_taken & (ex_target != idex_q.pred_target)));
  assign ex_redirect    = ex_mispred;
  assign ex_redirect_pc = ex_taken ? ex_target : pc4_ex;

  // train predictor only with committed-path instructions
  assign ex_train       = ex_fire & ~mem_redirect & ~ex_misalign & ex_is_cf;
  assign bp_upd_valid   = ex_train;
  assign bp_upd_is_cond = idex_q.ctrl.is_branch;
  assign bp_upd_pc      = idex_q.pc;
  assign bp_upd_taken   = ex_taken;
  assign bp_upd_target  = ex_target;

  // ID/EX: when frozen, capture the forwarded operands so they survive the stall
  always_comb begin
    idex_in = idex_d;
    if (idex_hold) begin
      idex_in         = idex_q;
      idex_in.rs1_val = ex_rs1_f;
      idex_in.rs2_val = ex_rs2_f;
    end
  end
  id_ex_reg u_idex (.clk(clk), .rst_n(rst_n), .en(1'b1), .flush(idex_flush), .d(idex_in), .q(idex_q));

  // EX/MEM
  always_comb begin
    exmem_d            = '0;
    exmem_d.valid      = idex_q.valid;
    exmem_d.exc        = idex_q.exc | ex_misalign;
    exmem_d.exc_cause  = idex_q.exc ? idex_q.exc_cause : CAUSE_INSN_MISALIGNED;
    exmem_d.tval       = idex_q.exc ? idex_q.tval : ex_target;
    // RTL FIX #4 (Stage 4, continued): same invariant enforced at the EX/MEM boundary.
    exmem_d.ctrl       = (exmem_d.exc || !idex_q.valid) ? '0 : idex_q.ctrl;
    exmem_d.csr_we     = (idex_q.funct3[1:0] == 2'b01) | (idex_q.rs1 != 5'd0);
    exmem_d.pc         = idex_q.pc;
    exmem_d.alu_result = ex_result;
    exmem_d.store_data = ex_rs2_f;
    exmem_d.rd         = idex_q.rd;
    exmem_d.funct3     = idex_q.funct3;
    exmem_d.csr_addr   = idex_q.imm[11:0];
  end
  ex_mem_reg u_exmem (.clk(clk), .rst_n(rst_n), .en(~exmem_hold), .flush(exmem_flush), .d(exmem_d), .q(exmem_q));

  // =====================================================================
  // MEM stage : D-cache access, CSR, traps, MRET, FENCE.I
  // =====================================================================
  logic [31:0] mem_addr;
  logic        mem_is_ld, mem_is_st, mem_misalign, irq_take, dmem_err_take;
  logic [1:0]  mem_size;
  assign mem_addr  = exmem_q.alu_result;
  assign mem_is_ld = exmem_q.ctrl.mem_read;
  assign mem_is_st = exmem_q.ctrl.mem_write;
  assign mem_size  = exmem_q.funct3[1:0];

  assign mem_misalign = exmem_q.valid & (mem_is_ld | mem_is_st) &
                        (((mem_size == 2'b01) & mem_addr[0]) | ((mem_size == 2'b10) & (|mem_addr[1:0])));

  // ---- CSR file / interrupt logic --------------------------------------------------
  logic        csr_req, csr_ill, irq_pending, mem_mret, mem_fencei;
  logic [31:0] csr_rdata, irq_cause, trap_target, mepc_o, trap_cause_w, trap_tval_w;

  assign csr_req = exmem_q.valid & exmem_q.ctrl.csr_en;

  // interrupt only between transactions (see header)
  assign irq_take = irq_pending & exmem_q.valid & ~exmem_q.exc & ~dmem_busy;

  // ---- D-cache request ------------------------------------------------------------------
  assign dmem_req      = exmem_q.valid & (mem_is_ld | mem_is_st) & ~exmem_q.exc & ~mem_misalign & ~irq_take;
  assign dmem_we       = mem_is_st;
  assign dmem_addr     = mem_addr;
  assign mem_stall     = dmem_req & ~dmem_ready;
  assign dmem_err_take = dmem_req & dmem_ready & dmem_err;

  // store lane alignment: replicate data, select lanes with byte enables
  always_comb begin
    case (mem_size)
      2'b00:   begin dmem_be = 4'b0001 << mem_addr[1:0];           dmem_wdata = {4{exmem_q.store_data[7:0]}};  end
      2'b01:   begin dmem_be = mem_addr[1] ? 4'b1100 : 4'b0011;    dmem_wdata = {2{exmem_q.store_data[15:0]}}; end
      default: begin dmem_be = 4'b1111;                            dmem_wdata = exmem_q.store_data;            end
    endcase
  end

  // load extraction / sign extension
  logic [7:0]  ld_byte;
  logic [15:0] ld_half;
  logic [31:0] load_data;
  assign ld_byte = dmem_rdata[8*mem_addr[1:0] +: 8];
  assign ld_half = mem_addr[1] ? dmem_rdata[31:16] : dmem_rdata[15:0];
  always_comb begin
    case (exmem_q.funct3)
      3'b000:  load_data = {{24{ld_byte[7]}}, ld_byte};    // LB
      3'b100:  load_data = {24'd0, ld_byte};               // LBU
      3'b001:  load_data = {{16{ld_half[15]}}, ld_half};   // LH
      3'b101:  load_data = {16'd0, ld_half};               // LHU
      default: load_data = dmem_rdata;                     // LW
    endcase
  end

  // ---- exception selection (oldest cause first) ----------------------------------
  logic [3:0]  mexc_cause;
  logic [31:0] mexc_tval;
  logic        mem_exc;
  always_comb begin
    if (exmem_q.exc)          begin mexc_cause = exmem_q.exc_cause; mexc_tval = exmem_q.tval; end
    else if (mem_misalign)    begin mexc_cause = mem_is_st ? CAUSE_STORE_MISALIGNED : CAUSE_LOAD_MISALIGNED; mexc_tval = mem_addr; end
    else if (dmem_err_take)   begin mexc_cause = mem_is_st ? CAUSE_STORE_ACCESS     : CAUSE_LOAD_ACCESS;     mexc_tval = mem_addr; end
    else                      begin mexc_cause = CAUSE_ILLEGAL; mexc_tval = 32'd0; end     // illegal CSR access
  end
  assign mem_exc      = exmem_q.valid & (exmem_q.exc | mem_misalign | dmem_err_take | csr_ill);
  assign trap_take    = mem_exc | irq_take;
  assign trap_cause_w = irq_take ? irq_cause : {28'd0, mexc_cause};
  assign trap_tval_w  = irq_take ? 32'd0     : mexc_tval;

  assign mem_mret   = exmem_q.valid & exmem_q.ctrl.is_mret   & ~trap_take;
  assign mem_fencei = exmem_q.valid & exmem_q.ctrl.is_fencei & ~trap_take;

  assign mem_redirect    = trap_take | mem_mret | mem_fencei;
  assign mem_redirect_pc = trap_take ? trap_target : (mem_mret ? mepc_o : (exmem_q.pc + 32'd4));
  assign imem_inval      = mem_fencei;

  logic retire;
  assign retire = exmem_q.valid & ~mem_stall & ~trap_take;

  csr_file u_csr (
    .clk(clk), .rst_n(rst_n),
    .csr_req(csr_req), .csr_commit(csr_req & ~trap_take),
    .csr_addr(exmem_q.csr_addr), .csr_op(exmem_q.funct3[1:0]),
    .csr_we(exmem_q.csr_we), .csr_wdata(exmem_q.alu_result),
    .csr_rdata(csr_rdata), .csr_illegal(csr_ill),
    .trap_valid(trap_take), .trap_pc(exmem_q.pc),
    .trap_cause(trap_cause_w), .trap_tval(trap_tval_w), .trap_target(trap_target),
    .mret_valid(mem_mret), .mepc_o(mepc_o),
    .irq_msip(irq_msip), .irq_mtip(irq_mtip), .irq_meip(irq_meip),
    .irq_pending(irq_pending), .irq_cause(irq_cause),
    .retire(retire),
    .hpm_evt({evt_dcache_miss, evt_icache_miss, ex_mispred & ~mem_redirect, ex_train})
  );

  // ---- MEM/WB ----------------------------------------------------------------------
  always_comb begin
    memwb_d           = '0;
    memwb_d.reg_write = exmem_q.ctrl.reg_write & exmem_q.valid;    // flushed on mem_stall / trap
    memwb_d.rd        = exmem_q.rd;
    case (exmem_q.ctrl.wb_sel)
      WB_LOAD: memwb_d.data = load_data;
      WB_CSR:  memwb_d.data = csr_rdata;
      default: memwb_d.data = exmem_q.alu_result;
    endcase
  end
  mem_wb_reg u_memwb (.clk(clk), .rst_n(rst_n), .en(1'b1), .flush(memwb_flush), .d(memwb_d), .q(memwb_q));

  // =====================================================================
  // Hazard unit
  // =====================================================================
  hazard_unit u_haz (
    .idex_valid(idex_q.valid),
    .idex_late(idex_q.ctrl.mem_read | idex_q.ctrl.csr_en),
    .idex_rd(idex_q.rd),
    .ifid_valid(ifid_q.valid),
    .ifid_rs1(ifid_q.instr[19:15]), .ifid_rs2(ifid_q.instr[24:20]),
    .ifid_use_rs1(id_ctrl.use_rs1), .ifid_use_rs2(id_ctrl.use_rs2),
    .mem_stall(mem_stall), .ex_busy(ex_busy),
    .ex_redirect(ex_redirect), .mem_redirect(mem_redirect), .trap_take(trap_take),
    .load_use(load_use),
    .pc_hold(pc_hold), .ifid_hold(ifid_hold), .idex_hold(idex_hold), .exmem_hold(exmem_hold),
    .ifid_flush(ifid_flush), .idex_flush(idex_flush), .exmem_flush(exmem_flush), .memwb_flush(memwb_flush)
  );

`ifndef SYNTHESIS
  // ---------------- simulation-only protocol / consistency assertions ----------------
  logic prev_mem_redirect;
  always @(posedge clk) begin
    prev_mem_redirect <= rst_n & mem_redirect;
    if (rst_n) begin
      // a MEM-stage redirect flushes every younger stage
      if (prev_mem_redirect)
        assert (!ifid_q.valid && !idex_q.valid && !exmem_q.valid)
          else $error("core: younger stages not flushed after trap/mret/fence.i");
      // traps never coincide with a pending D-cache stall
      assert (!(mem_stall && trap_take)) else $error("core: trap during D-cache stall");
      // a store request must enable at least one byte lane
      assert (!(dmem_req && dmem_we && dmem_be == 4'b0)) else $error("core: store with empty byte enable");
      // a taken interrupt must never start a memory transaction
      assert (!(irq_take && dmem_req)) else $error("core: request issued with irq_take");
    end
  end
`endif
endmodule
