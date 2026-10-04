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
