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
