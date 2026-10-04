// =============================================================================
// csr_file.sv - machine-mode CSRs, trap entry/return, interrupt gating, counters
//
// Implemented: mstatus(MIE,MPIE,MPP=11) misa mie mtvec(direct/vectored) mscratch
//   mepc mcause mtval mip(ro) mcycle[h] minstret[h] mhpmcounter3..6 (custom events)
//   + read-only shadows cycle[h]/instret[h] and mhartid.
// M-mode only.  Unknown CSR or write to a read-only CSR (addr[11:10]==11)
// => csr_illegal (core raises illegal-instruction, mtval = 0).
// Called from the MEM stage so CSR side effects are never speculative.
//
// hpm event map: bit0 branches/jumps resolved, bit1 mispredicts,
//                bit2 I$ miss, bit3 D$ miss
// =============================================================================
module csr_file import rv32im_pkg::*; (
  input  logic        clk,
  input  logic        rst_n,
  // CSR instruction port
  input  logic        csr_req,       // valid CSR instruction in MEM
  input  logic        csr_commit,    // it retires (no trap) -> perform the write
  input  logic [11:0] csr_addr,
  input  logic [1:0]  csr_op,        // 01 RW, 10 RS, 11 RC
  input  logic        csr_we,        // instruction actually writes (RS/RC with rs1=x0 do not)
  input  logic [31:0] csr_wdata,
  output logic [31:0] csr_rdata,
  output logic        csr_illegal,
  // trap entry / return
  input  logic        trap_valid,
  input  logic [31:0] trap_pc,
  input  logic [31:0] trap_cause,    // {irq, ..., code}
  input  logic [31:0] trap_tval,
  output logic [31:0] trap_target,   // mtvec (+4*cause when vectored irq)
  input  logic        mret_valid,
  output logic [31:0] mepc_o,
  // interrupts
  input  logic        irq_msip,
  input  logic        irq_mtip,
  input  logic        irq_meip,
  output logic        irq_pending,   // enabled & pending & mstatus.MIE
  output logic [31:0] irq_cause,
  // counters
  input  logic        retire,
  input  logic [3:0]  hpm_evt
);
  // ---------------------------------------------------------------- state
  logic        mie_q, mpie_q;                  // mstatus.MIE / MPIE
  logic        msie_q, mtie_q, meie_q;         // mie bits 3/7/11
  logic [29:0] mtvec_base;                     // mtvec[31:2]
  logic        mtvec_vec;                      // mtvec[0] (vectored mode)
  logic [29:0] mepc_q;                         // mepc[31:2]
  logic [5:0]  mcause_q;                       // {interrupt, code[4:0]}
  logic [31:0] mtval_q, mscratch_q;
  logic [63:0] mcycle_q, minstret_q;
  logic [31:0] hpm_q [4];

  // ---------------------------------------------------------------- read mux
  logic [31:0] mstatus_v, mie_v, mip_v;
  logic        known;
  assign mstatus_v = {19'd0, 2'b11, 3'd0, mpie_q, 3'd0, mie_q, 3'd0};
  assign mie_v     = {20'd0, meie_q, 3'd0, mtie_q, 3'd0, msie_q, 3'd0};
  assign mip_v     = {20'd0, irq_meip, 3'd0, irq_mtip, 3'd0, irq_msip, 3'd0};

  always_comb begin
    known     = 1'b1;
    csr_rdata = 32'd0;
    case (csr_addr)
      CSR_MSTATUS:                 csr_rdata = mstatus_v;
      CSR_MISA:                    csr_rdata = 32'h4000_1100;             // RV32 I+M
      CSR_MIE:                     csr_rdata = mie_v;
      CSR_MTVEC:                   csr_rdata = {mtvec_base, 1'b0, mtvec_vec};
      CSR_MSCRATCH:                csr_rdata = mscratch_q;
      CSR_MEPC:                    csr_rdata = {mepc_q, 2'b00};
      CSR_MCAUSE:                  csr_rdata = {mcause_q[5], 26'd0, mcause_q[4:0]};
      CSR_MTVAL:                   csr_rdata = mtval_q;
      CSR_MIP:                     csr_rdata = mip_v;
      CSR_MCYCLE,   CSR_CYCLE:     csr_rdata = mcycle_q[31:0];
      CSR_MCYCLEH,  CSR_CYCLEH:    csr_rdata = mcycle_q[63:32];
      CSR_MINSTRET, CSR_INSTRET:   csr_rdata = minstret_q[31:0];
      CSR_MINSTRETH,CSR_INSTRETH:  csr_rdata = minstret_q[63:32];
      CSR_MHPM3:                   csr_rdata = hpm_q[0];
      CSR_MHPM4:                   csr_rdata = hpm_q[1];
      CSR_MHPM5:                   csr_rdata = hpm_q[2];
      CSR_MHPM6:                   csr_rdata = hpm_q[3];
      CSR_MHARTID:                 csr_rdata = 32'd0;
      default:                     known = 1'b0;
    endcase
  end

  // ---------------------------------------------------------------- write value / legality
  logic [31:0] nv;
  logic        read_only, wr_fire;
  always_comb begin
    case (csr_op)
      2'b01:   nv = csr_wdata;
      2'b10:   nv = csr_rdata |  csr_wdata;
      2'b11:   nv = csr_rdata & ~csr_wdata;
      default: nv = csr_rdata;
    endcase
  end
  assign read_only   = (csr_addr[11:10] == 2'b11);
  assign csr_illegal = csr_req & (~known | (csr_we & read_only));   // independent of csr_commit
  assign wr_fire     = csr_commit & csr_we & known & ~read_only;

  // ---------------------------------------------------------------- trap target / interrupts
  assign trap_target = (mtvec_vec & trap_cause[31])
                     ? {mtvec_base + {25'd0, trap_cause[4:0]}, 2'b00}
                     : {mtvec_base, 2'b00};
  assign mepc_o = {mepc_q, 2'b00};

  logic [2:0] pend;                                  // {MEI, MTI, MSI} pending & enabled
  assign pend        = {irq_meip & meie_q, irq_mtip & mtie_q, irq_msip & msie_q};
  assign irq_pending = mie_q & (|pend);
  always_comb begin                                  // priority: MEI > MSI > MTI
    if (pend[2])      irq_cause = {1'b1, 27'd0, 4'd11};
    else if (pend[0]) irq_cause = {1'b1, 27'd0, 4'd3};
    else              irq_cause = {1'b1, 27'd0, 4'd7};
  end

  // ---------------------------------------------------------------- status / trap registers
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      mie_q <= 1'b0;  mpie_q <= 1'b0;
      msie_q <= 1'b0; mtie_q <= 1'b0; meie_q <= 1'b0;
      mtvec_base <= 30'd0; mtvec_vec <= 1'b0;
      mepc_q <= 30'd0; mcause_q <= 6'd0; mtval_q <= 32'd0; mscratch_q <= 32'd0;
    end else if (trap_valid) begin                   // trap entry (highest priority)
      mepc_q   <= trap_pc[31:2];
      mcause_q <= {trap_cause[31], trap_cause[4:0]};
      mtval_q  <= trap_tval;
      mpie_q   <= mie_q;
      mie_q    <= 1'b0;
    end else if (mret_valid) begin                   // MRET
      mie_q  <= mpie_q;
      mpie_q <= 1'b1;
    end else if (wr_fire) begin
      case (csr_addr)
        CSR_MSTATUS:  begin mie_q <= nv[3]; mpie_q <= nv[7]; end
        CSR_MIE:      begin msie_q <= nv[3]; mtie_q <= nv[7]; meie_q <= nv[11]; end
        CSR_MTVEC:    begin mtvec_base <= nv[31:2]; mtvec_vec <= nv[0]; end
        CSR_MSCRATCH: mscratch_q <= nv;
        CSR_MEPC:     mepc_q <= nv[31:2];
        CSR_MCAUSE:   mcause_q <= {nv[31], nv[4:0]};
        CSR_MTVAL:    mtval_q <= nv;
        default: ;
      endcase
    end
  end

  // ---------------------------------------------------------------- counters
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      mcycle_q <= 64'd0; minstret_q <= 64'd0;
      for (int i = 0; i < 4; i++) hpm_q[i] <= 32'd0;
    end else begin
      mcycle_q   <= mcycle_q + 64'd1;
      minstret_q <= minstret_q + {63'd0, retire};
      for (int i = 0; i < 4; i++) hpm_q[i] <= hpm_q[i] + {31'd0, hpm_evt[i]};
      if (wr_fire) begin                             // software writes override the increment
        case (csr_addr)
          CSR_MCYCLE:    mcycle_q   <= {mcycle_q[63:32], nv};
          CSR_MCYCLEH:   mcycle_q   <= {nv, mcycle_q[31:0]};
          CSR_MINSTRET:  minstret_q <= {minstret_q[63:32], nv};
          CSR_MINSTRETH: minstret_q <= {nv, minstret_q[31:0]};
          CSR_MHPM3:     hpm_q[0] <= nv;
          CSR_MHPM4:     hpm_q[1] <= nv;
          CSR_MHPM5:     hpm_q[2] <= nv;
          CSR_MHPM6:     hpm_q[3] <= nv;
          default: ;
        endcase
      end
    end
  end

`ifndef SYNTHESIS
  // trap entry must save pc, cause and clear MIE
  logic        chk_trap_q;
  logic [29:0] chk_pc_q;
  always @(posedge clk) begin
    chk_trap_q <= rst_n & trap_valid;
    chk_pc_q   <= trap_pc[31:2];
    if (rst_n && chk_trap_q) begin       // RTL FIX #2: ignore uninitialised state during reset
      assert (mepc_q == chk_pc_q) else $error("csr: mepc not captured on trap");
      assert (mie_q == 1'b0)      else $error("csr: MIE not cleared on trap");
    end
  end
`endif
endmodule
