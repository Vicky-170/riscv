# RV32IM SoC — RTL Checkpoint Record (Stage 2+)

**Scope:** first full RTL drop of the frozen architecture (5-stage RV32IM, BHT/BTB, I/D caches, AXI4, APB peripherals, CSR/trap, perf counters).
**Size:** 28 SystemVerilog files, ~3,100 lines, top = `rv32im_soc`, compile order in `rtl/filelist.f`.

> ## Honest status
> Every module below is at **C0 = "RTL written"**. Per your instruction nothing was compiled, linted or simulated in this session, so **C1–C4 and RTL-SIGNOFF are NOT claimed for any module.** Inline `assert` checks (simulation-only, under `` `ifndef SYNTHESIS ``) are included as groundwork for C3 but have never run. Expect a handful of tool-specific syntax fixes on first compile (see §6).

---

## 1. Module status

Legend: **C0** written · C1 compiles/lints clean · C2 unit-tested · C3 integrated · C4 formal/regression.

| Module | File | Status | Key features implemented | Inline assertions |
|---|---|---|---|---|
| package | `rv32im_pkg.sv` | C0 | opcodes, enums, `ctrl_t`, pipeline structs, reduced-AXI structs, memory map, `apply_be()` | – |
| pc_unit | `core/pc_unit.sv` | C0 | reset PC, +4, redirect > prediction > seq., stall hold, IALIGN=32 | – |
| register_file | `core/register_file.sv` | C0 | 32×32, x0 hard-wired, 2R1W, WB→ID write-through, optional reset | x0 reads 0 |
| immediate_gen | `core/immediate_gen.sv` | C0 | I/S/B/U/J | – |
| decoder | `core/decoder.sv` | C0 | full RV32I + M + Zicsr + FENCE/FENCE.I + MRET, WFI=NOP, illegal → no side effects | – |
| alu | `core/alu.sv` | C0 | shared adder (ADD/SUB/SLT/SLTU), one shared shifter (left = reverse-shift-reverse) | – |
| branch_unit | `core/branch_unit.sv` | C0 | 6 branch conds, JAL/JALR target (JALR reuses ALU adder, bit0 cleared) | – |
| forwarding_unit | `core/forwarding_unit.sv` | C0 | EX/MEM > MEM/WB priority, x0 never forwarded | – |
| hazard_unit | `core/hazard_unit.sv` | C0 | load-use (also CSR reads), mem/ex stalls, mispredict + trap flushes | – |
| pipeline_regs | `core/pipeline_regs.sv` | C0 | 4 stage regs; flush > hold; only control bits reset (data unreset) | – |
| muldiv_unit | `core/muldiv_unit.sv` | C0 | `MUL_IMPL` 0 = 1-cycle, 1 = 33-cycle iterative; 32-cycle restoring div; x/0 and INT_MIN/−1 per spec | no ready in RUN |
| csr_file | `core/csr_file.sv` | C0 | mstatus mie mip mtvec(+vectored) mepc mcause mtval mscratch misa, cycle/instret(+h), 4 HPM counters | trap saves mepc, clears MIE |
| branch_predictor | `core/branch_predictor.sv` | C0 | `bht` (2-bit, 2 read ports) + `btb` (direct-mapped) + wrapper; 3 variants | – |
| rv32im_core | `core/rv32im_core.sv` | C0 | 5-stage integration, traps in MEM, MRET, FENCE.I, IRQ, perf events | flush-after-trap, no trap during stall, BE≠0, no req on irq |
| cache_tag/data_array | `cache/cache_arrays.sv` | C0 | valid bits (reset/inval/clear), byte-enable data array, async read | – |
| icache | `cache/icache.sv` | C0 | direct-mapped, burst refill, victim invalidated at refill start, error line, FENCE.I kill, `ENABLE=0` 1-word buffer | err ⇒ ready |
| dcache | `cache/dcache.sv` | C0 | write-through/no-write-allocate, load-hit in same cycle, uncached MMIO, error reporting, `ENABLE=0` bypass | err only in DONE, strobes≠0 |
| axi4_master | `bus/axi4_master.sv` | C0 | native→AXI, INCR bursts, single-beat writes, `READ_ONLY` | AR/AW stability |
| axi4_interconnect (+`axi_err_slave`) | `bus/axi4_interconnect.sv` | C0 | 2M×3S shared-bus, RR arbitration, registered decode, DECERR responder | no AR+AW together |
| axi_to_apb | `bus/axi_to_apb.sv` | C0 | AXI-Lite→APB4, one-hot psel, PSLVERR→SLVERR, unmapped→DECERR | no bursts, psel one-hot |
| boot_rom | `memory/boot_rom.sv` | C0 | `$readmemh`, burst reads, out-of-range/write → SLVERR | – |
| sram_controller | `memory/sram_controller.sv` | C0 | burst R/W, byte strobes, out-of-range → SLVERR | – |
| memory_subsystem | `memory/memory_subsystem.sv` | C0 | I$ + D$ + 2 masters + xbar + ROM + SRAM, exports peripheral port | – |
| timer | `peripherals/timer.sv` | C0 | 64-bit mtime/mtimecmp, EN, MSIP | – |
| uart | `peripherals/uart.sv` | C0 | 8N1 TX/RX, baud divisor, overrun/frame flags, IRQs | – |
| gpio | `peripherals/gpio.sv` | C0 | OUT/DIR/IN/IRQ_EN, 2-FF input sync | – |
| interrupt_controller | `peripherals/interrupt_controller.sv` | C0 | 8 sources, enable mask, fixed-priority claim | – |
| rv32im_soc | `soc/rv32im_soc.sv` | C0 | top-level wiring + all PPA-variant parameters | – |

---

## 2. Architecture decisions that shape the checkpoints

1. **Traps are taken in MEM (precise).** Fetch fault, illegal, ECALL/EBREAK and misaligned jump targets ride down the pipe with the instruction; MEM adds load/store misalign/access faults, illegal CSR access and interrupts. Nothing architectural is written before MEM commits. A trap flushes IF/ID, ID/EX, EX/MEM.
2. **CSR ops execute in MEM** (never speculative). They are "late" producers → the load-use interlock covers them.
3. **Interrupts** are taken only when MEM holds a valid instruction and the D-cache FSM is idle (`dmem_busy=0`), so a bus transaction is never abandoned. `mepc` = PC of that not-yet-executed instruction.
4. **Stall + forwarding safety:** while ID/EX is frozen (mem stall / mul-div busy) its operands are refreshed with the forwarded values, otherwise a producer leaving MEM/WB would lose the bypassed data. *This is the first thing to stress in C3.*
5. **Branches resolve in EX.** Variants: static not-taken · BHT-only (redirect from ID, 1 bubble) · BHT+BTB (redirect from IF). Mispredict = direction differs or target differs, also catches BTB-hit-on-non-branch.
6. **Caches:** direct-mapped, combinational-read hit (0 extra cycles). D-cache is write-through, no-write-allocate, blocking stores. Peripheral space is never cached. Stores hit the array only after a successful bus write.
7. **Bus:** one owner at a time (shared-bus arbitration, 1 cycle overhead), registered address decode, DECERR for undecoded regions, SLVERR for out-of-range/ROM-write.
8. **Defaults:** `MUL_IMPL=0`, BHT+BTB on, 64-line × 16 B caches (1 KiB each), 4 KiB ROM, 4 KiB SRAM.

## 3. Memory map (**assumed** — reconcile with your Stage-0 `memory_map.md`, I did not have that file)

| Region | Base | Notes |
|---|---|---|
| Boot ROM | `0x0000_0000` | reset PC; read-only; cacheable |
| SRAM | `0x1000_0000` | code + data; cacheable |
| Timer | `0x4000_0000` | CTRL 0x00, MSIP 0x04, MTIME 0x08/0x0C, MTIMECMP 0x10/0x14 |
| UART | `0x4000_1000` | TXDATA 0x00, RXDATA 0x04, STATUS 0x08, CTRL 0x0C, BAUD 0x10 |
| GPIO | `0x4000_2000` | OUT 0x00, DIR 0x04, IN 0x08, IRQ_EN 0x0C |
| INTC | `0x4000_3000` | PENDING 0x00, ENABLE 0x04, CLAIM 0x08 |

Decode is by `addr[31:28]` (regions) and `addr[15:12]` (peripheral). Constants live in `rv32im_pkg.sv`.
INTC sources: 0 UART, 1 GPIO, 2–7 `ext_irq[0..5]`. Core interrupts: MSIP/MTIP from timer, MEIP from INTC.

## 4. Top-level parameters (PPA variants)

`ENABLE_BHT`, `ENABLE_BTB`, `BHT_ENTRIES`, `BTB_ENTRIES`, `MUL_IMPL`, `OPERAND_ISOLATION`, `ICACHE_ENABLE`, `DCACHE_ENABLE`, `ICACHE_LINES/LINE_BYTES`, `DCACHE_LINES/LINE_BYTES`, `ROM_WORDS`, `SRAM_WORDS`, `ROM_INIT_FILE`, `UART_BAUD_DIV`, `RESET_PC`.
Constraints: `ENABLE_BTB ⇒ ENABLE_BHT` (elaboration `$error`); cache lines power-of-2 ≥ 2, line bytes power-of-2 ≥ 8.

## 5. Deviations from the Stage-0 plan (deliberate)

| Planned | Actual | Why |
|---|---|---|
| separate `cache_controller.sv` | FSM inside `icache`/`dcache` | I- and D-side FSMs differ; saves a layer |
| `axi4_lite_slave.sv` + `axi_to_apb.sv` | merged into `axi_to_apb.sv` | the bridge *is* the AXI-Lite slave |
| full AXI4 | reduced AXI4: no IDs/LOCK/CACHE/PROT/QOS, 1 outstanding, INCR only, 32-bit | matches what the masters actually need; documented so nobody assumes full AXI4 compliance |
| interconnect outside memory subsystem | inside `memory_subsystem`, peripheral port exported | matches "memory_subsystem integrates I$, D$, ROM, SRAM, AXI" |
| clock gating variant | **not implemented** (only operand isolation) | belongs to the PPA stage; needs a library ICG cell |
| testbenches | **not written** | out of scope for this RTL drop |

## 6. First-compile risk list (fix these first)

* Toolchain support for **packed structs containing enums**, **package imports in module headers** (`module x import pkg::*; #(...)`) and **struct-typed ports**. Fine in Verilator 5 / sv2v / yosys-slang; plain Yosys `read_verilog -sv` is the one to check.
* Size casts (`8'(WORDS-1)`, `32'(i+1)`), `$onehot0`, `$error` inside `generate`, immediate `assert` in `always @(posedge clk)`.
* `boot_rom` `$readmemh(INIT_FILE)` warns if `rom_init.hex` is missing (create it before simulating).
* Verilator `-Wall` will report unused bits/signals (e.g. `pc_plus4`, `hpm` bits); benign.

## 7. Known limitations / behaviours to be aware of

* Blocking write-through stores cost a full bus round trip; no write buffer. Sequential-store-heavy code will show high CPI — a candidate PPA optimisation.
* Register file, caches and SRAM are flop arrays (large area). Swap for macros in the PD stage; the SRAM controller would need one wait state for a synchronous-read macro.
* Illegal-CSR exceptions report `mtval = 0`. WFI is a NOP. Compressed instructions are illegal.
* Instruction fetch from the peripheral region → DECERR → instruction access fault. Fetch from SRAM is allowed (needs `FENCE.I` after writing code).
* Interrupt latency is bounded by an in-flight D-cache transaction (worst case: a refill).
* `mhpmcounter3..6` are custom-event counters: branches/jumps, mispredicts, I$ misses, D$ misses (32-bit, no `mhpmevent`).

## 8. Suggested next steps (in order)

1. **C1:** `verilator --lint-only -Wall -Wno-fatal --top-module rv32im_soc -f rtl/filelist.f`, fix syntax/width issues, then run each variant of the parameter set once for elaboration.
2. **C2 unit benches (highest bug-yield first):** `muldiv_unit` (spec corner cases), `alu`, `decoder`, `csr_file`, `icache`/`dcache` against a simple AXI slave model, `axi4_interconnect`, `uart`.
3. **C3 core tests:** RISC-V `rv32ui`/`rv32um` ISA tests via ROM hex; a directed test for *forwarding across a D-cache stall*, *load-use*, *mispredict during mul/div*, *interrupt during a D-cache miss*, *FENCE.I after self-modifying store*.
4. **C4:** SBY properties for x0, flush-after-trap, AXI stability (assertions already sketched inline); Yosys synthesis + STA baseline to fill the PPA table.
5. Write the reset-value / register-reference docs from §3 once the memory map is reconciled.

## 9. Files

```
rtl/rv32im_pkg.sv
rtl/core/        pc_unit register_file immediate_gen decoder alu branch_unit forwarding_unit
                 hazard_unit pipeline_regs muldiv_unit csr_file branch_predictor rv32im_core
rtl/cache/       cache_arrays icache dcache
rtl/bus/         axi4_master axi4_interconnect axi_to_apb
rtl/memory/      boot_rom sram_controller memory_subsystem
rtl/peripherals/ timer uart gpio interrupt_controller
rtl/soc/         rv32im_soc
rtl/filelist.f
```


> **Update (Stage 4 verification):** Module-level verification is complete and SIGNED OFF
> (see `STAGE4_VERIFICATION_REPORT.md`). Four RTL bugs were found and fixed during
> verification: (1) `decoder.sv` accepted reserved MRET/WFI encodings with nonzero
> rd/rs1; (2) `csr_file.sv` had a simulation-only assertion false-fire during reset;
> (3) `boot_rom.sv`/`sram_controller.sv` used the wrong address bit slice for their
> range check, incorrectly erroring on every access at the real base address; (4)
> `rv32im_core.sv` did not force a pipeline bubble's control bits to zero at the
> `id_ctrl`/`exmem_d.ctrl` source, allowing `forwarding_unit` to forward garbage data
> from an invalid stage during pipeline warm-up. All four are fixed in the RTL files
> in this directory; the appendix source dump below predates these fixes — see the
> individual `.sv` files for the corrected code (each fix is marked `RTL FIX #N`).

---

# Appendix A — Complete source (compile order)
Files appear in the same order as `rtl/filelist.f` (package first, top-level last). Total: 28 files.

## Contents
1. [`rtl/rv32im_pkg.sv`](#1-rtlrv32impkgsv)
2. [`rtl/core/pipeline_regs.sv`](#2-rtlcorepipelineregssv)
3. [`rtl/core/pc_unit.sv`](#3-rtlcorepcunitsv)
4. [`rtl/core/register_file.sv`](#4-rtlcoreregisterfilesv)
5. [`rtl/core/immediate_gen.sv`](#5-rtlcoreimmediategensv)
6. [`rtl/core/decoder.sv`](#6-rtlcoredecodersv)
7. [`rtl/core/alu.sv`](#7-rtlcorealusv)
8. [`rtl/core/branch_unit.sv`](#8-rtlcorebranchunitsv)
9. [`rtl/core/forwarding_unit.sv`](#9-rtlcoreforwardingunitsv)
10. [`rtl/core/hazard_unit.sv`](#10-rtlcorehazardunitsv)
11. [`rtl/core/muldiv_unit.sv`](#11-rtlcoremuldivunitsv)
12. [`rtl/core/csr_file.sv`](#12-rtlcorecsrfilesv)
13. [`rtl/core/branch_predictor.sv`](#13-rtlcorebranchpredictorsv)
14. [`rtl/core/rv32im_core.sv`](#14-rtlcorerv32imcoresv)
15. [`rtl/cache/cache_arrays.sv`](#15-rtlcachecachearrayssv)
16. [`rtl/cache/icache.sv`](#16-rtlcacheicachesv)
17. [`rtl/cache/dcache.sv`](#17-rtlcachedcachesv)
18. [`rtl/bus/axi4_master.sv`](#18-rtlbusaxi4mastersv)
19. [`rtl/bus/axi4_interconnect.sv`](#19-rtlbusaxi4interconnectsv)
20. [`rtl/bus/axi_to_apb.sv`](#20-rtlbusaxitoapbsv)
21. [`rtl/memory/boot_rom.sv`](#21-rtlmemorybootromsv)
22. [`rtl/memory/sram_controller.sv`](#22-rtlmemorysramcontrollersv)
23. [`rtl/memory/memory_subsystem.sv`](#23-rtlmemorymemorysubsystemsv)
24. [`rtl/peripherals/timer.sv`](#24-rtlperipheralstimersv)
25. [`rtl/peripherals/uart.sv`](#25-rtlperipheralsuartsv)
26. [`rtl/peripherals/gpio.sv`](#26-rtlperipheralsgpiosv)
27. [`rtl/peripherals/interrupt_controller.sv`](#27-rtlperipheralsinterruptcontrollersv)
28. [`rtl/soc/rv32im_soc.sv`](#28-rtlsocrv32imsocsv)

## 1. `rtl/rv32im_pkg.sv`

```systemverilog
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
```

## 2. `rtl/core/pipeline_regs.sv`

```systemverilog
// =============================================================================
// pipeline_regs.sv - IF/ID, ID/EX, EX/MEM, MEM/WB registers
//
// Convention (all four): flush > en.
//   * reset / flush clear ONLY the "control" part (valid, ctrl, exc, reg_write):
//     a bubble is a register with valid=0 and all side-effect controls at 0.
//   * the data payload has no reset/clear (saves area); en=1 loads it, en=0 holds it.
// =============================================================================

module if_id_reg import rv32im_pkg::*; (
  input  logic clk, rst_n, en, flush,
  input  if_id_t d,
  output if_id_t q
);
  always_ff @(posedge clk) begin
    if (!rst_n || flush) begin
      q.valid <= 1'b0;
      q.exc   <= 1'b0;
    end else if (en) begin
      q.valid <= d.valid;
      q.exc   <= d.exc;
    end
    if (en) begin
      q.exc_cause   <= d.exc_cause;
      q.pred_taken  <= d.pred_taken;
      q.pc          <= d.pc;
      q.instr       <= d.instr;
      q.pred_target <= d.pred_target;
    end
  end
endmodule

module id_ex_reg import rv32im_pkg::*; (
  input  logic clk, rst_n, en, flush,
  input  id_ex_t d,
  output id_ex_t q
);
  always_ff @(posedge clk) begin
    if (!rst_n || flush) begin
      q.valid <= 1'b0;
      q.ctrl  <= '0;
      q.exc   <= 1'b0;
    end else if (en) begin
      q.valid <= d.valid;
      q.ctrl  <= d.ctrl;
      q.exc   <= d.exc;
    end
    if (en) begin
      q.exc_cause   <= d.exc_cause;
      q.pred_taken  <= d.pred_taken;
      q.pc          <= d.pc;
      q.rs1_val     <= d.rs1_val;
      q.rs2_val     <= d.rs2_val;
      q.imm         <= d.imm;
      q.tval        <= d.tval;
      q.pred_target <= d.pred_target;
      q.rs1         <= d.rs1;
      q.rs2         <= d.rs2;
      q.rd          <= d.rd;
      q.funct3      <= d.funct3;
    end
  end
endmodule

module ex_mem_reg import rv32im_pkg::*; (
  input  logic clk, rst_n, en, flush,
  input  ex_mem_t d,
  output ex_mem_t q
);
  always_ff @(posedge clk) begin
    if (!rst_n || flush) begin
      q.valid <= 1'b0;
      q.ctrl  <= '0;
      q.exc   <= 1'b0;
    end else if (en) begin
      q.valid <= d.valid;
      q.ctrl  <= d.ctrl;
      q.exc   <= d.exc;
    end
    if (en) begin
      q.exc_cause  <= d.exc_cause;
      q.csr_we     <= d.csr_we;
      q.pc         <= d.pc;
      q.alu_result <= d.alu_result;
      q.store_data <= d.store_data;
      q.tval       <= d.tval;
      q.rd         <= d.rd;
      q.funct3     <= d.funct3;
      q.csr_addr   <= d.csr_addr;
    end
  end
endmodule

module mem_wb_reg import rv32im_pkg::*; (
  input  logic clk, rst_n, en, flush,
  input  mem_wb_t d,
  output mem_wb_t q
);
  always_ff @(posedge clk) begin
    if (!rst_n || flush)  q.reg_write <= 1'b0;
    else if (en)          q.reg_write <= d.reg_write;
    if (en) begin
      q.rd   <= d.rd;
      q.data <= d.data;
    end
  end
endmodule
```

## 3. `rtl/core/pc_unit.sv`

```systemverilog
// =============================================================================
// pc_unit.sv - fetch program counter
//   priority: redirect > BTB prediction > PC+4.  PC[1:0] is always 0 (no C-ext).
//   The PC only steps when the fetched instruction is accepted (advance) or a
//   redirect arrives; a redirect always wins over a stall.
// =============================================================================
module pc_unit #(
  parameter logic [31:0] RESET_PC = 32'h0000_0000
) (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        advance,          // instruction at pc accepted by IF/ID
  input  logic        redirect_valid,   // trap / mispredict / early-decode redirect
  input  logic [31:0] redirect_pc,
  input  logic        pred_taken,       // BTB+BHT prediction for current pc
  input  logic [31:0] pred_target,
  output logic [31:0] pc,
  output logic [31:0] pc_plus4
);
  logic [31:0] pc_next;

  assign pc_plus4 = pc + 32'd4;

  always_comb begin
    if (redirect_valid)    pc_next = redirect_pc;
    else if (pred_taken)   pc_next = pred_target;
    else                   pc_next = pc_plus4;
    pc_next[1:0] = 2'b00;                       // enforce IALIGN=32
  end

  always_ff @(posedge clk) begin
    if (!rst_n)                        pc <= RESET_PC;
    else if (redirect_valid | advance) pc <= pc_next;
  end
endmodule
```

## 4. `rtl/core/register_file.sv`

```systemverilog
// =============================================================================
// register_file.sv - 32x32 RV32 integer register file
//   * 2 async read ports, 1 write port; x0 is not stored and reads as zero
//   * write-through bypass: a same-cycle write is visible to the read ports
//     (covers producer-in-WB / consumer-in-ID)
//   * RESET_REGS=0 (default) saves area: registers are not reset in hardware;
//     simulation zero-fills them so no X reaches software.
// =============================================================================
module register_file #(
  parameter bit RESET_REGS = 1'b0
) (
  input  logic        clk,
  input  logic        rst_n,
  input  logic [4:0]  raddr1,
  input  logic [4:0]  raddr2,
  output logic [31:0] rdata1,
  output logic [31:0] rdata2,
  input  logic        we,
  input  logic [4:0]  waddr,
  input  logic [31:0] wdata
);
  logic [31:0] rf [1:31];                       // x0 intentionally absent

  always_ff @(posedge clk) begin
    if (RESET_REGS && !rst_n) begin
      for (int i = 1; i < 32; i++) rf[i] <= 32'd0;
    end else if (we && waddr != 5'd0) begin
      rf[waddr] <= wdata;
    end
  end

  assign rdata1 = (raddr1 == 5'd0) ? 32'd0 : ((we && waddr == raddr1) ? wdata : rf[raddr1]);
  assign rdata2 = (raddr2 == 5'd0) ? 32'd0 : ((we && waddr == raddr2) ? wdata : rf[raddr2]);

`ifndef SYNTHESIS
  initial for (int i = 1; i < 32; i++) rf[i] = 32'd0;   // X-free simulation
  always @(posedge clk) if (rst_n) begin
    assert (!(raddr1 == 5'd0) || rdata1 == 32'd0) else $error("regfile: x0 read1 != 0");
    assert (!(raddr2 == 5'd0) || rdata2 == 32'd0) else $error("regfile: x0 read2 != 0");
  end
`endif
endmodule
```

## 5. `rtl/core/immediate_gen.sv`

```systemverilog
// =============================================================================
// immediate_gen.sv - I/S/B/U/J immediate extraction (format chosen from opcode)
//   SYSTEM (CSR) instructions use the I-type path: imm[11:0] = CSR address.
// =============================================================================
module immediate_gen import rv32im_pkg::*; (
  input  logic [31:0] instr,
  output logic [31:0] imm
);
  always_comb begin
    case (instr[6:0])
      OP_STORE:          imm = {{20{instr[31]}}, instr[31:25], instr[11:7]};                          // S
      OP_BRANCH:         imm = {{19{instr[31]}}, instr[31], instr[7], instr[30:25], instr[11:8], 1'b0}; // B
      OP_LUI, OP_AUIPC:  imm = {instr[31:12], 12'd0};                                                 // U
      OP_JAL:            imm = {{11{instr[31]}}, instr[31], instr[19:12], instr[20], instr[30:21], 1'b0}; // J
      default:           imm = {{20{instr[31]}}, instr[31:20]};                                       // I
    endcase
  end
endmodule
```

## 6. `rtl/core/decoder.sv`

```systemverilog
// =============================================================================
// decoder.sv - RV32IM + Zicsr + FENCE/FENCE.I + MRET decoder (purely combinational)
//   * Every unsupported/invalid encoding sets ctrl.illegal and clears all other
//     side-effect controls.
//   * ECALL/EBREAK are flagged here and turned into exceptions in ID.
//   * WFI is decoded as a NOP.  Compressed (instr[1:0] != 2'b11) is illegal.
// =============================================================================
module decoder import rv32im_pkg::*; (
  input  logic [31:0] instr,
  output ctrl_t       ctrl
);
  logic [6:0] opcode, f7;
  logic [2:0] f3;
  logic [4:0] rd, rs1;

  assign opcode = instr[6:0];
  assign f3     = instr[14:12];
  assign f7     = instr[31:25];
  assign rd     = instr[11:7];
  assign rs1    = instr[19:15];

  always_comb begin
    ctrl = '0;                                   // NOP defaults (alu ADD, A=rs1, B=rs2)

    if (instr[1:0] != 2'b11) begin
      ctrl.illegal = 1'b1;
    end else begin
      case (opcode)
        OP_LUI:   begin ctrl.reg_write = 1'b1; ctrl.op_a_sel = A_ZERO; ctrl.op_b_imm = 1'b1; end
        OP_AUIPC: begin ctrl.reg_write = 1'b1; ctrl.op_a_sel = A_PC;   ctrl.op_b_imm = 1'b1; end
        OP_JAL:   begin ctrl.reg_write = 1'b1; ctrl.is_jal = 1'b1; end

        OP_JALR: begin                            // target = rs1 + imm (ALU adder)
          if (f3 == 3'b000) begin
            ctrl.reg_write = 1'b1; ctrl.is_jalr = 1'b1; ctrl.use_rs1 = 1'b1; ctrl.op_b_imm = 1'b1;
          end else ctrl.illegal = 1'b1;
        end

        OP_BRANCH: begin
          if (f3 != 3'b010 && f3 != 3'b011) begin
            ctrl.is_branch = 1'b1; ctrl.use_rs1 = 1'b1; ctrl.use_rs2 = 1'b1;
          end else ctrl.illegal = 1'b1;
        end

        OP_LOAD: begin                            // LB LH LW LBU LHU
          if (f3 == 3'b000 || f3 == 3'b001 || f3 == 3'b010 || f3 == 3'b100 || f3 == 3'b101) begin
            ctrl.mem_read = 1'b1; ctrl.reg_write = 1'b1; ctrl.wb_sel = WB_LOAD;
            ctrl.use_rs1 = 1'b1;  ctrl.op_b_imm = 1'b1;
          end else ctrl.illegal = 1'b1;
        end

        OP_STORE: begin                           // SB SH SW
          if (f3 == 3'b000 || f3 == 3'b001 || f3 == 3'b010) begin
            ctrl.mem_write = 1'b1; ctrl.use_rs1 = 1'b1; ctrl.use_rs2 = 1'b1; ctrl.op_b_imm = 1'b1;
          end else ctrl.illegal = 1'b1;
        end

        OP_IMM: begin
          ctrl.reg_write = 1'b1; ctrl.use_rs1 = 1'b1; ctrl.op_b_imm = 1'b1;
          case (f3)
            3'b000: ctrl.alu_op = ALU_ADD;
            3'b010: ctrl.alu_op = ALU_SLT;
            3'b011: ctrl.alu_op = ALU_SLTU;
            3'b100: ctrl.alu_op = ALU_XOR;
            3'b110: ctrl.alu_op = ALU_OR;
            3'b111: ctrl.alu_op = ALU_AND;
            3'b001: begin ctrl.alu_op = ALU_SLL; if (f7 != 7'b0000000) ctrl.illegal = 1'b1; end
            3'b101: begin
              ctrl.alu_op = f7[5] ? ALU_SRA : ALU_SRL;
              if (f7 != 7'b0000000 && f7 != 7'b0100000) ctrl.illegal = 1'b1;
            end
            default: ctrl.illegal = 1'b1;
          endcase
        end

        OP_REG: begin
          ctrl.reg_write = 1'b1; ctrl.use_rs1 = 1'b1; ctrl.use_rs2 = 1'b1;
          if (f7 == 7'b0000001) begin
            ctrl.is_md = 1'b1;                    // MUL/MULH/MULHSU/MULHU/DIV/DIVU/REM/REMU
          end else if (f7 == 7'b0000000 || (f7 == 7'b0100000 && (f3 == 3'b000 || f3 == 3'b101))) begin
            case (f3)
              3'b000: ctrl.alu_op = f7[5] ? ALU_SUB : ALU_ADD;
              3'b001: ctrl.alu_op = ALU_SLL;
              3'b010: ctrl.alu_op = ALU_SLT;
              3'b011: ctrl.alu_op = ALU_SLTU;
              3'b100: ctrl.alu_op = ALU_XOR;
              3'b101: ctrl.alu_op = f7[5] ? ALU_SRA : ALU_SRL;
              3'b110: ctrl.alu_op = ALU_OR;
              default: ctrl.alu_op = ALU_AND;
            endcase
          end else ctrl.illegal = 1'b1;
        end

        OP_FENCE: begin                           // FENCE = NOP, FENCE.I = I$ invalidate
          if (f3 == 3'b000)      ; // nop
          else if (f3 == 3'b001) ctrl.is_fencei = 1'b1;
          else                   ctrl.illegal = 1'b1;
        end

        OP_SYSTEM: begin
          if (f3 == 3'b000) begin
            case (instr[31:20])
              12'h000: if (rs1 == 5'd0 && rd == 5'd0) ctrl.is_ecall  = 1'b1; else ctrl.illegal = 1'b1;
              12'h001: if (rs1 == 5'd0 && rd == 5'd0) ctrl.is_ebreak = 1'b1; else ctrl.illegal = 1'b1;
              12'h302: ctrl.is_mret = 1'b1;
              12'h105: ;                          // WFI -> NOP
              default: ctrl.illegal = 1'b1;
            endcase
          end else if (f3 != 3'b100) begin        // CSRRW/S/C and immediate forms
            ctrl.csr_en = 1'b1; ctrl.reg_write = 1'b1; ctrl.wb_sel = WB_CSR;
            ctrl.use_rs1 = ~f3[2];                // reg forms read rs1; imm forms use zimm
          end else ctrl.illegal = 1'b1;
        end

        default: ctrl.illegal = 1'b1;
      endcase
    end

    // Illegal instructions must have no side effects.
    if (ctrl.illegal) begin
      ctrl = '0;
      ctrl.illegal = 1'b1;
    end
  end
endmodule
```

## 7. `rtl/core/alu.sv`

```systemverilog
// =============================================================================
// alu.sv - RV32I ALU (area-efficient)
//   * one adder/subtractor shared by ADD/SUB/SLT/SLTU (and address/JALR math)
//   * one right shifter shared by SLL/SRL/SRA (left shift = reverse, shift, reverse)
// =============================================================================
module alu import rv32im_pkg::*; (
  input  logic [31:0] a,
  input  logic [31:0] b,
  input  alu_op_e     op,
  output logic [31:0] y
);
  // ---- shared adder / subtractor -------------------------------------------
  logic        sub, lt, ltu;
  logic [32:0] sum;
  assign sub = (op == ALU_SUB) | (op == ALU_SLT) | (op == ALU_SLTU);
  assign sum = {1'b0, a} + {1'b0, b ^ {32{sub}}} + {32'd0, sub};
  assign ltu = ~sum[32];                              // a<b unsigned <=> no carry out of a-b
  assign lt  = (a[31] ^ b[31]) ? a[31] : sum[31];     // signed compare

  // ---- shared shifter ------------------------------------------------------
  logic [31:0] a_rev, sh_in, sh_r, sh_r_rev, sh_out;
  logic [32:0] sh_full;
  logic        sh_fill;
  always_comb begin
    for (int i = 0; i < 32; i++) begin
      a_rev[i]    = a[31-i];
      sh_r_rev[i] = sh_r[31-i];
    end
  end
  assign sh_in   = (op == ALU_SLL) ? a_rev : a;
  assign sh_fill = (op == ALU_SRA) & a[31];           // arithmetic fill bit
  assign sh_full = $signed({sh_fill, sh_in}) >>> b[4:0];
  assign sh_r    = sh_full[31:0];
  assign sh_out  = (op == ALU_SLL) ? sh_r_rev : sh_r;

  // ---- result mux ----------------------------------------------------------
  always_comb begin
    case (op)
      ALU_ADD, ALU_SUB:            y = sum[31:0];
      ALU_SLT:                     y = {31'd0, lt};
      ALU_SLTU:                    y = {31'd0, ltu};
      ALU_XOR:                     y = a ^ b;
      ALU_OR:                      y = a | b;
      ALU_AND:                     y = a & b;
      ALU_SLL, ALU_SRL, ALU_SRA:   y = sh_out;
      default:                     y = sum[31:0];
    endcase
  end
endmodule
```

## 8. `rtl/core/branch_unit.sv`

```systemverilog
// =============================================================================
// branch_unit.sv - EX-stage branch/jump resolution
//   taken  : JAL/JALR always, conditional branches by funct3 compare
//   target : JALR = (rs1+imm)&~1 (supplied by ALU adder), else pc+imm
// =============================================================================
module branch_unit (
  input  logic [2:0]  funct3,
  input  logic [31:0] rs1,
  input  logic [31:0] rs2,
  input  logic        is_branch,
  input  logic        is_jal,
  input  logic        is_jalr,
  input  logic [31:0] pc,
  input  logic [31:0] imm,
  input  logic [31:0] jalr_sum,      // rs1 + imm from the ALU
  output logic        taken,
  output logic [31:0] target
);
  logic eq, lt, ltu, cond;
  assign eq  = (rs1 == rs2);
  assign lt  = ($signed(rs1) < $signed(rs2));
  assign ltu = (rs1 < rs2);

  always_comb begin
    case (funct3)
      3'b000:  cond = eq;      // BEQ
      3'b001:  cond = ~eq;     // BNE
      3'b100:  cond = lt;      // BLT
      3'b101:  cond = ~lt;     // BGE
      3'b110:  cond = ltu;     // BLTU
      3'b111:  cond = ~ltu;    // BGEU
      default: cond = 1'b0;
    endcase
  end

  assign taken  = is_jal | is_jalr | (is_branch & cond);
  assign target = is_jalr ? {jalr_sum[31:1], 1'b0} : (pc + imm);
endmodule
```

## 9. `rtl/core/forwarding_unit.sv`

```systemverilog
// =============================================================================
// forwarding_unit.sv - EX operand bypass select
//   0 = ID/EX register value, 1 = EX/MEM result, 2 = MEM/WB result.
//   Youngest producer wins (EX/MEM over MEM/WB); x0 is never forwarded.
//   Loads/CSR reads are "late" producers - the hazard unit guarantees a consumer
//   is never in EX while such a producer sits in EX/MEM.
// =============================================================================
module forwarding_unit (
  input  logic [4:0] ex_rs1,
  input  logic [4:0] ex_rs2,
  input  logic       exmem_reg_write,
  input  logic [4:0] exmem_rd,
  input  logic       memwb_reg_write,
  input  logic [4:0] memwb_rd,
  output logic [1:0] fwd_a,
  output logic [1:0] fwd_b
);
  always_comb begin
    fwd_a = 2'd0;
    fwd_b = 2'd0;
    if (memwb_reg_write && memwb_rd != 5'd0 && memwb_rd == ex_rs1) fwd_a = 2'd2;
    if (memwb_reg_write && memwb_rd != 5'd0 && memwb_rd == ex_rs2) fwd_b = 2'd2;
    if (exmem_reg_write && exmem_rd != 5'd0 && exmem_rd == ex_rs1) fwd_a = 2'd1;
    if (exmem_reg_write && exmem_rd != 5'd0 && exmem_rd == ex_rs2) fwd_b = 2'd1;
  end
endmodule
```

## 10. `rtl/core/hazard_unit.sv`

```systemverilog
// =============================================================================
// hazard_unit.sv - stall / flush / bubble generation
//
// Stall sources (highest to lowest reach):
//   mem_stall : D-cache busy for the MEM instruction -> freeze IF..MEM, bubble to WB
//   ex_busy   : multi-cycle mul/div in EX            -> freeze IF..EX, bubble to MEM
//   load_use  : consumer right behind a load/CSR read -> freeze IF/ID, bubble to EX
// Flush sources:
//   mem_redirect : trap / MRET / FENCE.I (MEM stage)  -> kill IF/ID, ID/EX, EX/MEM
//   ex_redirect  : branch mispredict (EX stage)       -> kill IF/ID, ID/EX
// Pipeline-register convention: flush has priority over hold (see pipeline_regs).
// =============================================================================
module hazard_unit (
  // ID/EX (instruction in EX)
  input  logic       idex_valid,
  input  logic       idex_late,        // result available only after MEM (load / CSR read)
  input  logic [4:0] idex_rd,
  // IF/ID (instruction in ID)
  input  logic       ifid_valid,
  input  logic [4:0] ifid_rs1,
  input  logic [4:0] ifid_rs2,
  input  logic       ifid_use_rs1,
  input  logic       ifid_use_rs2,
  // events
  input  logic       mem_stall,
  input  logic       ex_busy,
  input  logic       ex_redirect,
  input  logic       mem_redirect,
  input  logic       trap_take,
  // controls
  output logic       load_use,
  output logic       pc_hold,
  output logic       ifid_hold,
  output logic       idex_hold,
  output logic       exmem_hold,
  output logic       ifid_flush,
  output logic       idex_flush,
  output logic       exmem_flush,
  output logic       memwb_flush
);
  assign load_use = idex_valid & idex_late & (idex_rd != 5'd0) & ifid_valid &
                    ((ifid_use_rs1 & (ifid_rs1 == idex_rd)) |
                     (ifid_use_rs2 & (ifid_rs2 == idex_rd)));

  assign pc_hold    = mem_stall | ex_busy | load_use;
  assign ifid_hold  = pc_hold;
  assign idex_hold  = mem_stall | ex_busy;
  assign exmem_hold = mem_stall;

  assign ifid_flush  = mem_redirect | ex_redirect;
  assign idex_flush  = mem_redirect | ex_redirect | (load_use & ~idex_hold);   // load-use bubble
  assign exmem_flush = mem_redirect | (ex_busy & ~mem_stall);                  // md-busy bubble
  assign memwb_flush = mem_stall | trap_take;
endmodule
```

## 11. `rtl/core/muldiv_unit.sv`

```systemverilog
// =============================================================================
// muldiv_unit.sv - RV32M multiply / divide
//
//   MUL_IMPL = 0 : MUL/MULH/MULHSU/MULHU in ONE cycle (33x33 signed multiplier,
//                  fast, large).  Division is always iterative.
//   MUL_IMPL = 1 : iterative shift-add multiplier (33 cycles, small).
//   Division     : radix-2 restoring divider on magnitudes, 32 cycles; signs are
//                  fixed up at the end.  Corner cases follow the RISC-V spec:
//                    x/0  -> DIV/DIVU = all ones, REM/REMU = x
//                    INT_MIN / -1 -> DIV = INT_MIN, REM = 0   (falls out of the
//                                    magnitude arithmetic, no special case)
//
// Handshake with the core (instruction stays in EX until it is done):
//   req   : MD instruction is in EX (level, held)
//   ready : result valid this cycle (comb).  Core stalls while req & ~ready.
//   ack   : instruction leaves EX this cycle (frees the FSM from DONE)
//   flush : instruction killed (pipeline flush) -> FSM returns to IDLE
// =============================================================================
module muldiv_unit #(
  parameter int MUL_IMPL = 0
) (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        flush,
  input  logic        req,
  input  logic [2:0]  op,              // funct3: 000 MUL 001 MULH 010 MULHSU 011 MULHU 100 DIV 101 DIVU 110 REM 111 REMU
  input  logic [31:0] a,
  input  logic [31:0] b,
  input  logic        ack,
  output logic        ready,
  output logic [31:0] result
);
  typedef enum logic [1:0] { MD_IDLE, MD_RUN, MD_DONE } md_state_e;
  md_state_e   st;
  logic [2:0]  op_q;
  logic [5:0]  cnt;
  logic [65:0] acc;                    // mul: accumulator | div: {rem[31:0], quo[31:0]}
  logic [65:0] mcand;                  // iterative mul: sign-extended multiplicand (shifts left)
  logic [32:0] mplr;                   // iterative mul: multiplier (shifts right)
  logic [31:0] dvsr;                   // divisor magnitude
  logic        q_neg, r_neg;

  wire is_div    = op[2];
  wire fast_path = (MUL_IMPL == 0) && !is_div;

  // ---- operand preparation ---------------------------------------------------
  wire a_signed = (op[1:0] != 2'b11);            // MUL/MULH/MULHSU: rs1 signed
  wire b_signed = ~op[1];                        // MUL/MULH: rs2 signed
  wire signed [32:0] ma = {a_signed & a[31], a};
  wire signed [32:0] mb = {b_signed & b[31], b};
  wire signed [65:0] prod_f = ma * mb;           // used only when MUL_IMPL == 0

  wire        div_signed = ~op[0];               // DIV/REM signed, DIVU/REMU unsigned
  wire        a_neg      = div_signed & a[31];
  wire        b_neg      = div_signed & b[31];
  wire [31:0] abs_a      = a_neg ? (32'd0 - a) : a;
  wire [31:0] abs_b      = b_neg ? (32'd0 - b) : b;

  // ---- one iteration of restoring division / shift-add ----------------------
  wire [32:0] trial    = {acc[63:32], acc[31]};              // shift next dividend bit into remainder
  wire [32:0] diff     = trial - {1'b0, dvsr};
  wire        sub_ok   = ~diff[32];                          // remainder >= divisor
  wire [31:0] next_rem = sub_ok ? diff[31:0] : trial[31:0];
  wire [31:0] next_quo = {acc[30:0], sub_ok};
  // multiplier bit 32 carries negative weight (two's complement)
  wire [65:0] addend   = mplr[0] ? ((cnt == 6'd32) ? (66'd0 - mcand) : mcand) : 66'd0;

  always_ff @(posedge clk) begin
    if (!rst_n || flush) begin
      st <= MD_IDLE;
    end else begin
      case (st)
        MD_IDLE: if (req && !fast_path) begin
          st   <= MD_RUN;
          op_q <= op;
          cnt  <= 6'd0;
          if (is_div) begin
            acc   <= {34'd0, abs_a};
            dvsr  <= abs_b;
            q_neg <= div_signed & (a[31] ^ b[31]) & (b != 32'd0);   // x/0 -> all ones, not negated
            r_neg <= a_neg;
          end else if (MUL_IMPL != 0) begin
            acc   <= 66'd0;
            mcand <= {{33{ma[32]}}, ma};
            mplr  <= mb;
          end
        end

        MD_RUN: begin
          cnt <= cnt + 6'd1;
          if (op_q[2]) begin
            acc <= {2'b00, next_rem, next_quo};
            if (cnt == 6'd31) st <= MD_DONE;
          end else if (MUL_IMPL != 0) begin
            acc   <= acc + addend;
            mcand <= mcand << 1;
            mplr  <= mplr >> 1;
            if (cnt == 6'd32) st <= MD_DONE;
          end
        end

        MD_DONE: if (ack) st <= MD_IDLE;
        default: st <= MD_IDLE;
      endcase
    end
  end

  // ---- result / ready -----------------------------------------------------------
  always_comb begin
    if (fast_path) begin
      ready  = req;
      result = (op[1:0] == 2'b00) ? prod_f[31:0] : prod_f[63:32];
    end else begin
      ready = req & (st == MD_DONE);
      if (op_q[2])                                   // DIV/DIVU (bit1=0) or REM/REMU (bit1=1)
        result = op_q[1] ? (r_neg ? (32'd0 - acc[63:32]) : acc[63:32])
                         : (q_neg ? (32'd0 - acc[31:0])  : acc[31:0]);
      else
        result = (op_q[1:0] == 2'b00) ? acc[31:0] : acc[63:32];
    end
  end

`ifndef SYNTHESIS
  always @(posedge clk) if (rst_n) begin
    assert (!(ready && st == MD_RUN)) else $error("muldiv: ready during RUN");
  end
`endif
endmodule
```

## 12. `rtl/core/csr_file.sv`

```systemverilog
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
    if (chk_trap_q) begin
      assert (mepc_q == chk_pc_q) else $error("csr: mepc not captured on trap");
      assert (mie_q == 1'b0)      else $error("csr: MIE not cleared on trap");
    end
  end
`endif
endmodule
```

## 13. `rtl/core/branch_predictor.sv`

```systemverilog
// =============================================================================
// branch_predictor.sv - bht + btb + wrapper
//
// Variants (parameters):
//   ENABLE_BHT=0, ENABLE_BTB=0 : static not-taken (all branches resolve in EX)
//   ENABLE_BHT=1, ENABLE_BTB=0 : BHT direction only; the core redirects from ID
//                                (target = pc+imm computed in decode, 1-bubble penalty)
//   ENABLE_BHT=1, ENABLE_BTB=1 : IF-stage prediction (BTB target + BHT direction)
// ENABLE_BTB=1 requires ENABLE_BHT=1 (elaboration error otherwise).
// =============================================================================

// ------------------------------------------------------------------ 2-bit BHT
module bht #(
  parameter int ENTRIES = 64,
  parameter int IDX_W   = $clog2(ENTRIES)
) (
  input  logic        clk,
  input  logic        rst_n,
  input  logic [31:0] pc_a,   output logic taken_a,     // read port A (IF stage)
  input  logic [31:0] pc_b,   output logic taken_b,     // read port B (ID stage)
  input  logic        upd_en,
  input  logic [31:0] upd_pc,
  input  logic        upd_taken
);
  logic [1:0] ctr [ENTRIES];                             // 00/01 not-taken, 10/11 taken
  wire [IDX_W-1:0] ia = pc_a[IDX_W+1:2];
  wire [IDX_W-1:0] ib = pc_b[IDX_W+1:2];
  wire [IDX_W-1:0] iu = upd_pc[IDX_W+1:2];

  assign taken_a = ctr[ia][1];
  assign taken_b = ctr[ib][1];

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      for (int i = 0; i < ENTRIES; i++) ctr[i] <= 2'b01;  // weakly not-taken
    end else if (upd_en) begin
      if (upd_taken) begin
        if (ctr[iu] != 2'b11) ctr[iu] <= ctr[iu] + 2'd1;  // saturating increment
      end else begin
        if (ctr[iu] != 2'b00) ctr[iu] <= ctr[iu] - 2'd1;  // saturating decrement
      end
    end
  end
endmodule

// ------------------------------------------------------------------ direct-mapped BTB
module btb #(
  parameter int ENTRIES = 16,
  parameter int IDX_W   = $clog2(ENTRIES),
  parameter int TAG_W   = 30 - IDX_W
) (
  input  logic        clk,
  input  logic        rst_n,
  input  logic [31:0] lookup_pc,
  output logic        hit,
  output logic [29:0] target,        // word target (pc[31:2])
  output logic        uncond,        // JAL/JALR entry (always taken)
  input  logic        upd_en,
  input  logic [31:0] upd_pc,
  input  logic [31:0] upd_target,
  input  logic        upd_uncond
);
  logic              vld [ENTRIES];
  logic [TAG_W-1:0]  tag [ENTRIES];
  logic [29:0]       tgt [ENTRIES];
  logic              unc [ENTRIES];

  wire [IDX_W-1:0] il = lookup_pc[IDX_W+1:2];
  wire [IDX_W-1:0] iu = upd_pc[IDX_W+1:2];

  assign hit    = vld[il] & (tag[il] == lookup_pc[31:IDX_W+2]);
  assign target = tgt[il];
  assign uncond = unc[il];

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      for (int i = 0; i < ENTRIES; i++) vld[i] <= 1'b0;
    end else if (upd_en) begin
      vld[iu] <= 1'b1;
    end
    if (upd_en) begin                                     // payload needs no reset
      tag[iu] <= upd_pc[31:IDX_W+2];
      tgt[iu] <= upd_target[31:2];
      unc[iu] <= upd_uncond;
    end
  end
endmodule

// ------------------------------------------------------------------ wrapper
module branch_predictor #(
  parameter bit ENABLE_BHT  = 1'b1,
  parameter bit ENABLE_BTB  = 1'b1,
  parameter int BHT_ENTRIES = 64,
  parameter int BTB_ENTRIES = 16
) (
  input  logic        clk,
  input  logic        rst_n,
  // IF-stage lookup (BTB mode)
  input  logic [31:0] if_pc,
  output logic        if_pred_taken,
  output logic [31:0] if_pred_target,
  // ID-stage lookup (BHT-only mode)
  input  logic [31:0] id_pc,
  output logic        id_bht_taken,
  // EX-stage training
  input  logic        upd_valid,      // resolved control-flow instruction (branch/jal/jalr)
  input  logic        upd_is_cond,    // conditional branch
  input  logic [31:0] upd_pc,
  input  logic        upd_taken,
  input  logic [31:0] upd_target
);
  generate
    if (ENABLE_BTB && !ENABLE_BHT) begin : g_bad_cfg
      $error("branch_predictor: ENABLE_BTB=1 requires ENABLE_BHT=1");
    end
  endgenerate

  logic bht_a;

  generate
    if (ENABLE_BHT) begin : g_bht
      bht #(.ENTRIES(BHT_ENTRIES)) u_bht (
        .clk(clk), .rst_n(rst_n),
        .pc_a(if_pc), .taken_a(bht_a),
        .pc_b(id_pc), .taken_b(id_bht_taken),
        .upd_en(upd_valid & upd_is_cond), .upd_pc(upd_pc), .upd_taken(upd_taken)
      );
    end else begin : g_nobht
      assign bht_a        = 1'b0;
      assign id_bht_taken = 1'b0;
    end

    if (ENABLE_BTB) begin : g_btb
      logic        hit, unc;
      logic [29:0] tgt;
      btb #(.ENTRIES(BTB_ENTRIES)) u_btb (
        .clk(clk), .rst_n(rst_n),
        .lookup_pc(if_pc), .hit(hit), .target(tgt), .uncond(unc),
        .upd_en(upd_valid & upd_taken),                   // allocate on taken control flow only
        .upd_pc(upd_pc), .upd_target(upd_target), .upd_uncond(~upd_is_cond)
      );
      assign if_pred_taken  = hit & (unc | bht_a);
      assign if_pred_target = {tgt, 2'b00};
    end else begin : g_nobtb
      assign if_pred_taken  = 1'b0;
      assign if_pred_target = 32'd0;
    end
  endgenerate
endmodule
```

## 14. `rtl/core/rv32im_core.sv`

```systemverilog
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
  assign id_ctrl = id_exc ? '0 : dctrl;               // excepting instruction becomes a side-effect-free bubble

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
    exmem_d.ctrl       = exmem_d.exc ? '0 : idex_q.ctrl;
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
```

## 15. `rtl/cache/cache_arrays.sv`

```systemverilog
// =============================================================================
// cache_arrays.sv - tag + data storage shared by the I-cache and D-cache
//   Both arrays have combinational (asynchronous) reads so a hit costs zero
//   extra pipeline cycles.  For a hard-macro SRAM flow, replace the data array
//   with a synchronous-read macro and add one fetch/MEM wait state.
// =============================================================================

// ------------------------------------------------------------------ tags + valid bits
module cache_tag_array #(
  parameter int LINES = 64,
  parameter int TAG_W = 20,
  parameter int IDX_W = $clog2(LINES)
) (
  input  logic             clk,
  input  logic             rst_n,
  input  logic             inval_all,               // clear every valid bit (FENCE.I)
  input  logic [IDX_W-1:0] rd_idx,
  output logic [TAG_W-1:0] rd_tag,
  output logic             rd_valid,
  input  logic             set_en,                  // install tag + set valid
  input  logic [IDX_W-1:0] set_idx,
  input  logic [TAG_W-1:0] set_tag,
  input  logic             clr_en,                  // clear one valid bit (refill start)
  input  logic [IDX_W-1:0] clr_idx
);
  logic [TAG_W-1:0] tags  [LINES];                  // no reset needed (guarded by valid)
  logic [LINES-1:0] valid;

  assign rd_tag   = tags[rd_idx];
  assign rd_valid = valid[rd_idx];

  always_ff @(posedge clk) begin
    if (!rst_n || inval_all) valid <= '0;
    else begin
      if (clr_en) valid[clr_idx] <= 1'b0;
      if (set_en) valid[set_idx] <= 1'b1;           // set wins if both (never simultaneous)
    end
    if (set_en) tags[set_idx] <= set_tag;
  end
endmodule

// ------------------------------------------------------------------ data words
module cache_data_array #(
  parameter int LINES  = 64,
  parameter int WORDS  = 4,                          // words per line (power of 2, >= 2)
  parameter int IDX_W  = $clog2(LINES),
  parameter int WORD_W = $clog2(WORDS)
) (
  input  logic              clk,
  input  logic [IDX_W-1:0]  rd_idx,
  input  logic [WORD_W-1:0] rd_word,
  output logic [31:0]       rd_data,
  input  logic              wr_en,
  input  logic [IDX_W-1:0]  wr_idx,
  input  logic [WORD_W-1:0] wr_word,
  input  logic [31:0]       wr_data,
  input  logic [3:0]        wr_be
);
  logic [31:0] mem [LINES*WORDS];

  assign rd_data = mem[{rd_idx, rd_word}];

  always_ff @(posedge clk) begin
    if (wr_en) begin
      for (int b = 0; b < 4; b++)
        if (wr_be[b]) mem[{wr_idx, wr_word}][8*b +: 8] <= wr_data[8*b +: 8];
    end
  end
endmodule
```

## 16. `rtl/cache/icache.sv`

```systemverilog
// =============================================================================
// icache.sv - direct-mapped, read-only instruction cache
//
// CPU side : cpu_addr is presented every cycle; cpu_ready=1 means cpu_rdata is
//            the instruction for THIS cpu_addr (combinational hit).  The cache is
//            stateless w.r.t. the CPU: a redirect just changes cpu_addr.
// Refill   : one INCR burst of LINE_BYTES/4 words through the native request port
//            (axi4_master).  The victim line is invalidated when the refill
//            starts, so partially-written lines can never hit.
// Errors   : a bus error during refill leaves the line invalid and raises
//            cpu_err (with cpu_ready) for addresses in that line until a
//            different line is requested or FENCE.I (inval).
// FENCE.I  : inval clears all lines; an in-flight refill is marked "kill" so it
//            cannot install possibly stale data.
// ENABLE=0 : degenerate 1-word fetch buffer (no cache), for PPA comparisons.
// =============================================================================
module icache import rv32im_pkg::*; #(
  parameter bit ENABLE     = 1'b1,
  parameter int LINES      = 64,       // power of 2, >= 2
  parameter int LINE_BYTES = 16        // power of 2, >= 8
) (
  input  logic        clk,
  input  logic        rst_n,
  // CPU side
  input  logic [31:0] cpu_addr,
  output logic [31:0] cpu_rdata,
  output logic        cpu_ready,
  output logic        cpu_err,
  input  logic        inval,
  // native request port to axi4_master (read only)
  output logic        req_valid,
  input  logic        req_ready,
  output logic [31:0] req_addr,
  output logic [7:0]  req_len,
  input  logic        rsp_valid,
  input  logic [31:0] rsp_data,
  input  logic        rsp_last,
  input  logic        rsp_err,
  output logic        miss_evt
);
  generate
  if (ENABLE) begin : g_cache
    localparam int WORDS  = LINE_BYTES / 4;
    localparam int OFF_W  = $clog2(LINE_BYTES);
    localparam int IDX_W  = $clog2(LINES);
    localparam int WORD_W = $clog2(WORDS);
    localparam int TAG_W  = 32 - OFF_W - IDX_W;

    // ---- address split ---------------------------------------------------------
    logic [IDX_W-1:0]  idx;
    logic [TAG_W-1:0]  tag;
    logic [WORD_W-1:0] word;
    assign idx  = cpu_addr[OFF_W +: IDX_W];
    assign tag  = cpu_addr[31 -: TAG_W];
    assign word = cpu_addr[2 +: WORD_W];

    // ---- state -----------------------------------------------------------------
    cache_state_e      state;
    logic [IDX_W-1:0]  miss_idx;
    logic [TAG_W-1:0]  miss_tag;
    logic [WORD_W-1:0] beat;
    logic              fill_err, kill, err_pending;
    logic [31-OFF_W:0] err_line;

    // ---- arrays ----------------------------------------------------------------
    logic [TAG_W-1:0] rd_tag;
    logic             rd_valid, tag_set, tag_clr, hit, err_hit, fill_we;

    assign hit     = rd_valid & (rd_tag == tag);
    assign err_hit = err_pending & (cpu_addr[31:OFF_W] == err_line);
    assign cpu_ready = hit | err_hit;
    assign cpu_err   = err_hit & ~hit;

    assign fill_we = (state == CS_FILL) & rsp_valid;
    assign tag_set = fill_we & rsp_last & ~fill_err & ~rsp_err & ~kill & ~inval;
    assign tag_clr = (state == CS_IDLE) & ~cpu_ready;           // refill starts: drop victim line

    cache_tag_array #(.LINES(LINES), .TAG_W(TAG_W)) u_tags (
      .clk(clk), .rst_n(rst_n), .inval_all(inval),
      .rd_idx(idx), .rd_tag(rd_tag), .rd_valid(rd_valid),
      .set_en(tag_set), .set_idx(miss_idx), .set_tag(miss_tag),
      .clr_en(tag_clr), .clr_idx(idx)
    );
    cache_data_array #(.LINES(LINES), .WORDS(WORDS)) u_data (
      .clk(clk),
      .rd_idx(idx), .rd_word(word), .rd_data(cpu_rdata),
      .wr_en(fill_we), .wr_idx(miss_idx), .wr_word(beat), .wr_data(rsp_data), .wr_be(4'hF)
    );

    // ---- refill request ------------------------------------------------------------
    assign req_valid = (state == CS_REQ);
    assign req_addr  = {miss_tag, miss_idx, {OFF_W{1'b0}}};    // line-aligned
    assign req_len   = 8'(WORDS - 1);
    assign miss_evt  = (state == CS_IDLE) & ~cpu_ready;

    // ---- FSM -----------------------------------------------------------------------
    always_ff @(posedge clk) begin
      if (!rst_n) begin
        state <= CS_IDLE; err_pending <= 1'b0; kill <= 1'b0; fill_err <= 1'b0;
      end else begin
        if (inval) begin
          err_pending <= 1'b0;
          if (state != CS_IDLE) kill <= 1'b1;
        end
        case (state)
          CS_IDLE: if (!cpu_ready) begin                       // miss -> start refill
            err_pending <= 1'b0;                               // stale error for another line
            miss_idx    <= idx;
            miss_tag    <= tag;
            beat        <= '0;
            fill_err    <= 1'b0;
            kill        <= 1'b0;
            state       <= CS_REQ;
          end
          CS_REQ: if (req_ready) state <= CS_FILL;             // master accepted the command
          CS_FILL: if (rsp_valid) begin
            beat <= beat + 1'b1;
            if (rsp_err) fill_err <= 1'b1;
            if (rsp_last) begin
              state <= CS_IDLE;
              if ((fill_err | rsp_err) & ~kill & ~inval) begin
                err_pending <= 1'b1;
                err_line    <= {miss_tag, miss_idx};
              end
            end
          end
          default: state <= CS_IDLE;
        endcase
      end
    end

  end else begin : g_bypass
    // ---- 1-word fetch buffer (no cache) ---------------------------------------------
    cache_state_e state;
    logic [31:0]  fb_addr, fb_data;
    logic         fb_valid, fb_err, kill;

    assign cpu_ready = fb_valid & (fb_addr == {cpu_addr[31:2], 2'b00});
    assign cpu_rdata = fb_data;
    assign cpu_err   = cpu_ready & fb_err;
    assign req_valid = (state == CS_REQ);
    assign req_addr  = fb_addr;
    assign req_len   = 8'd0;
    assign miss_evt  = (state == CS_IDLE) & ~cpu_ready;

    always_ff @(posedge clk) begin
      if (!rst_n) begin
        state <= CS_IDLE; fb_valid <= 1'b0; kill <= 1'b0;
      end else begin
        if (inval) begin
          fb_valid <= 1'b0;
          if (state != CS_IDLE) kill <= 1'b1;
        end
        case (state)
          CS_IDLE: if (!cpu_ready) begin
            fb_addr  <= {cpu_addr[31:2], 2'b00};
            fb_valid <= 1'b0;
            kill     <= 1'b0;
            state    <= CS_REQ;
          end
          CS_REQ:  if (req_ready) state <= CS_FILL;
          CS_FILL: if (rsp_valid) begin
            fb_data  <= rsp_data;
            fb_err   <= rsp_err;
            fb_valid <= ~kill & ~inval;
            state    <= CS_IDLE;
          end
          default: state <= CS_IDLE;
        endcase
      end
    end
  end
  endgenerate

`ifndef SYNTHESIS
  always @(posedge clk) if (rst_n) begin
    assert (!(cpu_err && !cpu_ready)) else $error("icache: err without ready");
  end
`endif
endmodule
```

## 17. `rtl/cache/dcache.sv`

```systemverilog
// =============================================================================
// dcache.sv - direct-mapped, write-through / no-write-allocate data cache
//
// CPU side (request held stable by the core until cpu_ready):
//   * cacheable load hit  : cpu_ready=1 in the same cycle (combinational read)
//   * load miss           : refill one line (INCR burst), then re-hit
//   * store (hit or miss) : single-beat write-through; cpu_ready after the B
//                           response.  On a hit the cached word is updated only
//                           after the bus write succeeded (keeps cache == memory,
//                           e.g. stores to ROM fault instead of corrupting the cache)
//   * peripheral space (0x4xxx_xxxx) or ENABLE=0 : uncached single-beat accesses
//   * bus error           : cpu_err with cpu_ready (core -> load/store access fault)
// Completion of uncached / store / error cases is presented for exactly one
// cycle in CS_DONE (registered, keeps AXI timing off the core's stall logic).
// cpu_busy = FSM active; the core does not take interrupts while busy.
// =============================================================================
module dcache import rv32im_pkg::*; #(
  parameter bit ENABLE     = 1'b1,
  parameter int LINES      = 64,       // power of 2, >= 2
  parameter int LINE_BYTES = 16        // power of 2, >= 8
) (
  input  logic        clk,
  input  logic        rst_n,
  // CPU side
  input  logic        cpu_req,
  input  logic        cpu_we,
  input  logic [31:0] cpu_addr,
  input  logic [31:0] cpu_wdata,       // replicated across byte lanes by the core
  input  logic [3:0]  cpu_be,
  output logic [31:0] cpu_rdata,       // full aligned word; core extracts byte/half
  output logic        cpu_ready,
  output logic        cpu_err,
  output logic        cpu_busy,
  // native request port to axi4_master
  output logic        req_valid,
  input  logic        req_ready,
  output logic        req_write,
  output logic [31:0] req_addr,
  output logic [7:0]  req_len,
  output logic [31:0] req_wdata,
  output logic [3:0]  req_wstrb,
  input  logic        rsp_valid,
  input  logic [31:0] rsp_data,
  input  logic        rsp_last,
  input  logic        rsp_err,
  output logic        miss_evt
);
  localparam int WORDS  = LINE_BYTES / 4;
  localparam int OFF_W  = $clog2(LINE_BYTES);
  localparam int IDX_W  = $clog2(LINES);
  localparam int WORD_W = $clog2(WORDS);
  localparam int TAG_W  = 32 - OFF_W - IDX_W;

  typedef enum logic [1:0] { K_REFILL = 2'd0, K_UNC_RD = 2'd1, K_WR = 2'd2 } dc_op_e;

  // ---- address split / cacheability ----------------------------------------------
  logic [IDX_W-1:0]  idx;
  logic [TAG_W-1:0]  tag;
  logic [WORD_W-1:0] word;
  logic              cacheable, hit;
  assign idx       = cpu_addr[OFF_W +: IDX_W];
  assign tag       = cpu_addr[31 -: TAG_W];
  assign word      = cpu_addr[2 +: WORD_W];
  assign cacheable = ENABLE & (cpu_addr[31:28] != REGION_PERIPH);

  // ---- FSM state -----------------------------------------------------------------
  cache_state_e      state;
  dc_op_e            op_q;
  logic [31:0]       addr_q, wdata_q, done_rdata;
  logic [3:0]        be_q;
  logic              hit_q, fill_err, done_err;
  logic [WORD_W-1:0] beat;

  // ---- arrays (only when ENABLE) ---------------------------------------------------
  logic [TAG_W-1:0]  rd_tag;
  logic              rd_valid, tag_set, tag_clr, arr_we;
  logic [31:0]       arr_rdata, arr_wdata;
  logic [3:0]        arr_wbe;
  logic [WORD_W-1:0] arr_wword;

  wire [IDX_W-1:0] q_idx  = addr_q[OFF_W +: IDX_W];
  wire [TAG_W-1:0] q_tag  = addr_q[31 -: TAG_W];
  wire [WORD_W-1:0] q_word = addr_q[2 +: WORD_W];

  wire resp_fire = (state == CS_FILL) & rsp_valid;
  assign arr_we    = resp_fire & ((op_q == K_REFILL) | ((op_q == K_WR) & ~rsp_err & hit_q));
  assign arr_wword = (op_q == K_REFILL) ? beat : q_word;
  assign arr_wdata = (op_q == K_REFILL) ? rsp_data : wdata_q;
  assign arr_wbe   = (op_q == K_REFILL) ? 4'hF : be_q;
  assign tag_set   = resp_fire & (op_q == K_REFILL) & rsp_last & ~fill_err & ~rsp_err;
  assign tag_clr   = (state == CS_IDLE) & cpu_req & ~cpu_we & cacheable & ~hit;   // refill start

  generate
    if (ENABLE) begin : g_arr
      cache_tag_array #(.LINES(LINES), .TAG_W(TAG_W)) u_tags (
        .clk(clk), .rst_n(rst_n), .inval_all(1'b0),
        .rd_idx(idx), .rd_tag(rd_tag), .rd_valid(rd_valid),
        .set_en(tag_set), .set_idx(q_idx), .set_tag(q_tag),
        .clr_en(tag_clr), .clr_idx(idx)
      );
      cache_data_array #(.LINES(LINES), .WORDS(WORDS)) u_data (
        .clk(clk),
        .rd_idx(idx), .rd_word(word), .rd_data(arr_rdata),
        .wr_en(arr_we), .wr_idx(q_idx), .wr_word(arr_wword), .wr_data(arr_wdata), .wr_be(arr_wbe)
      );
    end else begin : g_noarr
      assign rd_tag = '0;
      assign rd_valid = 1'b0;
      assign arr_rdata = 32'd0;
    end
  endgenerate

  assign hit = cacheable & rd_valid & (rd_tag == tag);

  // ---- CPU-facing outputs ----------------------------------------------------------------
  assign cpu_busy  = (state != CS_IDLE);
  always_comb begin
    cpu_ready = 1'b0;
    cpu_err   = 1'b0;
    cpu_rdata = arr_rdata;
    case (state)
      CS_IDLE: cpu_ready = cpu_req & ~cpu_we & hit;          // load hit
      CS_DONE: begin cpu_ready = 1'b1; cpu_err = done_err; cpu_rdata = done_rdata; end
      default: ;
    endcase
  end

  // ---- AXI-side request -----------------------------------------------------------------------
  assign req_valid = (state == CS_REQ);
  assign req_write = (op_q == K_WR);
  assign req_addr  = (op_q == K_REFILL) ? {addr_q[31:OFF_W], {OFF_W{1'b0}}} : {addr_q[31:2], 2'b00};
  assign req_len   = (op_q == K_REFILL) ? 8'(WORDS - 1) : 8'd0;
  assign req_wdata = wdata_q;
  assign req_wstrb = be_q;
  assign miss_evt  = tag_clr;

  // ---- FSM --------------------------------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      state <= CS_IDLE; fill_err <= 1'b0; done_err <= 1'b0;
    end else begin
      case (state)
        CS_IDLE: if (cpu_req) begin
          addr_q  <= cpu_addr;
          wdata_q <= cpu_wdata;
          be_q    <= cpu_be;
          hit_q   <= hit;
          beat    <= '0;
          fill_err <= 1'b0;
          if (cpu_we) begin                      // store: write-through, no allocate
            op_q <= K_WR;     state <= CS_REQ;
          end else if (!cacheable) begin         // peripheral / cache disabled
            op_q <= K_UNC_RD; state <= CS_REQ;
          end else if (!hit) begin               // load miss
            op_q <= K_REFILL; state <= CS_REQ;
          end                                    // load hit: served combinationally
        end

        CS_REQ: if (req_ready) state <= CS_FILL;

        CS_FILL: if (rsp_valid) begin
          case (op_q)
            K_REFILL: begin
              beat <= beat + 1'b1;
              if (rsp_err) fill_err <= 1'b1;
              if (rsp_last) begin
                if (fill_err | rsp_err) begin done_err <= 1'b1; done_rdata <= 32'd0; state <= CS_DONE; end
                else                    state <= CS_IDLE;            // next cycle re-hits
              end
            end
            K_UNC_RD: begin done_rdata <= rsp_data; done_err <= rsp_err; state <= CS_DONE; end
            default:  begin done_rdata <= 32'd0;    done_err <= rsp_err; state <= CS_DONE; end  // K_WR
          endcase
        end

        CS_DONE: state <= CS_IDLE;
        default: state <= CS_IDLE;
      endcase
    end
  end

`ifndef SYNTHESIS
  always @(posedge clk) if (rst_n) begin
    assert (!(cpu_ready && cpu_err && state != CS_DONE)) else $error("dcache: err outside DONE");
    assert (!(req_valid && req_write && req_wstrb == 4'b0)) else $error("dcache: write with empty strobes");
  end
`endif
endmodule
```

## 18. `rtl/bus/axi4_master.sv`

```systemverilog
// =============================================================================
// axi4_master.sv - native request -> reduced-AXI4 master (one transaction at a time)
//
// Native side:
//   req_valid/req_ready  : command handshake (accepted only in IDLE)
//   read  : INCR burst of req_len+1 words        -> rsp_valid per R beat (rsp_last on RLAST)
//   write : single beat (AW+W together)          -> one rsp_valid on B (rsp_last=1)
//   rsp_err = RRESP/BRESP != OKAY.  The consumer must always accept rsp_valid
//   (RREADY is tied to "in R state").
// READ_ONLY=1 removes the write path (instruction-side master).
// All AXI outputs come straight from registers/state -> no combinational path
// from the AXI inputs to AXI outputs.
// =============================================================================
module axi4_master import rv32im_pkg::*; #(
  parameter bit READ_ONLY = 1'b0
) (
  input  logic        clk,
  input  logic        rst_n,
  // native command
  input  logic        req_valid,
  output logic        req_ready,
  input  logic        req_write,
  input  logic [31:0] req_addr,
  input  logic [7:0]  req_len,
  input  logic [31:0] req_wdata,
  input  logic [3:0]  req_wstrb,
  // native response
  output logic        rsp_valid,
  output logic [31:0] rsp_data,
  output logic        rsp_last,
  output logic        rsp_err,
  // AXI
  output axi_req_t    m_req,
  input  axi_rsp_t    m_rsp
);
  typedef enum logic [2:0] { M_IDLE, M_AR, M_R, M_W, M_B } m_state_e;
  m_state_e    st;
  logic [31:0] addr_q, wdata_q;
  logic [7:0]  len_q;
  logic [3:0]  wstrb_q;
  logic        aw_done, w_done;

  wire aw_hs = m_req.awvalid & m_rsp.awready;
  wire w_hs  = m_req.wvalid  & m_rsp.wready;

  assign req_ready = (st == M_IDLE);

  always_comb begin
    m_req         = AXI_REQ_IDLE;
    m_req.araddr  = addr_q;   m_req.arlen = len_q;  m_req.arsize = 3'b010;  m_req.arburst = AXI_BURST_INCR;
    m_req.awaddr  = addr_q;   m_req.awlen = 8'd0;   m_req.awsize = 3'b010;  m_req.awburst = AXI_BURST_INCR;
    m_req.wdata   = wdata_q;  m_req.wstrb = wstrb_q; m_req.wlast = 1'b1;
    m_req.arvalid = (st == M_AR);
    m_req.rready  = (st == M_R);
    m_req.awvalid = (st == M_W) & ~aw_done;
    m_req.wvalid  = (st == M_W) & ~w_done;
    m_req.bready  = (st == M_B);

    rsp_valid = ((st == M_R) & m_rsp.rvalid) | ((st == M_B) & m_rsp.bvalid);
    rsp_data  = m_rsp.rdata;
    rsp_last  = (st == M_B) | m_rsp.rlast;
    rsp_err   = (st == M_B) ? (m_rsp.bresp != AXI_RESP_OKAY) : (m_rsp.rresp != AXI_RESP_OKAY);
  end

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      st <= M_IDLE; aw_done <= 1'b0; w_done <= 1'b0;
    end else begin
      case (st)
        M_IDLE: if (req_valid) begin
          addr_q  <= req_addr;
          len_q   <= req_len;
          wdata_q <= req_wdata;
          wstrb_q <= req_wstrb;
          aw_done <= 1'b0;
          w_done  <= 1'b0;
          st      <= (req_write && !READ_ONLY) ? M_W : M_AR;
        end
        M_AR: if (m_rsp.arready) st <= M_R;
        M_R:  if (m_rsp.rvalid && m_rsp.rlast) st <= M_IDLE;
        M_W: begin                                   // AW and W handshakes complete independently
          if (aw_hs) aw_done <= 1'b1;
          if (w_hs)  w_done  <= 1'b1;
          if ((aw_done | aw_hs) & (w_done | w_hs)) st <= M_B;
        end
        M_B:  if (m_rsp.bvalid) st <= M_IDLE;
        default: st <= M_IDLE;
      endcase
    end
  end

`ifndef SYNTHESIS
  // AXI stability rule: once valid is raised it stays (with stable payload) until ready
  logic        p_arv, p_arr, p_awv, p_awr;
  logic [31:0] p_araddr, p_awaddr;
  always @(posedge clk) begin
    if (rst_n) begin
      if (p_arv && !p_arr) assert (m_req.arvalid && m_req.araddr == p_araddr) else $error("axi_master: AR not stable");
      if (p_awv && !p_awr) assert (m_req.awvalid && m_req.awaddr == p_awaddr) else $error("axi_master: AW not stable");
    end
    p_arv <= m_req.arvalid; p_arr <= m_rsp.arready; p_araddr <= m_req.araddr;
    p_awv <= m_req.awvalid; p_awr <= m_rsp.awready; p_awaddr <= m_req.awaddr;
  end
`endif
endmodule
```

## 19. `rtl/bus/axi4_interconnect.sv`

```systemverilog
// =============================================================================
// axi4_interconnect.sv - 2 masters (I$, D$) x 3 slaves (ROM, SRAM, PERIPH) + DECERR
//
// Shared-bus style: one master owns the fabric for the whole transaction
// (address decode is registered at grant time), which keeps the design small
// and deadlock-free.  Arbitration: round-robin between M0 (I$) and M1 (D$).
// A master must not raise ARVALID and AWVALID simultaneously (our masters never do).
//
// Address decode (address[31:28]):
//   0x0 -> S0 boot ROM   0x1 -> S1 SRAM   0x4 -> S2 peripherals   else -> DECERR
// Cost: 1 arbitration cycle per transaction.
// =============================================================================

// ------------------------------------------------------------------ error responder
module axi_err_slave import rv32im_pkg::*; #(
  parameter logic [1:0] RESP = AXI_RESP_DECERR
) (
  input  logic     clk,
  input  logic     rst_n,
  input  axi_req_t req,
  output axi_rsp_t rsp
);
  typedef enum logic [1:0] { E_IDLE, E_RD, E_WR, E_B } e_state_t;
  e_state_t   st;
  logic [7:0] cnt;

  always_comb begin
    rsp = AXI_RSP_IDLE;
    case (st)
      E_IDLE: begin
        rsp.arready = req.arvalid;
        rsp.awready = req.awvalid & ~req.arvalid;
      end
      E_RD: begin rsp.rvalid = 1'b1; rsp.rresp = RESP; rsp.rlast = (cnt == 8'd0); end
      E_WR: rsp.wready = 1'b1;                              // swallow every write beat
      E_B:  begin rsp.bvalid = 1'b1; rsp.bresp = RESP; end
      default: ;
    endcase
  end

  always_ff @(posedge clk) begin
    if (!rst_n) st <= E_IDLE;
    else begin
      case (st)
        E_IDLE: if (req.arvalid)      begin cnt <= req.arlen; st <= E_RD; end
                else if (req.awvalid) st <= E_WR;
        E_RD:   if (req.rready) begin
                  if (cnt == 8'd0) st <= E_IDLE; else cnt <= cnt - 8'd1;
                end
        E_WR:   if (req.wvalid && req.wlast) st <= E_B;
        E_B:    if (req.bready) st <= E_IDLE;
        default: st <= E_IDLE;
      endcase
    end
  end
endmodule

// ------------------------------------------------------------------ interconnect
module axi4_interconnect import rv32im_pkg::*; (
  input  logic     clk,
  input  logic     rst_n,
  input  axi_req_t m0_req,  output axi_rsp_t m0_rsp,      // instruction side
  input  axi_req_t m1_req,  output axi_rsp_t m1_rsp,      // data side
  output axi_req_t s0_req,  input  axi_rsp_t s0_rsp,      // boot ROM
  output axi_req_t s1_req,  input  axi_rsp_t s1_rsp,      // SRAM
  output axi_req_t s2_req,  input  axi_rsp_t s2_rsp       // peripheral bridge
);
  // ---- grant state --------------------------------------------------------------
  logic       act, gm, gwr, last_gm;
  logic [1:0] gs;                                          // 0 ROM, 1 SRAM, 2 PERIPH, 3 DECERR

  function automatic logic [1:0] decode(input logic [31:0] a);
    case (a[31:28])
      REGION_ROM:    decode = 2'd0;
      REGION_SRAM:   decode = 2'd1;
      REGION_PERIPH: decode = 2'd2;
      default:       decode = 2'd3;
    endcase
  endfunction

  // ---- arbitration (only used while idle) -----------------------------------------
  logic     m0_want, m1_want, pick_m1;
  axi_req_t pick_req, mreq, e_req;
  axi_rsp_t mrsp, e_rsp;

  assign m0_want  = m0_req.arvalid | m0_req.awvalid;
  assign m1_want  = m1_req.arvalid | m1_req.awvalid;
  assign pick_m1  = m1_want & (~m0_want | ~last_gm);       // round-robin when both want
  assign pick_req = pick_m1 ? m1_req : m0_req;

  assign mreq = gm ? m1_req : m0_req;                      // granted master's request

  logic done;
  assign done = gwr ? (mrsp.bvalid & mreq.bready)
                    : (mrsp.rvalid & mreq.rready & mrsp.rlast);

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      act <= 1'b0; gm <= 1'b0; gwr <= 1'b0; gs <= 2'd0; last_gm <= 1'b1;
    end else if (!act) begin
      if (m0_want | m1_want) begin
        act     <= 1'b1;
        gm      <= pick_m1;
        last_gm <= pick_m1;
        gwr     <= ~pick_req.arvalid & pick_req.awvalid;                       // reads have priority
        gs      <= decode(pick_req.arvalid ? pick_req.araddr : pick_req.awaddr);
      end
    end else if (done) begin
      act <= 1'b0;
    end
  end

  // ---- request routing --------------------------------------------------------------
  assign s0_req = (act && gs == 2'd0) ? mreq : AXI_REQ_IDLE;
  assign s1_req = (act && gs == 2'd1) ? mreq : AXI_REQ_IDLE;
  assign s2_req = (act && gs == 2'd2) ? mreq : AXI_REQ_IDLE;
  assign e_req  = (act && gs == 2'd3) ? mreq : AXI_REQ_IDLE;

  // ---- response routing ---------------------------------------------------------------
  always_comb begin
    case (gs)
      2'd0:    mrsp = s0_rsp;
      2'd1:    mrsp = s1_rsp;
      2'd2:    mrsp = s2_rsp;
      default: mrsp = e_rsp;
    endcase
  end
  assign m0_rsp = (act && !gm) ? mrsp : AXI_RSP_IDLE;
  assign m1_rsp = (act &&  gm) ? mrsp : AXI_RSP_IDLE;

  axi_err_slave #(.RESP(AXI_RESP_DECERR)) u_decerr (.clk(clk), .rst_n(rst_n), .req(e_req), .rsp(e_rsp));

`ifndef SYNTHESIS
  always @(posedge clk) if (rst_n) begin
    assert (!(m0_req.arvalid && m0_req.awvalid)) else $error("axi_ic: M0 raised AR and AW together");
    assert (!(m1_req.arvalid && m1_req.awvalid)) else $error("axi_ic: M1 raised AR and AW together");
  end
`endif
endmodule
```

## 20. `rtl/bus/axi_to_apb.sv`

```systemverilog
// =============================================================================
// axi_to_apb.sv - AXI4-Lite-style slave -> APB4 master bridge
//
//   * single-beat only (arlen/awlen must be 0; the D-cache never bursts to MMIO)
//   * a write is accepted when AWVALID and WVALID are both present
//   * peripheral select = address[15:12] (one-hot psel, NUM_PERIPH slots);
//     an unmapped slot returns DECERR without an APB access
//   * APB SETUP -> ACCESS (wait for PREADY) -> AXI response; PSLVERR -> SLVERR
//   * reads have priority over writes
// =============================================================================
module axi_to_apb import rv32im_pkg::*; #(
  parameter int NUM_PERIPH = 4
) (
  input  logic                        clk,
  input  logic                        rst_n,
  input  axi_req_t                    s_req,
  output axi_rsp_t                    s_rsp,
  // APB master
  output logic [NUM_PERIPH-1:0]       psel,
  output logic                        penable,
  output logic                        pwrite,
  output logic [11:0]                 paddr,
  output logic [31:0]                 pwdata,
  output logic [3:0]                  pstrb,
  input  logic [NUM_PERIPH*32-1:0]    prdata,          // flattened per-peripheral read data
  input  logic [NUM_PERIPH-1:0]       pready,
  input  logic [NUM_PERIPH-1:0]       pslverr
);
  typedef enum logic [2:0] { B_IDLE, B_SETUP, B_ACCESS, B_RESP_R, B_RESP_W } b_state_e;
  b_state_e    st;
  logic [31:0] addr_q, wdata_q, rdata_q;
  logic [3:0]  strb_q;
  logic        wr_q;
  logic [1:0]  resp_q;

  localparam logic [3:0] NP = 4'(NUM_PERIPH);
  wire [3:0] sel      = addr_q[15:12];
  wire       sel_ok   = (sel < NP);
  wire       take_rd  = (st == B_IDLE) & s_req.arvalid;
  wire       take_wr  = (st == B_IDLE) & ~s_req.arvalid & s_req.awvalid & s_req.wvalid;

  // ---- APB outputs -----------------------------------------------------------------
  always_comb begin
    psel    = '0;
    if (st == B_SETUP || st == B_ACCESS) psel[sel[$clog2(NUM_PERIPH)-1:0]] = sel_ok;
    penable = (st == B_ACCESS);
    pwrite  = wr_q;
    paddr   = addr_q[11:0];
    pwdata  = wdata_q;
    pstrb   = wr_q ? strb_q : 4'b0000;
  end

  // ---- AXI responses --------------------------------------------------------------------
  always_comb begin
    s_rsp         = AXI_RSP_IDLE;
    s_rsp.arready = take_rd;
    s_rsp.awready = take_wr;
    s_rsp.wready  = take_wr;
    s_rsp.rvalid  = (st == B_RESP_R);
    s_rsp.rdata   = rdata_q;
    s_rsp.rresp   = resp_q;
    s_rsp.rlast   = 1'b1;
    s_rsp.bvalid  = (st == B_RESP_W);
    s_rsp.bresp   = resp_q;
  end

  // ---- read-data mux (selected slot) --------------------------------------------------------
  logic [31:0] sel_rdata;
  logic        sel_ready, sel_err;
  always_comb begin
    sel_rdata = 32'd0; sel_ready = 1'b1; sel_err = 1'b0;
    for (int i = 0; i < NUM_PERIPH; i++) begin
      if (sel == i[3:0]) begin
        sel_rdata = prdata[32*i +: 32];
        sel_ready = pready[i];
        sel_err   = pslverr[i];
      end
    end
  end

  always_ff @(posedge clk) begin
    if (!rst_n) st <= B_IDLE;
    else begin
      case (st)
        B_IDLE: begin
          if (take_rd) begin
            addr_q <= s_req.araddr; wr_q <= 1'b0; st <= B_SETUP;
          end else if (take_wr) begin
            addr_q <= s_req.awaddr; wdata_q <= s_req.wdata; strb_q <= s_req.wstrb;
            wr_q <= 1'b1; st <= B_SETUP;
          end
        end
        B_SETUP: begin
          if (sel_ok) st <= B_ACCESS;
          else begin                                       // unmapped slot: no APB access
            rdata_q <= 32'd0; resp_q <= AXI_RESP_DECERR;
            st <= wr_q ? B_RESP_W : B_RESP_R;
          end
        end
        B_ACCESS: if (sel_ready) begin
          rdata_q <= sel_rdata;
          resp_q  <= sel_err ? AXI_RESP_SLVERR : AXI_RESP_OKAY;
          st      <= wr_q ? B_RESP_W : B_RESP_R;
        end
        B_RESP_R: if (s_req.rready) st <= B_IDLE;
        B_RESP_W: if (s_req.bready) st <= B_IDLE;
        default:  st <= B_IDLE;
      endcase
    end
  end

`ifndef SYNTHESIS
  always @(posedge clk) if (rst_n) begin
    assert (!(take_rd && s_req.arlen != 8'd0)) else $error("axi_to_apb: burst read not supported");
    assert (!(take_wr && !s_req.wlast))        else $error("axi_to_apb: burst write not supported");
    assert ($onehot0(psel))                    else $error("axi_to_apb: psel not one-hot");
  end
`endif
endmodule
```

## 21. `rtl/memory/boot_rom.sv`

```systemverilog
// =============================================================================
// boot_rom.sv - read-only boot ROM, AXI slave
//   * INCR burst reads, one word per cycle after the AR handshake
//   * reads beyond WORDS (inside the 0x0xxx_xxxx region) -> SLVERR (data 0)
//   * any write is drained and answered with SLVERR (ROM is not writable)
//   * contents come from INIT_FILE ($readmemh, one 32-bit hex word per line)
// =============================================================================
module boot_rom import rv32im_pkg::*; #(
  parameter int    WORDS     = 1024,                 // 4 KiB default
  parameter string INIT_FILE = "rom_init.hex"
) (
  input  logic     clk,
  input  logic     rst_n,
  input  axi_req_t s_req,
  output axi_rsp_t s_rsp
);
  localparam int AW = $clog2(WORDS);

  logic [31:0] rom [WORDS];
  initial if (INIT_FILE != "") $readmemh(INIT_FILE, rom);

  // ---- read channel FSM -------------------------------------------------------------
  logic        rd_act;
  logic [29:0] wa_q;                                  // word address
  logic [7:0]  cnt_q;                                 // beats remaining - 1
  wire         in_range = (wa_q[29:AW] == '0);

  always_ff @(posedge clk) begin
    if (!rst_n) rd_act <= 1'b0;
    else if (!rd_act) begin
      if (s_req.arvalid) begin
        rd_act <= 1'b1;
        wa_q   <= s_req.araddr[31:2];
        cnt_q  <= s_req.arlen;
      end
    end else if (s_req.rready) begin
      wa_q <= wa_q + 30'd1;
      if (cnt_q == 8'd0) rd_act <= 1'b0;
      else               cnt_q  <= cnt_q - 8'd1;
    end
  end

  // ---- write channel: reject with SLVERR --------------------------------------------------
  axi_req_t werr_req;
  axi_rsp_t werr_rsp;
  always_comb begin
    werr_req         = s_req;
    werr_req.arvalid = 1'b0;                          // read side handled above
    werr_req.rready  = 1'b0;
  end
  axi_err_slave #(.RESP(AXI_RESP_SLVERR)) u_wr_reject (.clk(clk), .rst_n(rst_n), .req(werr_req), .rsp(werr_rsp));

  // ---- response assembly ----------------------------------------------------------------------
  always_comb begin
    s_rsp         = AXI_RSP_IDLE;
    s_rsp.arready = ~rd_act;
    s_rsp.rvalid  = rd_act;
    s_rsp.rdata   = in_range ? rom[wa_q[AW-1:0]] : 32'd0;
    s_rsp.rresp   = in_range ? AXI_RESP_OKAY : AXI_RESP_SLVERR;
    s_rsp.rlast   = (cnt_q == 8'd0);
    s_rsp.awready = werr_rsp.awready;
    s_rsp.wready  = werr_rsp.wready;
    s_rsp.bvalid  = werr_rsp.bvalid;
    s_rsp.bresp   = werr_rsp.bresp;
  end
endmodule
```

## 22. `rtl/memory/sram_controller.sv`

```systemverilog
// =============================================================================
// sram_controller.sv - AXI slave in front of a word-organised byte-writable SRAM
//   * INCR burst read (1 word/cycle) and INCR burst write, byte strobes honoured
//   * accesses beyond WORDS (inside the 0x1xxx_xxxx region) -> SLVERR
//   * the array below is behavioural (flops).  For the physical flow swap the
//     `mem` array for an OpenRAM/SRAM macro (synchronous read => the S_RD state
//     needs one extra wait cycle before rvalid; not implemented here).
// =============================================================================
module sram_controller import rv32im_pkg::*; #(
  parameter int WORDS = 1024                          // 4 KiB default
) (
  input  logic     clk,
  input  logic     rst_n,
  input  axi_req_t s_req,
  output axi_rsp_t s_rsp
);
  localparam int AW = $clog2(WORDS);

  typedef enum logic [1:0] { S_IDLE, S_RD, S_WR, S_B } s_state_e;
  s_state_e    st;
  logic [29:0] wa_q;                                  // word address of current beat
  logic [7:0]  cnt_q;
  logic        bad_q;                                 // a write beat was out of range

  logic [31:0] mem [WORDS];
  wire         in_range = (wa_q[29:AW] == '0);
  wire         wr_en    = (st == S_WR) & s_req.wvalid & in_range;

`ifndef SYNTHESIS
  initial for (int i = 0; i < WORDS; i++) mem[i] = 32'd0;
`endif

  // ---- byte-enable write -------------------------------------------------------------
  always_ff @(posedge clk) begin
    if (wr_en) begin
      for (int b = 0; b < 4; b++)
        if (s_req.wstrb[b]) mem[wa_q[AW-1:0]][8*b +: 8] <= s_req.wdata[8*b +: 8];
    end
  end

  // ---- channel handshakes ---------------------------------------------------------------
  always_comb begin
    s_rsp = AXI_RSP_IDLE;
    case (st)
      S_IDLE: begin
        s_rsp.arready = s_req.arvalid;
        s_rsp.awready = s_req.awvalid & ~s_req.arvalid;
      end
      S_RD: begin
        s_rsp.rvalid = 1'b1;
        s_rsp.rdata  = in_range ? mem[wa_q[AW-1:0]] : 32'd0;
        s_rsp.rresp  = in_range ? AXI_RESP_OKAY : AXI_RESP_SLVERR;
        s_rsp.rlast  = (cnt_q == 8'd0);
      end
      S_WR: s_rsp.wready = 1'b1;
      S_B: begin
        s_rsp.bvalid = 1'b1;
        s_rsp.bresp  = bad_q ? AXI_RESP_SLVERR : AXI_RESP_OKAY;
      end
      default: ;
    endcase
  end

  always_ff @(posedge clk) begin
    if (!rst_n) st <= S_IDLE;
    else begin
      case (st)
        S_IDLE: begin
          if (s_req.arvalid) begin
            wa_q <= s_req.araddr[31:2]; cnt_q <= s_req.arlen; st <= S_RD;
          end else if (s_req.awvalid) begin
            wa_q <= s_req.awaddr[31:2]; bad_q <= 1'b0; st <= S_WR;
          end
        end
        S_RD: if (s_req.rready) begin
          wa_q <= wa_q + 30'd1;
          if (cnt_q == 8'd0) st <= S_IDLE;
          else               cnt_q <= cnt_q - 8'd1;
        end
        S_WR: if (s_req.wvalid) begin
          if (!in_range) bad_q <= 1'b1;
          wa_q <= wa_q + 30'd1;
          if (s_req.wlast) st <= S_B;
        end
        S_B: if (s_req.bready) st <= S_IDLE;
        default: st <= S_IDLE;
      endcase
    end
  end
endmodule
```

## 23. `rtl/memory/memory_subsystem.sv`

```systemverilog
// =============================================================================
// memory_subsystem.sv - I-cache + D-cache + AXI masters + interconnect + ROM + SRAM
//
//   core imem --> icache --> axi4_master(RO) --\
//                                               +--> axi4_interconnect --> ROM   (0x0xxx_xxxx)
//   core dmem --> dcache --> axi4_master ------/                       --> SRAM  (0x1xxx_xxxx)
//                                                                      --> per_*  (0x4xxx_xxxx, exported)
//                                                                      --> DECERR (anything else)
// The peripheral AXI port is exported so the SoC top can attach axi_to_apb.
// =============================================================================
module memory_subsystem import rv32im_pkg::*; #(
  parameter bit    ICACHE_ENABLE     = 1'b1,
  parameter bit    DCACHE_ENABLE     = 1'b1,
  parameter int    ICACHE_LINES      = 64,
  parameter int    ICACHE_LINE_BYTES = 16,
  parameter int    DCACHE_LINES      = 64,
  parameter int    DCACHE_LINE_BYTES = 16,
  parameter int    ROM_WORDS         = 1024,
  parameter int    SRAM_WORDS        = 1024,
  parameter string ROM_INIT_FILE     = "rom_init.hex"
) (
  input  logic        clk,
  input  logic        rst_n,
  // core instruction port
  input  logic [31:0] imem_addr,
  output logic [31:0] imem_rdata,
  output logic        imem_ready,
  output logic        imem_err,
  input  logic        imem_inval,
  // core data port
  input  logic        dmem_req,
  input  logic        dmem_we,
  input  logic [31:0] dmem_addr,
  input  logic [31:0] dmem_wdata,
  input  logic [3:0]  dmem_be,
  output logic [31:0] dmem_rdata,
  output logic        dmem_ready,
  output logic        dmem_err,
  output logic        dmem_busy,
  // performance events
  output logic        evt_icache_miss,
  output logic        evt_dcache_miss,
  // peripheral AXI port (to axi_to_apb)
  output axi_req_t    per_req,
  input  axi_rsp_t    per_rsp
);
  // ---- native request/response wires ------------------------------------------------
  logic        i_req_valid, i_req_ready, i_rsp_valid, i_rsp_last, i_rsp_err;
  logic [31:0] i_req_addr, i_rsp_data;
  logic [7:0]  i_req_len;

  logic        d_req_valid, d_req_ready, d_req_write, d_rsp_valid, d_rsp_last, d_rsp_err;
  logic [31:0] d_req_addr, d_req_wdata, d_rsp_data;
  logic [7:0]  d_req_len;
  logic [3:0]  d_req_wstrb;

  // ---- AXI wires -----------------------------------------------------------------------
  axi_req_t m0_req, m1_req, s0_req, s1_req;
  axi_rsp_t m0_rsp, m1_rsp, s0_rsp, s1_rsp;

  // ---- caches -----------------------------------------------------------------------------
  icache #(.ENABLE(ICACHE_ENABLE), .LINES(ICACHE_LINES), .LINE_BYTES(ICACHE_LINE_BYTES)) u_icache (
    .clk(clk), .rst_n(rst_n),
    .cpu_addr(imem_addr), .cpu_rdata(imem_rdata), .cpu_ready(imem_ready), .cpu_err(imem_err),
    .inval(imem_inval),
    .req_valid(i_req_valid), .req_ready(i_req_ready), .req_addr(i_req_addr), .req_len(i_req_len),
    .rsp_valid(i_rsp_valid), .rsp_data(i_rsp_data), .rsp_last(i_rsp_last), .rsp_err(i_rsp_err),
    .miss_evt(evt_icache_miss)
  );

  dcache #(.ENABLE(DCACHE_ENABLE), .LINES(DCACHE_LINES), .LINE_BYTES(DCACHE_LINE_BYTES)) u_dcache (
    .clk(clk), .rst_n(rst_n),
    .cpu_req(dmem_req), .cpu_we(dmem_we), .cpu_addr(dmem_addr), .cpu_wdata(dmem_wdata), .cpu_be(dmem_be),
    .cpu_rdata(dmem_rdata), .cpu_ready(dmem_ready), .cpu_err(dmem_err), .cpu_busy(dmem_busy),
    .req_valid(d_req_valid), .req_ready(d_req_ready), .req_write(d_req_write), .req_addr(d_req_addr),
    .req_len(d_req_len), .req_wdata(d_req_wdata), .req_wstrb(d_req_wstrb),
    .rsp_valid(d_rsp_valid), .rsp_data(d_rsp_data), .rsp_last(d_rsp_last), .rsp_err(d_rsp_err),
    .miss_evt(evt_dcache_miss)
  );

  // ---- AXI masters ---------------------------------------------------------------------------
  axi4_master #(.READ_ONLY(1'b1)) u_i_master (
    .clk(clk), .rst_n(rst_n),
    .req_valid(i_req_valid), .req_ready(i_req_ready), .req_write(1'b0), .req_addr(i_req_addr),
    .req_len(i_req_len), .req_wdata(32'd0), .req_wstrb(4'd0),
    .rsp_valid(i_rsp_valid), .rsp_data(i_rsp_data), .rsp_last(i_rsp_last), .rsp_err(i_rsp_err),
    .m_req(m0_req), .m_rsp(m0_rsp)
  );

  axi4_master #(.READ_ONLY(1'b0)) u_d_master (
    .clk(clk), .rst_n(rst_n),
    .req_valid(d_req_valid), .req_ready(d_req_ready), .req_write(d_req_write), .req_addr(d_req_addr),
    .req_len(d_req_len), .req_wdata(d_req_wdata), .req_wstrb(d_req_wstrb),
    .rsp_valid(d_rsp_valid), .rsp_data(d_rsp_data), .rsp_last(d_rsp_last), .rsp_err(d_rsp_err),
    .m_req(m1_req), .m_rsp(m1_rsp)
  );

  // ---- fabric + slaves -----------------------------------------------------------------------
  axi4_interconnect u_xbar (
    .clk(clk), .rst_n(rst_n),
    .m0_req(m0_req), .m0_rsp(m0_rsp),
    .m1_req(m1_req), .m1_rsp(m1_rsp),
    .s0_req(s0_req), .s0_rsp(s0_rsp),
    .s1_req(s1_req), .s1_rsp(s1_rsp),
    .s2_req(per_req), .s2_rsp(per_rsp)
  );

  boot_rom #(.WORDS(ROM_WORDS), .INIT_FILE(ROM_INIT_FILE)) u_rom (
    .clk(clk), .rst_n(rst_n), .s_req(s0_req), .s_rsp(s0_rsp)
  );

  sram_controller #(.WORDS(SRAM_WORDS)) u_sram (
    .clk(clk), .rst_n(rst_n), .s_req(s1_req), .s_rsp(s1_rsp)
  );
endmodule
```

## 24. `rtl/peripherals/timer.sv`

```systemverilog
// =============================================================================
// timer.sv - machine timer + software-interrupt register (CLINT-lite), APB slave
//
//   offset  reg        access  description
//   0x00    CTRL       RW      [0] EN: counter runs while 1 (reset: 0)
//   0x04    MSIP       RW      [0] software interrupt pending -> irq_sw
//   0x08    MTIME_LO   RW      free-running counter, low word
//   0x0C    MTIME_HI   RW      high word (read hi/lo/hi for a consistent 64-bit value)
//   0x10    MTIMECMP_LO RW     compare, low word  (reset: all ones => no interrupt)
//   0x14    MTIMECMP_HI RW     compare, high word
//   irq_timer = EN && (mtime >= mtimecmp), level, cleared by writing a larger mtimecmp.
// Zero wait states, no error responses (unmapped offsets read 0, writes ignored).
// =============================================================================
module timer import rv32im_pkg::*; (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        psel,
  input  logic        penable,
  input  logic        pwrite,
  input  logic [11:0] paddr,
  input  logic [31:0] pwdata,
  input  logic [3:0]  pstrb,
  output logic [31:0] prdata,
  output logic        pready,
  output logic        pslverr,
  output logic        irq_timer,
  output logic        irq_sw
);
  logic        en, msip;
  logic [63:0] mtime, mtimecmp;

  wire       wr  = psel & penable & pwrite;
  wire [3:0] off = paddr[5:2];

  assign pready  = 1'b1;
  assign pslverr = 1'b0;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      en <= 1'b0; msip <= 1'b0; mtime <= 64'd0; mtimecmp <= '1;
    end else begin
      if (en) mtime <= mtime + 64'd1;
      if (wr) begin                                   // writes override the increment
        case (off)
          4'h0: if (pstrb[0]) en   <= pwdata[0];
          4'h1: if (pstrb[0]) msip <= pwdata[0];
          4'h2: mtime[31:0]      <= apply_be(mtime[31:0],      pwdata, pstrb);
          4'h3: mtime[63:32]     <= apply_be(mtime[63:32],     pwdata, pstrb);
          4'h4: mtimecmp[31:0]   <= apply_be(mtimecmp[31:0],   pwdata, pstrb);
          4'h5: mtimecmp[63:32]  <= apply_be(mtimecmp[63:32],  pwdata, pstrb);
          default: ;
        endcase
      end
    end
  end

  always_comb begin
    case (off)
      4'h0:    prdata = {31'd0, en};
      4'h1:    prdata = {31'd0, msip};
      4'h2:    prdata = mtime[31:0];
      4'h3:    prdata = mtime[63:32];
      4'h4:    prdata = mtimecmp[31:0];
      4'h5:    prdata = mtimecmp[63:32];
      default: prdata = 32'd0;
    endcase
  end

  assign irq_timer = en & (mtime >= mtimecmp);
  assign irq_sw    = msip;
endmodule
```

## 25. `rtl/peripherals/uart.sv`

```systemverilog
// =============================================================================
// uart.sv - 8N1 UART (single-byte TX/RX buffers), APB slave
//
//   offset  reg      access  description
//   0x00    TXDATA   W       [7:0] write starts transmission if TX is ready (ignored otherwise)
//   0x04    RXDATA   R       [7:0] received byte; the read clears RX_VALID
//   0x08    STATUS   R/W1C   [0] TX_READY  [1] RX_VALID  [2] OVERRUN (W1C)  [3] FRAME_ERR (W1C)
//   0x0C    CTRL     RW      [0] TX_IRQ_EN (irq while TX_READY)  [1] RX_IRQ_EN (irq while RX_VALID)
//   0x10    BAUD     RW      [15:0] divisor; one bit lasts (BAUD+1) clk cycles
//   RX: 2-FF synchroniser, start-bit qualified at mid-bit, samples mid-bit,
//       stop-bit low => FRAME_ERR, byte arriving while RX_VALID => OVERRUN (byte dropped).
// =============================================================================
module uart import rv32im_pkg::*; #(
  parameter logic [15:0] BAUD_DIV_RESET = 16'd433      // 50 MHz / 115200 - 1
) (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        psel,
  input  logic        penable,
  input  logic        pwrite,
  input  logic [11:0] paddr,
  input  logic [31:0] pwdata,
  input  logic [3:0]  pstrb,
  output logic [31:0] prdata,
  output logic        pready,
  output logic        pslverr,
  input  logic        rxd,
  output logic        txd,
  output logic        irq
);
  assign pready  = 1'b1;
  assign pslverr = 1'b0;

  wire       acc = psel & penable;
  wire       wr  = acc & pwrite;
  wire       rd  = acc & ~pwrite;
  wire [2:0] off = paddr[4:2];

  logic [15:0] div_q;
  logic        tx_irq_en, rx_irq_en;

  // ------------------------------------------------------------------ TX
  logic        tx_busy;
  logic [9:0]  tx_shift;                                 // {stop, data[7:0], start}, LSB first
  logic [3:0]  tx_bit;
  logic [15:0] tx_cnt;
  wire         tx_start = wr && off == 3'd0 && pstrb[0] && !tx_busy;

  assign txd = tx_busy ? tx_shift[0] : 1'b1;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      tx_busy <= 1'b0; tx_shift <= 10'h3FF; tx_bit <= 4'd0; tx_cnt <= 16'd0;
    end else if (tx_start) begin
      tx_shift <= {1'b1, pwdata[7:0], 1'b0};
      tx_busy  <= 1'b1;
      tx_bit   <= 4'd0;
      tx_cnt   <= div_q;
    end else if (tx_busy) begin
      if (tx_cnt == 16'd0) begin                         // bit period elapsed
        tx_cnt   <= div_q;
        tx_shift <= {1'b1, tx_shift[9:1]};
        tx_bit   <= tx_bit + 4'd1;
        if (tx_bit == 4'd9) tx_busy <= 1'b0;             // stop bit finished
      end else tx_cnt <= tx_cnt - 16'd1;
    end
  end

  // ------------------------------------------------------------------ RX
  logic        rx_s1, rx_s2, rx_busy, rx_valid, overrun, frame_err;
  logic [3:0]  rx_bit;
  logic [15:0] rx_cnt;
  logic [7:0]  rx_shift, rx_data;

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      rx_s1 <= 1'b1; rx_s2 <= 1'b1; rx_busy <= 1'b0; rx_valid <= 1'b0;
      overrun <= 1'b0; frame_err <= 1'b0; rx_bit <= 4'd0; rx_cnt <= 16'd0;
      rx_shift <= 8'd0; rx_data <= 8'd0;
    end else begin
      rx_s1 <= rxd;
      rx_s2 <= rx_s1;

      // software side effects first, hardware events below take priority
      if (rd && off == 3'd1) rx_valid <= 1'b0;
      if (wr && off == 3'd2 && pstrb[0]) begin
        if (pwdata[2]) overrun   <= 1'b0;
        if (pwdata[3]) frame_err <= 1'b0;
      end

      if (!rx_busy) begin
        if (!rx_s2) begin                                // falling edge: start bit
          rx_busy <= 1'b1;
          rx_cnt  <= {1'b0, div_q[15:1]};                // wait half a bit -> middle of start bit
          rx_bit  <= 4'd0;
        end
      end else if (rx_cnt != 16'd0) begin
        rx_cnt <= rx_cnt - 16'd1;
      end else begin
        rx_cnt <= div_q;
        if (rx_bit == 4'd0) begin                        // middle of start bit
          if (rx_s2) rx_busy <= 1'b0;                    // glitch, abort
          else       rx_bit  <= 4'd1;
        end else if (rx_bit <= 4'd8) begin               // data bits d0..d7
          rx_shift <= {rx_s2, rx_shift[7:1]};
          rx_bit   <= rx_bit + 4'd1;
        end else begin                                   // stop bit
          rx_busy <= 1'b0;
          if (rx_s2) begin
            if (rx_valid && !(rd && off == 3'd1)) overrun <= 1'b1;
            else begin rx_data <= rx_shift; rx_valid <= 1'b1; end
          end else frame_err <= 1'b1;
        end
      end
    end
  end

  // ------------------------------------------------------------------ control regs
  always_ff @(posedge clk) begin
    if (!rst_n) begin
      div_q <= BAUD_DIV_RESET; tx_irq_en <= 1'b0; rx_irq_en <= 1'b0;
    end else if (wr) begin
      case (off)
        3'd3: if (pstrb[0]) begin tx_irq_en <= pwdata[0]; rx_irq_en <= pwdata[1]; end
        3'd4: begin
          if (pstrb[0]) div_q[7:0]  <= pwdata[7:0];
          if (pstrb[1]) div_q[15:8] <= pwdata[15:8];
        end
        default: ;
      endcase
    end
  end

  always_comb begin
    case (off)
      3'd1:    prdata = {24'd0, rx_data};
      3'd2:    prdata = {28'd0, frame_err, overrun, rx_valid, ~tx_busy};
      3'd3:    prdata = {30'd0, rx_irq_en, tx_irq_en};
      3'd4:    prdata = {16'd0, div_q};
      default: prdata = 32'd0;
    endcase
  end

  assign irq = (~tx_busy & tx_irq_en) | (rx_valid & rx_irq_en);
endmodule
```

## 26. `rtl/peripherals/gpio.sv`

```systemverilog
// =============================================================================
// gpio.sv - 32-bit GPIO, APB slave
//
//   offset  reg      access  description
//   0x00    OUT      RW      output data (reset 0)
//   0x04    DIR      RW      1 = pin driven as output (gpio_oe), reset 0 = all inputs
//   0x08    IN       R       synchronised pin values (2-FF)
//   0x0C    IRQ_EN   RW      per-pin enable; irq = |(IN & IRQ_EN)  (level, active high)
// =============================================================================
module gpio import rv32im_pkg::*; (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        psel,
  input  logic        penable,
  input  logic        pwrite,
  input  logic [11:0] paddr,
  input  logic [31:0] pwdata,
  input  logic [3:0]  pstrb,
  output logic [31:0] prdata,
  output logic        pready,
  output logic        pslverr,
  input  logic [31:0] gpio_i,
  output logic [31:0] gpio_o,
  output logic [31:0] gpio_oe,
  output logic        irq
);
  logic [31:0] out_q, dir_q, irq_en_q, in_s1, in_s2;
  wire         wr  = psel & penable & pwrite;
  wire [1:0]   off = paddr[3:2];

  assign pready  = 1'b1;
  assign pslverr = 1'b0;
  assign gpio_o  = out_q;
  assign gpio_oe = dir_q;
  assign irq     = |(in_s2 & irq_en_q);

  always_ff @(posedge clk) begin
    if (!rst_n) begin
      out_q <= 32'd0; dir_q <= 32'd0; irq_en_q <= 32'd0; in_s1 <= 32'd0; in_s2 <= 32'd0;
    end else begin
      in_s1 <= gpio_i;
      in_s2 <= in_s1;
      if (wr) begin
        case (off)
          2'd0: out_q    <= apply_be(out_q,    pwdata, pstrb);
          2'd1: dir_q    <= apply_be(dir_q,    pwdata, pstrb);
          2'd3: irq_en_q <= apply_be(irq_en_q, pwdata, pstrb);
          default: ;                                   // IN is read-only
        endcase
      end
    end
  end

  always_comb begin
    case (off)
      2'd0:    prdata = out_q;
      2'd1:    prdata = dir_q;
      2'd2:    prdata = in_s2;
      default: prdata = irq_en_q;
    endcase
  end
endmodule
```

## 27. `rtl/peripherals/interrupt_controller.sv`

```systemverilog
// =============================================================================
// interrupt_controller.sv - external interrupt aggregator (PLIC-lite), APB slave
//
//   offset  reg      access  description
//   0x00    PENDING  R       raw level of the 8 sources (a source clears at the peripheral)
//   0x04    ENABLE   RW      per-source enable (reset 0 = all masked)
//   0x08    CLAIM    R       1 + index of the lowest-numbered enabled pending source, 0 = none
//                            (fixed priority: source 0 highest).  No claim/complete handshake
//                            is needed because sources are level-sensitive.
//   meip = |(PENDING & ENABLE)  -> core mip.MEIP
// Source map used by the SoC: 0 UART, 1 GPIO, 2..7 external pins.
// =============================================================================
module interrupt_controller import rv32im_pkg::*; #(
  parameter int N_SRC = 8
) (
  input  logic             clk,
  input  logic             rst_n,
  input  logic             psel,
  input  logic             penable,
  input  logic             pwrite,
  input  logic [11:0]      paddr,
  input  logic [31:0]      pwdata,
  input  logic [3:0]       pstrb,
  output logic [31:0]      prdata,
  output logic             pready,
  output logic             pslverr,
  input  logic [N_SRC-1:0] irq_src,
  output logic             meip
);
  logic [N_SRC-1:0] enable_q, active;
  logic [31:0]      claim;

  wire       wr  = psel & penable & pwrite;
  wire [1:0] off = paddr[3:2];

  assign pready  = 1'b1;
  assign pslverr = 1'b0;
  assign active  = irq_src & enable_q;
  assign meip    = |active;

  always_comb begin                                     // lowest index wins
    claim = 32'd0;
    for (int i = N_SRC - 1; i >= 0; i--)
      if (active[i]) claim = 32'(i + 1);
  end

  always_ff @(posedge clk) begin
    if (!rst_n)                        enable_q <= '0;
    else if (wr && off == 2'd1) begin
      for (int b = 0; b < N_SRC; b++)
        if (pstrb[b/8]) enable_q[b] <= pwdata[b];
    end
  end

  always_comb begin
    case (off)
      2'd0:    prdata = 32'(irq_src);
      2'd1:    prdata = 32'(enable_q);
      2'd2:    prdata = claim;
      default: prdata = 32'd0;
    endcase
  end
endmodule
```

## 28. `rtl/soc/rv32im_soc.sv`

```systemverilog
// =============================================================================
// rv32im_soc.sv - SoC top: core + memory subsystem + APB peripherals
//
//   Memory map            0x0000_0000  boot ROM        0x1000_0000  SRAM
//                         0x4000_0000  timer  (+0x1000 UART, +0x2000 GPIO, +0x3000 INTC)
//   Interrupts to core    MSIP <- timer.msip   MTIP <- timer compare   MEIP <- INTC
//   INTC sources          0 UART, 1 GPIO, 2..7 ext_irq[0..5]
// All top-level parameters select the PPA variants (predictor, mul, caches, sizes).
// =============================================================================
module rv32im_soc import rv32im_pkg::*; #(
  // core
  parameter logic [31:0] RESET_PC          = 32'h0000_0000,
  parameter bit          ENABLE_BHT        = 1'b1,
  parameter bit          ENABLE_BTB        = 1'b1,
  parameter int          BHT_ENTRIES       = 64,
  parameter int          BTB_ENTRIES       = 16,
  parameter int          MUL_IMPL          = 0,
  parameter bit          OPERAND_ISOLATION = 1'b0,
  // caches / memories
  parameter bit          ICACHE_ENABLE     = 1'b1,
  parameter bit          DCACHE_ENABLE     = 1'b1,
  parameter int          ICACHE_LINES      = 64,
  parameter int          ICACHE_LINE_BYTES = 16,
  parameter int          DCACHE_LINES      = 64,
  parameter int          DCACHE_LINE_BYTES = 16,
  parameter int          ROM_WORDS         = 1024,
  parameter int          SRAM_WORDS        = 1024,
  parameter string       ROM_INIT_FILE     = "rom_init.hex",
  // peripherals
  parameter logic [15:0] UART_BAUD_DIV     = 16'd433
) (
  input  logic        clk,
  input  logic        rst_n,
  // UART
  input  logic        uart_rxd,
  output logic        uart_txd,
  // GPIO
  input  logic [31:0] gpio_i,
  output logic [31:0] gpio_o,
  output logic [31:0] gpio_oe,
  // external interrupt sources
  input  logic [5:0]  ext_irq
);
  // ---------------------------------------------------------------- core <-> memory
  logic [31:0] imem_addr, imem_rdata, dmem_addr, dmem_wdata, dmem_rdata;
  logic        imem_ready, imem_err, imem_inval;
  logic        dmem_req, dmem_we, dmem_ready, dmem_err, dmem_busy;
  logic [3:0]  dmem_be;
  logic        evt_imiss, evt_dmiss;
  logic        irq_msip, irq_mtip, irq_meip;

  rv32im_core #(
    .RESET_PC(RESET_PC), .ENABLE_BHT(ENABLE_BHT), .ENABLE_BTB(ENABLE_BTB),
    .BHT_ENTRIES(BHT_ENTRIES), .BTB_ENTRIES(BTB_ENTRIES),
    .MUL_IMPL(MUL_IMPL), .OPERAND_ISOLATION(OPERAND_ISOLATION)
  ) u_core (
    .clk(clk), .rst_n(rst_n),
    .imem_addr(imem_addr), .imem_rdata(imem_rdata), .imem_ready(imem_ready),
    .imem_err(imem_err), .imem_inval(imem_inval),
    .dmem_req(dmem_req), .dmem_we(dmem_we), .dmem_addr(dmem_addr), .dmem_wdata(dmem_wdata),
    .dmem_be(dmem_be), .dmem_rdata(dmem_rdata), .dmem_ready(dmem_ready),
    .dmem_err(dmem_err), .dmem_busy(dmem_busy),
    .irq_msip(irq_msip), .irq_mtip(irq_mtip), .irq_meip(irq_meip),
    .evt_icache_miss(evt_imiss), .evt_dcache_miss(evt_dmiss)
  );

  axi_req_t per_req;
  axi_rsp_t per_rsp;

  memory_subsystem #(
    .ICACHE_ENABLE(ICACHE_ENABLE), .DCACHE_ENABLE(DCACHE_ENABLE),
    .ICACHE_LINES(ICACHE_LINES), .ICACHE_LINE_BYTES(ICACHE_LINE_BYTES),
    .DCACHE_LINES(DCACHE_LINES), .DCACHE_LINE_BYTES(DCACHE_LINE_BYTES),
    .ROM_WORDS(ROM_WORDS), .SRAM_WORDS(SRAM_WORDS), .ROM_INIT_FILE(ROM_INIT_FILE)
  ) u_mem (
    .clk(clk), .rst_n(rst_n),
    .imem_addr(imem_addr), .imem_rdata(imem_rdata), .imem_ready(imem_ready),
    .imem_err(imem_err), .imem_inval(imem_inval),
    .dmem_req(dmem_req), .dmem_we(dmem_we), .dmem_addr(dmem_addr), .dmem_wdata(dmem_wdata),
    .dmem_be(dmem_be), .dmem_rdata(dmem_rdata), .dmem_ready(dmem_ready),
    .dmem_err(dmem_err), .dmem_busy(dmem_busy),
    .evt_icache_miss(evt_imiss), .evt_dcache_miss(evt_dmiss),
    .per_req(per_req), .per_rsp(per_rsp)
  );

  // ---------------------------------------------------------------- AXI -> APB
  logic [3:0]   psel;
  logic         penable, pwrite;
  logic [11:0]  paddr;
  logic [31:0]  pwdata;
  logic [3:0]   pstrb;
  logic [127:0] prdata;                       // {intc, gpio, uart, timer}
  logic [3:0]   pready, pslverr;

  axi_to_apb #(.NUM_PERIPH(4)) u_apb (
    .clk(clk), .rst_n(rst_n), .s_req(per_req), .s_rsp(per_rsp),
    .psel(psel), .penable(penable), .pwrite(pwrite), .paddr(paddr),
    .pwdata(pwdata), .pstrb(pstrb), .prdata(prdata), .pready(pready), .pslverr(pslverr)
  );

  // ---------------------------------------------------------------- peripherals
  logic uart_irq, gpio_irq;

  timer u_timer (
    .clk(clk), .rst_n(rst_n),
    .psel(psel[PERIPH_TIMER]), .penable(penable), .pwrite(pwrite), .paddr(paddr),
    .pwdata(pwdata), .pstrb(pstrb),
    .prdata(prdata[32*PERIPH_TIMER +: 32]), .pready(pready[PERIPH_TIMER]), .pslverr(pslverr[PERIPH_TIMER]),
    .irq_timer(irq_mtip), .irq_sw(irq_msip)
  );

  uart #(.BAUD_DIV_RESET(UART_BAUD_DIV)) u_uart (
    .clk(clk), .rst_n(rst_n),
    .psel(psel[PERIPH_UART]), .penable(penable), .pwrite(pwrite), .paddr(paddr),
    .pwdata(pwdata), .pstrb(pstrb),
    .prdata(prdata[32*PERIPH_UART +: 32]), .pready(pready[PERIPH_UART]), .pslverr(pslverr[PERIPH_UART]),
    .rxd(uart_rxd), .txd(uart_txd), .irq(uart_irq)
  );

  gpio u_gpio (
    .clk(clk), .rst_n(rst_n),
    .psel(psel[PERIPH_GPIO]), .penable(penable), .pwrite(pwrite), .paddr(paddr),
    .pwdata(pwdata), .pstrb(pstrb),
    .prdata(prdata[32*PERIPH_GPIO +: 32]), .pready(pready[PERIPH_GPIO]), .pslverr(pslverr[PERIPH_GPIO]),
    .gpio_i(gpio_i), .gpio_o(gpio_o), .gpio_oe(gpio_oe), .irq(gpio_irq)
  );

  interrupt_controller #(.N_SRC(8)) u_intc (
    .clk(clk), .rst_n(rst_n),
    .psel(psel[PERIPH_INTC]), .penable(penable), .pwrite(pwrite), .paddr(paddr),
    .pwdata(pwdata), .pstrb(pstrb),
    .prdata(prdata[32*PERIPH_INTC +: 32]), .pready(pready[PERIPH_INTC]), .pslverr(pslverr[PERIPH_INTC]),
    .irq_src({ext_irq, gpio_irq, uart_irq}), .meip(irq_meip)
  );
endmodule
```

## File list (`rtl/filelist.f`)

```
# Compile order (package first). Top module: rv32im_soc
# Example lint:  verilator --lint-only -Wall -Wno-fatal --top-module rv32im_soc -f rtl/filelist.f
rtl/rv32im_pkg.sv
rtl/core/pipeline_regs.sv
rtl/core/pc_unit.sv
rtl/core/register_file.sv
rtl/core/immediate_gen.sv
rtl/core/decoder.sv
rtl/core/alu.sv
rtl/core/branch_unit.sv
rtl/core/forwarding_unit.sv
rtl/core/hazard_unit.sv
rtl/core/muldiv_unit.sv
rtl/core/csr_file.sv
rtl/core/branch_predictor.sv
rtl/core/rv32im_core.sv
rtl/cache/cache_arrays.sv
rtl/cache/icache.sv
rtl/cache/dcache.sv
rtl/bus/axi4_master.sv
rtl/bus/axi4_interconnect.sv
rtl/bus/axi_to_apb.sv
rtl/memory/boot_rom.sv
rtl/memory/sram_controller.sv
rtl/memory/memory_subsystem.sv
rtl/peripherals/timer.sv
rtl/peripherals/uart.sv
rtl/peripherals/gpio.sv
rtl/peripherals/interrupt_controller.sv
rtl/soc/rv32im_soc.sv
```
