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
