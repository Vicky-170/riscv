// =============================================================================
// tb_immediate_gen.sv - V0..V5 for immediate_gen.sv
//   Reference model rebuilds each immediate bit-by-bit straight from the RISC-V
//   spec field definitions (inst[31], inst[30:25], ...) rather than reusing the
//   DUT's concatenations.
// =============================================================================
module tb_immediate_gen import rv32im_pkg::*;;
  `include "tb_common.svh"

  logic        clk = 0;
  logic [31:0] instr, imm;
  always #5 clk = ~clk;
  always @(posedge clk) cyc++;

  immediate_gen dut (.instr(instr), .imm(imm));

  // ---- independent reference: build the 32-bit value bit by bit ---------------
  function automatic logic [31:0] ref_imm(input logic [31:0] ins);
    logic [31:0] v = 32'd0;
    case (ins[6:0])
      7'b0100011: begin                               // S-type
        v[4:0]  = ins[11:7];
        v[11:5] = ins[31:25];
        for (int i = 12; i < 32; i++) v[i] = ins[31];
      end
      7'b1100011: begin                               // B-type
        v[0] = 1'b0; v[4:1] = ins[11:8]; v[10:5] = ins[30:25];
        v[11] = ins[7]; v[12] = ins[31];
        for (int i = 13; i < 32; i++) v[i] = ins[31];
      end
      7'b0110111, 7'b0010111: begin                   // U-type
        v[11:0] = 12'd0; v[31:12] = ins[31:12];
      end
      7'b1101111: begin                               // J-type
        v[0] = 1'b0; v[10:1] = ins[30:21]; v[11] = ins[20]; v[19:12] = ins[19:12];
        v[20] = ins[31];
        for (int i = 21; i < 32; i++) v[i] = ins[31];
      end
      default: begin                                  // I-type
        v[11:0] = ins[31:20];
        for (int i = 12; i < 32; i++) v[i] = ins[31];
      end
    endcase
    return v;
  endfunction

  task automatic apply(input logic [31:0] ins, input bit is_rand);
    instr = ins;
    #1;
    case (ins[6:0])
      7'b0100011: cov_hit(1);
      7'b1100011: cov_hit(2);
      7'b0110111, 7'b0010111: cov_hit(3);
      7'b1101111: cov_hit(4);
      default:    cov_hit(0);
    endcase
    if (imm[31]) cov_hit(5); else cov_hit(6);
    if (imm == 0) cov_hit(7);
    if (is_rand) rchk($sformatf("op%02h", ins[6:0]), {32'd0, ref_imm(ins)}, {32'd0, imm});
    else         chk($sformatf("instr=%08h", ins), {32'd0, ref_imm(ins)}, {32'd0, imm});
    @(posedge clk);
  endtask

  logic [6:0] opl [8];

  initial begin
    tb_init("immediate_gen");
    cov_def(0,"I_type"); cov_def(1,"S_type"); cov_def(2,"B_type"); cov_def(3,"U_type");
    cov_def(4,"J_type"); cov_def(5,"imm_negative"); cov_def(6,"imm_positive"); cov_def(7,"imm_zero");
    opl = '{OP_IMM, OP_LOAD, OP_JALR, OP_SYSTEM, OP_STORE, OP_BRANCH, OP_LUI, OP_JAL};

    // -------- V1 directed: all-zero / all-one immediate fields, sign boundaries ----
    foreach (opl[i]) begin
      apply({25'h000_0000, opl[i]}, 0);              // every immediate bit 0
      apply({25'h1FF_FFFF, opl[i]}, 0);              // every immediate bit 1 -> -1 / max
      apply({1'b0, 24'hFF_FFFF, opl[i]}, 0);         // sign bit 0, rest 1 (max positive)
      apply({1'b1, 24'h00_0000, opl[i]}, 0);         // sign bit 1 only (most negative)
      apply({12'h7FF, 13'h0000, opl[i]}, 0);
      apply({12'h800, 13'h1FFF, opl[i]}, 0);
    end
    // walking-one through instr[31:7] for every format: catches any mis-routed bit
    foreach (opl[i])
      for (int b = 7; b < 32; b++)
        apply((32'd1 << b) | {25'd0, opl[i]}, 0);

    // -------- V2/V5: 120 randomized instructions --------------------------------
    for (int i = 0; i < 120; i++)
      apply({$urandom(), 7'h00} | {25'd0, opl[$urandom_range(0,7)]}, 1);

    finish_report();
    $finish;
  end
endmodule
