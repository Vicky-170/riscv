// =============================================================================
// rv32im_pkg.sv - shared types/constants for the RV32IM SoC
//   * opcodes, ALU/control enums, CSR addresses, trap causes
//   * pipeline register structs (IF/ID, ID/EX, EX/MEM, MEM/WB)
//   * reduced-AXI4 request/response structs (see docs for the supported subset)
//   * memory map constants
// Compile this file FIRST.
// =============================================================================
package rv32im_pkg;

  // ------------------------------------------------------------- opcodes
  localparam logic [6:0] OP_LUI    = 7'b011_0111;
  localparam logic [6:0] OP_AUIPC  = 7'b001_0111;
  localparam logic [6:0] OP_JAL    = 7'b110_1111;
  localparam logic [6:0] OP_JALR   = 7'b110_0111;
  localparam logic [6:0] OP_BRANCH = 7'b110_0011;
  localparam logic [6:0] OP_LOAD   = 7'b000_0011;
  localparam logic [6:0] OP_STORE  = 7'b010_0011;
  localparam logic [6:0] OP_IMM    = 7'b001_0011;
  localparam logic [6:0] OP_REG    = 7'b011_0011;
  localparam logic [6:0] OP_FENCE  = 7'b000_1111;
  localparam logic [6:0] OP_SYSTEM = 7'b111_0011;

  // ------------------------------------------------------------- datapath enums
  typedef enum logic [3:0] {
    ALU_ADD = 4'd0, ALU_SUB = 4'd1, ALU_SLL = 4'd2, ALU_SLT = 4'd3,
    ALU_SLTU = 4'd4, ALU_XOR = 4'd5, ALU_SRL = 4'd6, ALU_SRA = 4'd7,
    ALU_OR = 4'd8, ALU_AND = 4'd9
  } alu_op_e;

  typedef enum logic [1:0] { A_RS1 = 2'd0, A_PC = 2'd1, A_ZERO = 2'd2 } op_a_sel_e;
  typedef enum logic [1:0] { WB_EX = 2'd0, WB_LOAD = 2'd1, WB_CSR = 2'd2 } wb_sel_e;

  // ------------------------------------------------------------- trap causes
  localparam logic [3:0] CAUSE_INSN_MISALIGNED  = 4'd0;
  localparam logic [3:0] CAUSE_INSN_ACCESS      = 4'd1;
  localparam logic [3:0] CAUSE_ILLEGAL          = 4'd2;
  localparam logic [3:0] CAUSE_BREAKPOINT       = 4'd3;
  localparam logic [3:0] CAUSE_LOAD_MISALIGNED  = 4'd4;
  localparam logic [3:0] CAUSE_LOAD_ACCESS      = 4'd5;
  localparam logic [3:0] CAUSE_STORE_MISALIGNED = 4'd6;
  localparam logic [3:0] CAUSE_STORE_ACCESS     = 4'd7;
  localparam logic [3:0] CAUSE_ECALL_M          = 4'd11;

  // ------------------------------------------------------------- CSR addresses
  localparam logic [11:0] CSR_MSTATUS  = 12'h300, CSR_MISA     = 12'h301,
                          CSR_MIE      = 12'h304, CSR_MTVEC    = 12'h305,
                          CSR_MSCRATCH = 12'h340, CSR_MEPC     = 12'h341,
                          CSR_MCAUSE   = 12'h342, CSR_MTVAL    = 12'h343,
                          CSR_MIP      = 12'h344,
                          CSR_MCYCLE   = 12'hB00, CSR_MINSTRET = 12'hB02,
                          CSR_MHPM3    = 12'hB03, CSR_MHPM4    = 12'hB04,
                          CSR_MHPM5    = 12'hB05, CSR_MHPM6    = 12'hB06,
                          CSR_MCYCLEH  = 12'hB80, CSR_MINSTRETH = 12'hB82,
                          CSR_CYCLE    = 12'hC00, CSR_INSTRET  = 12'hC02,
                          CSR_CYCLEH   = 12'hC80, CSR_INSTRETH = 12'hC82,
                          CSR_MHARTID  = 12'hF14;

  // ------------------------------------------------------------- control bundle
  // Produced by decoder; a all-zero ctrl_t is a NOP/bubble.
  typedef struct packed {
    alu_op_e   alu_op;
    op_a_sel_e op_a_sel;
    logic      op_b_imm;            // 1: ALU operand B = imm, 0: rs2
    logic      use_rs1, use_rs2;    // operand really consumed (hazard filtering)
    logic      is_branch, is_jal, is_jalr;
    logic      mem_read, mem_write;
    logic      reg_write;
    wb_sel_e   wb_sel;
    logic      is_md;               // M-extension op (mul/div)
    logic      csr_en;              // Zicsr instruction (executes in MEM)
    logic      is_mret, is_fencei;
    logic      is_ecall, is_ebreak, illegal;  // consumed in ID (become exceptions)
  } ctrl_t;

  // ------------------------------------------------------------- pipeline registers
  typedef struct packed {                 // IF/ID
    logic        valid;
    logic        exc;                     // instruction access fault
    logic [3:0]  exc_cause;
    logic        pred_taken;
    logic [31:0] pc, instr, pred_target;
  } if_id_t;

  typedef struct packed {                 // ID/EX
    logic        valid;
    ctrl_t       ctrl;
    logic        exc;
    logic [3:0]  exc_cause;
    logic        pred_taken;
    logic [31:0] pc, rs1_val, rs2_val, imm, tval, pred_target;
    logic [4:0]  rs1, rs2, rd;
    logic [2:0]  funct3;
  } id_ex_t;

  typedef struct packed {                 // EX/MEM
    logic        valid;
    ctrl_t       ctrl;
    logic        exc;
    logic [3:0]  exc_cause;
    logic        csr_we;
    logic [31:0] pc, alu_result, store_data, tval;
    logic [4:0]  rd;
    logic [2:0]  funct3;
    logic [11:0] csr_addr;
  } ex_mem_t;

  typedef struct packed {                 // MEM/WB
    logic        reg_write;
    logic [4:0]  rd;
    logic [31:0] data;
  } mem_wb_t;

  // ------------------------------------------------------------- cache FSM states
  typedef enum logic [1:0] { CS_IDLE = 2'd0, CS_REQ = 2'd1, CS_FILL = 2'd2, CS_DONE = 2'd3 } cache_state_e;

  // ------------------------------------------------------------- reduced AXI4
  // Subset: single outstanding transaction per master, INCR bursts, 32-bit data,
  // no ID / LOCK / CACHE / PROT / QOS / REGION signals.
  localparam logic [1:0] AXI_RESP_OKAY   = 2'b00;
  localparam logic [1:0] AXI_RESP_SLVERR = 2'b10;
  localparam logic [1:0] AXI_RESP_DECERR = 2'b11;
  localparam logic [1:0] AXI_BURST_INCR  = 2'b01;

  typedef struct packed {                 // master -> slave
    logic [31:0] awaddr;  logic [7:0] awlen;  logic [2:0] awsize;  logic [1:0] awburst;  logic awvalid;
    logic [31:0] wdata;   logic [3:0] wstrb;  logic wlast;         logic wvalid;
    logic        bready;
    logic [31:0] araddr;  logic [7:0] arlen;  logic [2:0] arsize;  logic [1:0] arburst;  logic arvalid;
    logic        rready;
  } axi_req_t;

  typedef struct packed {                 // slave -> master
    logic        awready;
    logic        wready;
    logic [1:0]  bresp;   logic bvalid;
    logic        arready;
    logic [31:0] rdata;   logic [1:0] rresp;  logic rlast;  logic rvalid;
  } axi_rsp_t;

  localparam axi_req_t AXI_REQ_IDLE = '0;
  localparam axi_rsp_t AXI_RSP_IDLE = '0;

  // ------------------------------------------------------------- memory map (address[31:28])
  localparam logic [3:0] REGION_ROM    = 4'h0;   // 0x0000_0000  boot ROM
  localparam logic [3:0] REGION_SRAM   = 4'h1;   // 0x1000_0000  data/program SRAM
  localparam logic [3:0] REGION_PERIPH = 4'h4;   // 0x4000_0000  peripherals (uncached)
  // peripheral windows inside REGION_PERIPH, selected by address[15:12]
  //   0x4000_0000 timer/CLINT-lite   0x4000_1000 UART
  //   0x4000_2000 GPIO               0x4000_3000 interrupt controller
  localparam int PERIPH_TIMER = 0, PERIPH_UART = 1, PERIPH_GPIO = 2, PERIPH_INTC = 3;

  // ------------------------------------------------------------- helpers
  // Byte-enable merge used by all MMIO/register writes.
  function automatic logic [31:0] apply_be(input logic [31:0] old_v,
                                           input logic [31:0] new_v,
                                           input logic [3:0]  be);
    return {be[3] ? new_v[31:24] : old_v[31:24],
            be[2] ? new_v[23:16] : old_v[23:16],
            be[1] ? new_v[15:8]  : old_v[15:8],
            be[0] ? new_v[7:0]   : old_v[7:0]};
  endfunction

endpackage
