// =============================================================================
// tb_decoder.sv - V0..V5 for decoder.sv
//
// Reference model: a table of (mask, match) pairs taken from the RISC-V spec
// opcode listing, plus a per-mnemonic expected control set.  Structurally
// independent of the DUT (which decodes with nested case statements).
// Any instruction matching no table entry must decode as illegal with all
// side-effect controls cleared.
// =============================================================================
module tb_decoder import rv32im_pkg::*;;
  `include "tb_common.svh"

  logic clk = 0;
  logic [31:0] instr;
  ctrl_t       ctrl;

  always #5 clk = ~clk;
  always @(posedge clk) cyc++;

  decoder dut (.instr(instr), .ctrl(ctrl));

  // ---- instruction table ------------------------------------------------------
  // kind codes
  localparam int K_RALU=0, K_IALU=1, K_LOAD=2, K_STORE=3, K_BR=4, K_JAL=5, K_JALR=6,
                 K_LUI=7, K_AUIPC=8, K_MD=9, K_CSR=10, K_ECALL=11, K_EBREAK=12,
                 K_MRET=13, K_WFI=14, K_FENCE=15, K_FENCEI=16;

  typedef struct {
    logic [31:0] mask;
    logic [31:0] match;
    int          kind;
    int          aop;            // alu_op for K_RALU/K_IALU, else -1
  } ent_t;

  ent_t  tbl  [64];
  string tnam [64];            // names kept out of the struct (Verilator codegen)
  int    ntbl = 0;

  function automatic void add(input logic [31:0] msk, mch, input int k, aop, input string nm);
    tbl[ntbl]  = '{msk, mch, k, aop};
    tnam[ntbl] = nm;
    ntbl++;
  endfunction

  function automatic void build_table();
    // R-type ALU: mask funct7+funct3+opcode
    add(32'hFE00707F, 32'h00000033, K_RALU, int'(ALU_ADD),  "ADD");
    add(32'hFE00707F, 32'h40000033, K_RALU, int'(ALU_SUB),  "SUB");
    add(32'hFE00707F, 32'h00001033, K_RALU, int'(ALU_SLL),  "SLL");
    add(32'hFE00707F, 32'h00002033, K_RALU, int'(ALU_SLT),  "SLT");
    add(32'hFE00707F, 32'h00003033, K_RALU, int'(ALU_SLTU), "SLTU");
    add(32'hFE00707F, 32'h00004033, K_RALU, int'(ALU_XOR),  "XOR");
    add(32'hFE00707F, 32'h00005033, K_RALU, int'(ALU_SRL),  "SRL");
    add(32'hFE00707F, 32'h40005033, K_RALU, int'(ALU_SRA),  "SRA");
    add(32'hFE00707F, 32'h00006033, K_RALU, int'(ALU_OR),   "OR");
    add(32'hFE00707F, 32'h00007033, K_RALU, int'(ALU_AND),  "AND");
    // M extension (funct7 = 0000001)
    for (int f3 = 0; f3 < 8; f3++)
      add(32'hFE00707F, 32'h02000033 | (32'(f3) << 12), K_MD, -1, "MD");
    // I-type ALU
    add(32'h0000707F, 32'h00000013, K_IALU, int'(ALU_ADD),  "ADDI");
    add(32'h0000707F, 32'h00002013, K_IALU, int'(ALU_SLT),  "SLTI");
    add(32'h0000707F, 32'h00003013, K_IALU, int'(ALU_SLTU), "SLTIU");
    add(32'h0000707F, 32'h00004013, K_IALU, int'(ALU_XOR),  "XORI");
    add(32'h0000707F, 32'h00006013, K_IALU, int'(ALU_OR),   "ORI");
    add(32'h0000707F, 32'h00007013, K_IALU, int'(ALU_AND),  "ANDI");
    add(32'hFE00707F, 32'h00001013, K_IALU, int'(ALU_SLL),  "SLLI");
    add(32'hFE00707F, 32'h00005013, K_IALU, int'(ALU_SRL),  "SRLI");
    add(32'hFE00707F, 32'h40005013, K_IALU, int'(ALU_SRA),  "SRAI");
    // loads / stores
    add(32'h0000707F, 32'h00000003, K_LOAD, -1, "LB");
    add(32'h0000707F, 32'h00001003, K_LOAD, -1, "LH");
    add(32'h0000707F, 32'h00002003, K_LOAD, -1, "LW");
    add(32'h0000707F, 32'h00004003, K_LOAD, -1, "LBU");
    add(32'h0000707F, 32'h00005003, K_LOAD, -1, "LHU");
    add(32'h0000707F, 32'h00000023, K_STORE, -1, "SB");
    add(32'h0000707F, 32'h00001023, K_STORE, -1, "SH");
    add(32'h0000707F, 32'h00002023, K_STORE, -1, "SW");
    // branches
    add(32'h0000707F, 32'h00000063, K_BR, -1, "BEQ");
    add(32'h0000707F, 32'h00001063, K_BR, -1, "BNE");
    add(32'h0000707F, 32'h00004063, K_BR, -1, "BLT");
    add(32'h0000707F, 32'h00005063, K_BR, -1, "BGE");
    add(32'h0000707F, 32'h00006063, K_BR, -1, "BLTU");
    add(32'h0000707F, 32'h00007063, K_BR, -1, "BGEU");
    // jumps / upper immediates
    add(32'h0000007F, 32'h0000006F, K_JAL,   -1, "JAL");
    add(32'h0000707F, 32'h00000067, K_JALR,  -1, "JALR");
    add(32'h0000007F, 32'h00000037, K_LUI,   -1, "LUI");
    add(32'h0000007F, 32'h00000017, K_AUIPC, -1, "AUIPC");
    // system
    add(32'hFFFFFFFF, 32'h00000073, K_ECALL,  -1, "ECALL");
    add(32'hFFFFFFFF, 32'h00100073, K_EBREAK, -1, "EBREAK");
    add(32'hFFFFFFFF, 32'h30200073, K_MRET,   -1, "MRET");
    add(32'hFFFFFFFF, 32'h10500073, K_WFI,    -1, "WFI");
    add(32'h0000707F, 32'h00001073, K_CSR, -1, "CSRRW");
    add(32'h0000707F, 32'h00002073, K_CSR, -1, "CSRRS");
    add(32'h0000707F, 32'h00003073, K_CSR, -1, "CSRRC");
    add(32'h0000707F, 32'h00005073, K_CSR, -1, "CSRRWI");
    add(32'h0000707F, 32'h00006073, K_CSR, -1, "CSRRSI");
    add(32'h0000707F, 32'h00007073, K_CSR, -1, "CSRRCI");
    // fences
    add(32'h0000707F, 32'h0000000F, K_FENCE,  -1, "FENCE");
    add(32'h0000707F, 32'h0000100F, K_FENCEI, -1, "FENCE.I");
  endfunction

  // ---- expected control bundle for a matched entry -----------------------------
  function automatic ctrl_t ref_ctrl(input logic [31:0] ins);
    ctrl_t c;
    int    k = -1, aop = -1;
    c = '0;
    if (ins[1:0] != 2'b11) begin c.illegal = 1'b1; return c; end
    for (int i = 0; i < ntbl; i++)
      if (((ins & tbl[i].mask) == tbl[i].match) && k == -1) begin
        k = tbl[i].kind; aop = tbl[i].aop;
      end
    if (k == -1) begin c.illegal = 1'b1; return c; end
    case (k)
      K_RALU: begin c.reg_write=1; c.use_rs1=1; c.use_rs2=1; c.alu_op=alu_op_e'(aop); end
      K_IALU: begin c.reg_write=1; c.use_rs1=1; c.op_b_imm=1; c.alu_op=alu_op_e'(aop); end
      K_MD:   begin c.reg_write=1; c.use_rs1=1; c.use_rs2=1; c.is_md=1; end
      K_LOAD: begin c.reg_write=1; c.use_rs1=1; c.op_b_imm=1; c.mem_read=1; c.wb_sel=WB_LOAD; end
      K_STORE:begin c.use_rs1=1; c.use_rs2=1; c.op_b_imm=1; c.mem_write=1; end
      K_BR:   begin c.use_rs1=1; c.use_rs2=1; c.is_branch=1; end
      K_JAL:  begin c.reg_write=1; c.is_jal=1; end
      K_JALR: begin c.reg_write=1; c.use_rs1=1; c.op_b_imm=1; c.is_jalr=1; end
      K_LUI:  begin c.reg_write=1; c.op_a_sel=A_ZERO; c.op_b_imm=1; end
      K_AUIPC:begin c.reg_write=1; c.op_a_sel=A_PC;   c.op_b_imm=1; end
      K_CSR:  begin c.reg_write=1; c.csr_en=1; c.wb_sel=WB_CSR; c.use_rs1=~ins[14]; end
      K_ECALL:  c.is_ecall  = 1'b1;
      K_EBREAK: c.is_ebreak = 1'b1;
      K_MRET:   c.is_mret   = 1'b1;
      K_FENCEI: c.is_fencei = 1'b1;
      default: ;                                     // K_WFI, K_FENCE decode as NOP
    endcase
    return c;
  endfunction

  task automatic apply(input logic [31:0] ins, input bit is_rand, input string nm);
    ctrl_t e;
    instr = ins;
    #1;
    e = ref_ctrl(ins);
    if (e.illegal)    cov_hit(0); else cov_hit(1);
    if (e.reg_write)  cov_hit(2);
    if (e.mem_read)   cov_hit(3);
    if (e.mem_write)  cov_hit(4);
    if (e.is_branch)  cov_hit(5);
    if (e.is_jal)     cov_hit(6);
    if (e.is_jalr)    cov_hit(7);
    if (e.is_md)      cov_hit(8);
    if (e.csr_en)     cov_hit(9);
    if (e.is_mret)    cov_hit(10);
    if (e.is_fencei)  cov_hit(11);
    if (e.is_ecall)   cov_hit(12);
    if (e.is_ebreak)  cov_hit(13);
    if (e.op_b_imm)   cov_hit(14);
    if (is_rand) rchk($sformatf("instr=%08h", ins), {{(64-$bits(ctrl_t)){1'b0}}, e},
                                                    {{(64-$bits(ctrl_t)){1'b0}}, ctrl});
    else         chk(nm, {{(64-$bits(ctrl_t)){1'b0}}, e}, {{(64-$bits(ctrl_t)){1'b0}}, ctrl});
    @(posedge clk);
  endtask

  initial begin
    tb_init("decoder");
    cov_def(0,"illegal"); cov_def(1,"legal"); cov_def(2,"reg_write"); cov_def(3,"mem_read");
    cov_def(4,"mem_write"); cov_def(5,"branch"); cov_def(6,"jal"); cov_def(7,"jalr");
    cov_def(8,"m_extension"); cov_def(9,"csr"); cov_def(10,"mret"); cov_def(11,"fence_i");
    cov_def(12,"ecall"); cov_def(13,"ebreak"); cov_def(14,"imm_operand");
    build_table();

    // -------- V1 directed: every table entry, with random rs/rd/imm filler -------
    for (int i = 0; i < ntbl; i++)
      for (int rep = 0; rep < 3; rep++) begin
        logic [31:0] ins = tbl[i].match | ($urandom() & ~tbl[i].mask);
        apply(ins, 0, tnam[i]);
      end

    // -------- V1 directed: illegal encodings ------------------------------------
    apply(32'h0000_0000, 0, "all-zero");                   // opcode 0 -> illegal
    apply(32'hFFFF_FFFF, 0, "all-ones");
    apply(32'h0000_0001, 0, "compressed-quadrant1");       // instr[1:0] != 11
    apply(32'h0000_0002, 0, "compressed-quadrant2");
    apply(32'h2000_0033, 0, "bad-funct7-RTYPE");
    apply(32'h0000_3003, 0, "LD(f3=3)-illegal-rv32");
    apply(32'h0000_6003, 0, "LWU(f3=6)-illegal-rv32");
    apply(32'h0000_7003, 0, "load-f3=7-illegal");
    apply(32'h0000_3023, 0, "SD-illegal-rv32");
    apply(32'h0000_2063, 0, "branch-f3=2-illegal");
    apply(32'h0000_3063, 0, "branch-f3=3-illegal");
    apply(32'h0000_1067, 0, "JALR-f3!=0-illegal");
    apply(32'h2000_1013, 0, "SLLI-bad-funct7");
    apply(32'h2000_5013, 0, "SRLI-bad-funct7");
    apply(32'h0000_4073, 0, "SYSTEM-f3=4-illegal");
    apply(32'h0020_0073, 0, "ECALL-with-rs1!=0");
    apply(32'h0000_0173, 0, "EBREAK-with-rd!=0");
    apply(32'h3020_0173, 0, "MRET-rd!=0-illegal");
    apply(32'h3021_0073, 0, "MRET-rs1!=0-illegal");
    apply(32'h1050_0173, 0, "WFI-rd!=0-illegal");
    apply(32'h1051_0073, 0, "WFI-rs1!=0-illegal");
    apply(32'h1050_0073, 0, "WFI-legal-nop");
    apply(32'h3030_0073, 0, "funct12=0x303-illegal");
    apply(32'h0000_200F, 0, "FENCE-f3=2-illegal");
    apply(32'h0000_007B, 0, "unused-opcode-7B");
    apply(32'h0000_002B, 0, "unused-opcode-2B(AMO)");
    apply(32'h0000_0053, 0, "unused-opcode-53(FP)");

    // -------- V2/V5: 120 randomized instructions --------------------------------
    for (int i = 0; i < 120; i++) begin
      logic [31:0] ins;
      if ($urandom_range(0, 2) == 0)
        ins = $urandom();                            // fully random (mostly illegal)
      else begin
        int e = $urandom_range(0, ntbl - 1);         // legal skeleton + random filler
        ins = tbl[e].match | ($urandom() & ~tbl[e].mask);
      end
      apply(ins, 1, "rand");
    end

    finish_report();
    $finish;
  end
endmodule
