// =============================================================================
// tb_csr_file.sv - V0..V5 for csr_file.sv
//
// Reference model: an architectural shadow of every implemented CSR, written
// from the RISC-V privileged spec (WARL masks, trap entry/MRET semantics,
// counter behaviour) and updated once per clock from the same inputs.  All
// combinational outputs (csr_rdata, csr_illegal, trap_target, irq_pending,
// irq_cause, mepc_o) are compared every cycle, so every random cycle is a
// full-state scoreboard check.
// =============================================================================
module tb_csr_file import rv32im_pkg::*;;
  `include "tb_common.svh"

  logic clk = 0, rst_n = 0;
  logic        csr_req = 0, csr_commit = 0, csr_we = 0;
  logic [11:0] csr_addr = 0;
  logic [1:0]  csr_op = 0;
  logic [31:0] csr_wdata = 0, csr_rdata;
  logic        csr_illegal;
  logic        trap_valid = 0, mret_valid = 0;
  logic [31:0] trap_pc = 0, trap_cause = 0, trap_tval = 0, trap_target, mepc_o;
  logic        irq_msip = 0, irq_mtip = 0, irq_meip = 0, irq_pending;
  logic [31:0] irq_cause;
  logic        retire = 0;
  logic [3:0]  hpm_evt = 0;

  always #5 clk = ~clk;
  always @(posedge clk) cyc++;

  csr_file dut (.*);

  // ---------------------------------------------------------------- V3 assertions
  // trap entry: MIE cleared and mepc captured on the following cycle
  ap_trap_mie:  assert property (@(posedge clk) disable iff (!rst_n)
                                 trap_valid |=> (dut.mie_q == 1'b0));
  ap_trap_mepc: assert property (@(posedge clk) disable iff (!rst_n)
                                 trap_valid |=> (dut.mepc_q == $past(trap_pc[31:2])));
  ap_trap_mpie: assert property (@(posedge clk) disable iff (!rst_n)
                                 trap_valid |=> (dut.mpie_q == $past(dut.mie_q)));
  ap_mret:      assert property (@(posedge clk) disable iff (!rst_n)
                                 (mret_valid && !trap_valid) |=> (dut.mie_q == $past(dut.mpie_q) && dut.mpie_q));
  // illegal access must never modify state
  ap_illegal_nowrite: assert property (@(posedge clk) disable iff (!rst_n)
                                 (csr_illegal && csr_commit && !trap_valid && !mret_valid) |=>
                                 $stable(dut.mscratch_q) && $stable(dut.mtvec_base));
  // mepc low bits are hard zero
  ap_mepc_align: assert property (@(posedge clk) disable iff (!rst_n) (mepc_o[1:0] == 2'b00));
  // interrupt cause always has the interrupt bit set and a legal code
  ap_irqcause: assert property (@(posedge clk) disable iff (!rst_n)
                                irq_pending |-> (irq_cause[31] && (irq_cause[4:0] inside {3, 7, 11})));

  // ---------------------------------------------------------------- reference model
  bit          m_mie, m_mpie, m_msie, m_mtie, m_meie, m_vec;
  logic [29:0] m_base, m_mepc;
  logic [5:0]  m_mcause;
  logic [31:0] m_mtval, m_mscr;
  logic [63:0] m_cyc, m_inst;
  logic [31:0] m_hpm [4];

  function automatic void mreset();
    m_mie = 0; m_mpie = 0; m_msie = 0; m_mtie = 0; m_meie = 0; m_vec = 0;
    m_base = 0; m_mepc = 0; m_mcause = 0; m_mtval = 0; m_mscr = 0;
    m_cyc = 0; m_inst = 0;
    for (int i = 0; i < 4; i++) m_hpm[i] = 0;
  endfunction

  function automatic bit mknown(input logic [11:0] ad);
    case (ad)
      12'h300, 12'h301, 12'h304, 12'h305, 12'h340, 12'h341, 12'h342, 12'h343, 12'h344,
      12'hB00, 12'hB02, 12'hB03, 12'hB04, 12'hB05, 12'hB06, 12'hB80, 12'hB82,
      12'hC00, 12'hC02, 12'hC80, 12'hC82, 12'hF14: return 1'b1;
      default: return 1'b0;
    endcase
  endfunction

  function automatic logic [31:0] mrd(input logic [11:0] ad);
    case (ad)
      12'h300: return {19'd0, 2'b11, 3'd0, m_mpie, 3'd0, m_mie, 3'd0};
      12'h301: return 32'h4000_1100;
      12'h304: return {20'd0, m_meie, 3'd0, m_mtie, 3'd0, m_msie, 3'd0};
      12'h305: return {m_base, 1'b0, m_vec};
      12'h340: return m_mscr;
      12'h341: return {m_mepc, 2'b00};
      12'h342: return {m_mcause[5], 26'd0, m_mcause[4:0]};
      12'h343: return m_mtval;
      12'h344: return {20'd0, irq_meip, 3'd0, irq_mtip, 3'd0, irq_msip, 3'd0};
      12'hB00, 12'hC00: return m_cyc[31:0];
      12'hB80, 12'hC80: return m_cyc[63:32];
      12'hB02, 12'hC02: return m_inst[31:0];
      12'hB82, 12'hC82: return m_inst[63:32];
      12'hB03: return m_hpm[0];
      12'hB04: return m_hpm[1];
      12'hB05: return m_hpm[2];
      12'hB06: return m_hpm[3];
      default: return 32'd0;                       // incl. mhartid = 0
    endcase
  endfunction

  function automatic logic [31:0] mnew(input logic [1:0] o, input logic [31:0] old, wd);
    case (o)
      2'b01:   return wd;
      2'b10:   return old | wd;
      2'b11:   return old & ~wd;
      default: return old;
    endcase
  endfunction

  function automatic logic [31:0] mtarget(input logic [31:0] cause);
    if (m_vec && cause[31]) return {m_base + 30'(cause[4:0]), 2'b00};
    return {m_base, 2'b00};
  endfunction

  // expected outputs derived from the model state + current inputs
  function automatic bit m_irq_pending();
    return m_mie & ((irq_meip & m_meie) | (irq_mtip & m_mtie) | (irq_msip & m_msie));
  endfunction
  function automatic logic [31:0] m_irq_cause();
    if (irq_meip & m_meie) return 32'h8000_000B;    // MEI first
    if (irq_msip & m_msie) return 32'h8000_0003;    // then MSI
    return 32'h8000_0007;                           // then MTI
  endfunction

  // advance the model by one clock using the current (pre-edge) inputs
  function automatic void mupdate();
    bit          kn, ro, wr;
    logic [31:0] old, nv;
    kn  = mknown(csr_addr);
    ro  = (csr_addr[11:10] == 2'b11);
    wr  = csr_commit && csr_we && kn && !ro;
    old = mrd(csr_addr);
    nv  = mnew(csr_op, old, csr_wdata);
    // counters: free-run, then software write overrides
    m_cyc  = m_cyc + 1;
    m_inst = m_inst + (retire ? 1 : 0);
    for (int i = 0; i < 4; i++) m_hpm[i] = m_hpm[i] + (hpm_evt[i] ? 1 : 0);
    if (wr) begin
      case (csr_addr)
        12'hB00: m_cyc  = {m_cyc[63:32], nv};
        12'hB80: m_cyc  = {nv, m_cyc[31:0]};
        12'hB02: m_inst = {m_inst[63:32], nv};
        12'hB82: m_inst = {nv, m_inst[31:0]};
        12'hB03: m_hpm[0] = nv;
        12'hB04: m_hpm[1] = nv;
        12'hB05: m_hpm[2] = nv;
        12'hB06: m_hpm[3] = nv;
        default: ;
      endcase
    end
    // trap / mret / csr-write on the status group
    if (trap_valid) begin
      m_mepc   = trap_pc[31:2];
      m_mcause = {trap_cause[31], trap_cause[4:0]};
      m_mtval  = trap_tval;
      m_mpie   = m_mie;
      m_mie    = 0;
    end else if (mret_valid) begin
      m_mie  = m_mpie;
      m_mpie = 1;
    end else if (wr) begin
      case (csr_addr)
        12'h300: begin m_mie = nv[3]; m_mpie = nv[7]; end
        12'h304: begin m_msie = nv[3]; m_mtie = nv[7]; m_meie = nv[11]; end
        12'h305: begin m_base = nv[31:2]; m_vec = nv[0]; end
        12'h340: m_mscr = nv;
        12'h341: m_mepc = nv[31:2];
        12'h342: m_mcause = {nv[31], nv[4:0]};
        12'h343: m_mtval = nv;
        default: ;                                   // misa/mip/RO: WARL ignore
      endcase
    end
  endfunction

  // ---------------------------------------------------------------- one cycle
  // Caller sets inputs at negedge; step checks, advances the model, returns at negedge.
  task automatic step(input bit is_rand);
    logic [31:0] e_rd;
    bit          e_ill, kn, ro;
    kn    = mknown(csr_addr);
    ro    = (csr_addr[11:10] == 2'b11);
    e_ill = csr_req && (!kn || (csr_we && ro));
    e_rd  = mrd(csr_addr);
    #1;
    // functional coverage
    if (csr_req && kn && !e_ill) cov_hit(0);
    if (e_ill)                    cov_hit(1);
    if (csr_req && csr_commit && csr_we && kn && !ro) cov_hit(2);
    if (trap_valid && !trap_cause[31]) cov_hit(3);
    if (trap_valid &&  trap_cause[31]) cov_hit(4);
    if (mret_valid)               cov_hit(5);
    if (m_vec && trap_cause[31])  cov_hit(6);
    if (m_irq_pending())          cov_hit(7);
    if (irq_meip && m_meie && m_mie) cov_hit(8);
    if (irq_msip && m_msie && m_mie && !(irq_meip && m_meie)) cov_hit(9);
    if (irq_mtip && m_mtie && m_mie && !(irq_meip && m_meie) && !(irq_msip && m_msie)) cov_hit(10);
    if (retire)                   cov_hit(11);
    if (|hpm_evt)                 cov_hit(12);
    if (csr_req && csr_commit && csr_we && (csr_addr inside {12'hB00,12'hB02,12'hB03,12'hB04,12'hB05,12'hB06})) cov_hit(13);
    if (csr_req && csr_op == 2'b01) cov_hit(14);
    if (csr_req && csr_op == 2'b10) cov_hit(15);
    if (csr_req && csr_op == 2'b11) cov_hit(16);
    if (csr_req && !csr_we && kn) cov_hit(17);      // read-only CSR access (no write)
    // ---- scoreboard compare of every combinational output
    if (is_rand) begin
      if (csr_req && kn) rchk("rdata", {32'd0, e_rd}, {32'd0, csr_rdata});
      rchk("illegal",  {63'd0, e_ill},              {63'd0, csr_illegal});
      rchk("target",   {32'd0, mtarget(trap_cause)},{32'd0, trap_target});
      rchk("irq_pend", {63'd0, m_irq_pending()},    {63'd0, irq_pending});
      if (m_irq_pending()) rchk("irq_cause", {32'd0, m_irq_cause()}, {32'd0, irq_cause});
      rchk("mepc",     {32'd0, {m_mepc, 2'b00}},    {32'd0, mepc_o});
    end else begin
      if (csr_req && kn) chk($sformatf("rdata@%03h", csr_addr), {32'd0, e_rd}, {32'd0, csr_rdata});
      chk("illegal",   {63'd0, e_ill},              {63'd0, csr_illegal});
      chk("target",    {32'd0, mtarget(trap_cause)},{32'd0, trap_target});
      chk("irq_pend",  {63'd0, m_irq_pending()},    {63'd0, irq_pending});
      if (m_irq_pending()) chk("irq_cause", {32'd0, m_irq_cause()}, {32'd0, irq_cause});
      chk("mepc",      {32'd0, {m_mepc, 2'b00}},    {32'd0, mepc_o});
    end
    mupdate();
    @(posedge clk);
    @(negedge clk);
  endtask

  task automatic idle_in();
    csr_req = 0; csr_commit = 0; csr_we = 0; csr_addr = 0; csr_op = 0; csr_wdata = 0;
    trap_valid = 0; mret_valid = 0; retire = 0; hpm_evt = 0;
  endtask

  // ---- convenience: one CSR access -------------------------------------------------
  task automatic csr_acc(input logic [11:0] ad, input logic [1:0] o, input logic [31:0] wd,
                         input bit we);
    idle_in();
    csr_req = 1; csr_commit = 1; csr_addr = ad; csr_op = o; csr_wdata = wd; csr_we = we;
    step(0);
    idle_in();
  endtask

  task automatic do_trap(input logic [31:0] pc, cause, tval);
    idle_in();
    trap_valid = 1; trap_pc = pc; trap_cause = cause; trap_tval = tval;
    step(0);
    idle_in();
  endtask

  logic [11:0] known_addrs [21];
  logic [11:0] rw_addrs [8];

  initial begin
    tb_init("csr_file");
    cov_def(0,"legal_csr_access"); cov_def(1,"illegal_access"); cov_def(2,"csr_write_committed");
    cov_def(3,"trap_exception"); cov_def(4,"trap_interrupt"); cov_def(5,"mret");
    cov_def(6,"vectored_irq_target"); cov_def(7,"irq_pending"); cov_def(8,"irq_MEI");
    cov_def(9,"irq_MSI"); cov_def(10,"irq_MTI"); cov_def(11,"retire"); cov_def(12,"hpm_event");
    cov_def(13,"counter_sw_write"); cov_def(14,"op_RW"); cov_def(15,"op_RS"); cov_def(16,"op_RC");
    cov_def(17,"read_only_access");

    known_addrs = '{12'h300,12'h301,12'h304,12'h305,12'h340,12'h341,12'h342,12'h343,12'h344,
                    12'hB00,12'hB02,12'hB03,12'hB04,12'hB05,12'hB06,12'hB80,12'hB82,
                    12'hC00,12'hC02,12'hC80,12'hC82};
    rw_addrs    = '{12'h300,12'h304,12'h305,12'h340,12'h341,12'h342,12'h343,12'hB03};

    // ---- V1: reset values ---------------------------------------------------------
    mreset();
    idle_in();
    repeat (3) @(negedge clk);
    // DUT and model counters are both 0 at release; each step below advances both once
    rst_n = 1;
    for (int i = 0; i < 21; i++)
      csr_acc(known_addrs[i], 2'b10, 32'd0, 1'b0);    // read (CSRRS x0) - checks reset values
    chk("reset_mstatus_MPP", 64'h0000_1800, {32'd0, mrd(12'h300)});
    chk("reset_misa",        64'h4000_1100, {32'd0, mrd(12'h301)});

    // ---- V1: read/write every implemented CSR with RW / RS / RC ------------------
    csr_acc(12'h340, 2'b01, 32'hDEAD_BEEF, 1);       // mscratch RW
    csr_acc(12'h340, 2'b10, 32'h0000_FFFF, 1);       // RS sets low half
    csr_acc(12'h340, 2'b11, 32'h0000_00FF, 1);       // RC clears low byte
    csr_acc(12'h340, 2'b10, 32'h0,         0);       // RS with zero operand: read, no write
    csr_acc(12'h305, 2'b01, 32'h8000_0101, 1);       // mtvec: bit1 hard zero, bit0 = vectored
    csr_acc(12'h305, 2'b01, 32'h0000_0FFC, 1);       // direct mode
    csr_acc(12'h341, 2'b01, 32'hFFFF_FFFF, 1);       // mepc: low 2 bits hard zero
    csr_acc(12'h342, 2'b01, 32'hFFFF_FFFF, 1);       // mcause WLRL storage
    csr_acc(12'h343, 2'b01, 32'h1234_5678, 1);       // mtval
    csr_acc(12'h300, 2'b01, 32'hFFFF_FFFF, 1);       // mstatus: only MIE/MPIE writable, MPP fixed
    csr_acc(12'h300, 2'b11, 32'hFFFF_FFFF, 1);       // clear everything writable
    csr_acc(12'h304, 2'b01, 32'hFFFF_FFFF, 1);       // mie: only bits 3/7/11
    csr_acc(12'h304, 2'b01, 32'h0000_0000, 1);
    csr_acc(12'h301, 2'b01, 32'h0000_0000, 1);       // misa write ignored (WARL)
    csr_acc(12'h344, 2'b01, 32'hFFFF_FFFF, 1);       // mip write ignored (read-only view)

    // ---- V1: illegal accesses -------------------------------------------------------
    csr_acc(12'h7C0, 2'b01, 32'd1, 1);               // unknown CSR write
    csr_acc(12'h7C0, 2'b10, 32'd0, 0);               // unknown CSR read
    csr_acc(12'h100, 2'b10, 32'd0, 0);               // sstatus not implemented (M-only)
    csr_acc(12'h001, 2'b10, 32'd0, 0);               // fflags not implemented (no F)
    csr_acc(12'hF11, 2'b10, 32'd0, 0);               // mvendorid not implemented
    csr_acc(12'hC00, 2'b01, 32'd5, 1);               // write to read-only cycle
    csr_acc(12'hC02, 2'b11, 32'd5, 1);               // write to read-only instret
    csr_acc(12'hF14, 2'b01, 32'd1, 1);               // write to read-only mhartid
    csr_acc(12'hC00, 2'b10, 32'd0, 0);               // read of read-only CSR is legal
    csr_acc(12'hF14, 2'b10, 32'd0, 0);               // mhartid read = 0

    // ---- V1: trap entry, MIE/MPIE, MRET --------------------------------------------
    csr_acc(12'h300, 2'b10, 32'h0000_0008, 1);       // MIE = 1
    do_trap(32'h0000_1234, 32'h0000_0002, 32'hBAD0_0002);     // illegal instruction
    csr_acc(12'h342, 2'b10, 32'd0, 0);               // mcause
    csr_acc(12'h341, 2'b10, 32'd0, 0);               // mepc
    csr_acc(12'h343, 2'b10, 32'd0, 0);               // mtval
    csr_acc(12'h300, 2'b10, 32'd0, 0);               // MIE=0, MPIE=1
    idle_in(); mret_valid = 1; step(0); idle_in();   // MRET: MIE <- MPIE, MPIE <- 1
    csr_acc(12'h300, 2'b10, 32'd0, 0);
    do_trap(32'h0000_4000, 32'h8000_0007, 32'd0);    // interrupt (MTI cause)
    do_trap(32'h0000_5000, 32'h0000_000B, 32'd0);    // ECALL from M while MIE already 0 (MPIE<-0)
    csr_acc(12'h300, 2'b10, 32'd0, 0);
    // trap_target: direct and vectored
    csr_acc(12'h305, 2'b01, 32'h0000_2000, 1);
    idle_in(); trap_cause = 32'h8000_0007; step(0);  // direct: base only
    csr_acc(12'h305, 2'b01, 32'h0000_2001, 1);       // vectored
    idle_in(); trap_cause = 32'h8000_0007; step(0);  // base + 4*7
    idle_in(); trap_cause = 32'h8000_000B; step(0);  // base + 4*11
    idle_in(); trap_cause = 32'h0000_0002; step(0);  // exceptions never vector
    // ---- V1: interrupt gating and priority ------------------------------------------
    csr_acc(12'h304, 2'b01, 32'h0000_0888, 1);       // enable MSIE|MTIE|MEIE
    csr_acc(12'h300, 2'b01, 32'h0000_0008, 1);       // MIE = 1
    idle_in(); irq_mtip = 1; step(0);                // MTI only
    idle_in(); irq_mtip = 1; irq_msip = 1; step(0);  // MSI beats MTI
    idle_in(); irq_mtip = 1; irq_msip = 1; irq_meip = 1; step(0);   // MEI beats both
    csr_acc(12'h300, 2'b11, 32'h0000_0008, 1);       // MIE = 0 -> masked even with lines high
    irq_mtip = 1; irq_msip = 1; irq_meip = 1; idle_in(); irq_mtip = 1; irq_msip = 1; irq_meip = 1; step(0);
    irq_mtip = 0; irq_msip = 0; irq_meip = 0;
    csr_acc(12'h300, 2'b10, 32'h0000_0008, 1);
    csr_acc(12'h304, 2'b11, 32'h0000_0080, 1);       // mask MTIE only
    idle_in(); irq_mtip = 1; step(0);                // pending line but masked
    csr_acc(12'h344, 2'b10, 32'd0, 0);               // mip still shows the raw line
    irq_mtip = 0;

    // ---- V1: performance counters -----------------------------------------------------
    csr_acc(12'hB02, 2'b01, 32'd0, 1);               // zero instret
    for (int i = 0; i < 5; i++) begin idle_in(); retire = 1; step(0); end
    csr_acc(12'hB02, 2'b10, 32'd0, 0);               // reads 5 (+ model check)
    csr_acc(12'hB03, 2'b01, 32'd0, 1);
    for (int i = 0; i < 4; i++) begin idle_in(); hpm_evt = 4'b0001; step(0); end
    for (int i = 0; i < 3; i++) begin idle_in(); hpm_evt = 4'b1010; step(0); end
    for (int i = 0; i < 2; i++) begin idle_in(); hpm_evt = 4'b1111; step(0); end
    csr_acc(12'hB03, 2'b10, 32'd0, 0);
    csr_acc(12'hB04, 2'b10, 32'd0, 0);
    csr_acc(12'hB05, 2'b10, 32'd0, 0);
    csr_acc(12'hB06, 2'b10, 32'd0, 0);
    csr_acc(12'hB80, 2'b10, 32'd0, 0);               // mcycleh
    csr_acc(12'hB00, 2'b01, 32'hFFFF_FFFE, 1);       // force mcycle low word near wrap
    for (int i = 0; i < 4; i++) begin idle_in(); step(0); end   // carry into mcycleh
    csr_acc(12'hB80, 2'b10, 32'd0, 0);
    csr_acc(12'hC80, 2'b10, 32'd0, 0);               // shadow read of high word
    csr_acc(12'hB82, 2'b01, 32'h0000_0007, 1);       // write instreth
    csr_acc(12'hC82, 2'b10, 32'd0, 0);

    // ---- V2/V5: 110 randomized cycles, full scoreboard --------------------------------
    for (int i = 0; i < 110; i++) begin
      idle_in();
      if ($urandom_range(0, 9) < 7) begin
        csr_req = 1;
        csr_addr = ($urandom_range(0, 9) == 0) ? 12'($urandom()) :
                   ($urandom_range(0, 1) ? rw_addrs[$urandom_range(0, 7)]
                                         : known_addrs[$urandom_range(0, 20)]);
        csr_op   = 2'($urandom_range(1, 3));
        csr_we   = (csr_op == 2'b01) ? 1'b1 : ($urandom_range(0, 3) != 0);
        csr_wdata = ($urandom_range(0, 3) == 0) ? 32'h0000_0888 :
                    ($urandom_range(0, 3) == 0) ? 32'h0000_0088 : $urandom();
        csr_commit = ($urandom_range(0, 9) != 0);
      end
      if ($urandom_range(0, 9) == 0) begin           // trap (never together with a commit)
        trap_valid = 1; csr_commit = 0; trap_pc = $urandom();
        trap_cause = ($urandom_range(0, 1) ? 32'h8000_0000 : 32'd0) | 32'($urandom_range(0, 11));
        trap_tval = $urandom();
      end else if ($urandom_range(0, 9) == 0) begin  // mret
        mret_valid = 1; csr_commit = 0;
      end
      if (!trap_valid) trap_cause = ($urandom_range(0, 1) ? 32'h8000_0000 : 32'd0) | 32'($urandom_range(0, 11));
      irq_msip = ($urandom_range(0, 2) == 0);
      irq_mtip = ($urandom_range(0, 2) == 0);
      irq_meip = ($urandom_range(0, 2) == 0);
      retire   = ($urandom_range(0, 9) < 7);
      hpm_evt  = 4'($urandom());
      step(1);
    end

    finish_report();
    $finish;
  end
endmodule
