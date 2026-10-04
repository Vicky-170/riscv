// =============================================================================
// tb_cache_arrays.sv - V0..V5 for cache_tag_array + cache_data_array
//   Shadow model of valid bits / tags / data words with byte enables.  Random
//   traffic mixes set, clear, invalidate-all and byte-masked writes; the read
//   ports (combinational) are checked every cycle against the shadow.
// =============================================================================
module tb_cache_arrays;
  `include "tb_common.svh"

  localparam int LINES = 8, TAG_W = 20, WORDS = 4, IDX_W = 3, WORD_W = 2;

  logic clk = 0, rst_n = 0;
  // tag array
  logic inval_all = 0, set_en = 0, clr_en = 0, rd_valid;
  logic [IDX_W-1:0] rd_idx = 0, set_idx = 0, clr_idx = 0;
  logic [TAG_W-1:0] rd_tag, set_tag = 0;
  // data array
  logic wr_en = 0;
  logic [IDX_W-1:0]  d_rd_idx = 0, wr_idx = 0;
  logic [WORD_W-1:0] d_rd_word = 0, wr_word = 0;
  logic [31:0] rd_data, wr_data = 0;
  logic [3:0]  wr_be = 0;

  always #5 clk = ~clk;
  always @(posedge clk) cyc++;

  cache_tag_array  #(.LINES(LINES), .TAG_W(TAG_W)) u_t (
    .clk(clk), .rst_n(rst_n), .inval_all(inval_all), .rd_idx(rd_idx), .rd_tag(rd_tag),
    .rd_valid(rd_valid), .set_en(set_en), .set_idx(set_idx), .set_tag(set_tag),
    .clr_en(clr_en), .clr_idx(clr_idx));
  cache_data_array #(.LINES(LINES), .WORDS(WORDS)) u_d (
    .clk(clk), .rd_idx(d_rd_idx), .rd_word(d_rd_word), .rd_data(rd_data),
    .wr_en(wr_en), .wr_idx(wr_idx), .wr_word(wr_word), .wr_data(wr_data), .wr_be(wr_be));

  // ---- V3 assertions -------------------------------------------------------------
  ap_inval: assert property (@(posedge clk) disable iff (!rst_n) inval_all |=> (u_t.valid == '0));
  ap_reset: assert property (@(posedge clk) disable iff (cyc < 2) !rst_n |=> (u_t.valid == '0));
  ap_set:   assert property (@(posedge clk) disable iff (!rst_n)
                             (set_en && !inval_all) |=> u_t.valid[$past(set_idx)]);

  // ---- reference model ---------------------------------------------------------------
  bit          s_v [LINES];
  logic [TAG_W-1:0] s_tag [LINES];
  logic [31:0] s_dat [LINES*WORDS];
  logic [31:0] s_msk [LINES*WORDS];              // bytes actually written so far (array is unreset)

  function automatic void sreset();
    for (int i = 0; i < LINES; i++) s_v[i] = 0;
    for (int i = 0; i < LINES*WORDS; i++) begin s_dat[i] = 0; s_msk[i] = 0; end
  endfunction

  task automatic step(input bit is_rand);
    logic [31:0] e_d, m_d;
    #1;
    m_d = s_msk[{d_rd_idx, d_rd_word}];
    e_d = s_dat[{d_rd_idx, d_rd_word}] & m_d;
    if (s_v[rd_idx]) cov_hit(0); else cov_hit(1);
    if (s_v[rd_idx] && rd_valid) cov_hit(2);
    if (wr_en && wr_be == 4'hF) cov_hit(3);
    if (wr_en && wr_be != 4'hF && wr_be != 4'h0) cov_hit(4);   // partial byte write
    if (wr_en && wr_be == 4'h0) cov_hit(5);                    // no-op write
    if (inval_all) cov_hit(6);
    if (clr_en) cov_hit(7);
    if (set_en) cov_hit(8);
    if (set_en && clr_en) cov_hit(9);
    // scoreboard compare of the combinational read ports
    if (is_rand) begin
      rchk("rd_valid", {63'd0, s_v[rd_idx]}, {63'd0, rd_valid});
      if (s_v[rd_idx]) rchk("rd_tag", {44'd0, s_tag[rd_idx]}, {44'd0, rd_tag});
      rchk("rd_data", {32'd0, e_d}, {32'd0, rd_data & m_d});
    end else begin
      chk("rd_valid", {63'd0, s_v[rd_idx]}, {63'd0, rd_valid});
      if (s_v[rd_idx]) chk("rd_tag", {44'd0, s_tag[rd_idx]}, {44'd0, rd_tag});
      chk("rd_data", {32'd0, e_d}, {32'd0, rd_data & m_d});
    end
    // model update (mirrors documented semantics: inval > clr/set, set wins over clr)
    if (inval_all) for (int i = 0; i < LINES; i++) s_v[i] = 0;
    else begin
      if (clr_en) s_v[clr_idx] = 0;
      if (set_en) s_v[set_idx] = 1;
    end
    if (set_en) s_tag[set_idx] = set_tag;
    if (wr_en)
      for (int b = 0; b < 4; b++)
        if (wr_be[b]) begin
          s_dat[{wr_idx, wr_word}][8*b +: 8] = wr_data[8*b +: 8];
          s_msk[{wr_idx, wr_word}][8*b +: 8] = 8'hFF;
        end
    @(posedge clk);
    @(negedge clk);
    inval_all = 0; set_en = 0; clr_en = 0; wr_en = 0;
  endtask

  initial begin
    tb_init("cache_arrays");
    cov_def(0,"read_valid_line"); cov_def(1,"read_invalid_line"); cov_def(2,"valid_agrees");
    cov_def(3,"full_word_write"); cov_def(4,"partial_byte_write"); cov_def(5,"write_be_zero");
    cov_def(6,"invalidate_all"); cov_def(7,"clear_one"); cov_def(8,"set_tag"); cov_def(9,"set_and_clear");
    sreset();
    repeat (3) @(negedge clk);
    // V1: everything invalid out of reset
    for (int i = 0; i < LINES; i++) begin rd_idx = 3'(i); step(0); end
    rst_n = 1; @(negedge clk);

    // V1: set, read back tag, clear, set with a different tag
    for (int i = 0; i < LINES; i++) begin
      set_en = 1; set_idx = 3'(i); set_tag = 20'hA0000 + 20'(i); rd_idx = 3'(i); step(0);
      rd_idx = 3'(i); step(0);
    end
    clr_en = 1; clr_idx = 3'd3; rd_idx = 3'd3; step(0);       // clear one line
    rd_idx = 3'd3; step(0); rd_idx = 3'd4; step(0);           // neighbour unaffected
    set_en = 1; set_idx = 3'd3; set_tag = 20'h12345; step(0); // re-install, new tag
    rd_idx = 3'd3; step(0);
    inval_all = 1; step(0);                                    // invalidate everything
    for (int i = 0; i < LINES; i++) begin rd_idx = 3'(i); step(0); end
    // set + inval same cycle: invalidate wins
    set_en = 1; set_idx = 3'd2; set_tag = 20'h55555; inval_all = 1; step(0);
    rd_idx = 3'd2; step(0);
    // set + clear same cycle on the same line: documented "set wins"
    set_en = 1; clr_en = 1; set_idx = 3'd5; clr_idx = 3'd5; set_tag = 20'h77777; step(0);
    rd_idx = 3'd5; step(0);
    // data: full word writes to every word, read all back
    for (int l = 0; l < LINES; l++)
      for (int w = 0; w < WORDS; w++) begin
        wr_en = 1; wr_idx = 3'(l); wr_word = 2'(w); wr_data = 32'h1000_0000 + 32'(l*16 + w); wr_be = 4'hF;
        step(0);
      end
    for (int l = 0; l < LINES; l++)
      for (int w = 0; w < WORDS; w++) begin d_rd_idx = 3'(l); d_rd_word = 2'(w); step(0); end
    // byte enables: write each single byte lane, then combinations
    for (int be = 0; be < 16; be++) begin
      wr_en = 1; wr_idx = 3'd2; wr_word = 2'd1; wr_data = 32'hFEDC_BA98 ^ (32'(be) * 32'h0101_0101);
      wr_be = 4'(be); step(0);
      d_rd_idx = 3'd2; d_rd_word = 2'd1; step(0);
    end
    // a write to one word must not disturb its neighbours
    wr_en = 1; wr_idx = 3'd6; wr_word = 2'd2; wr_data = 32'hFFFF_FFFF; wr_be = 4'hF; step(0);
    d_rd_idx = 3'd6; d_rd_word = 2'd1; step(0);
    d_rd_idx = 3'd6; d_rd_word = 2'd3; step(0);
    d_rd_idx = 3'd7; d_rd_word = 2'd2; step(0);

    // V2/V5: 120 random cycles
    for (int i = 0; i < 120; i++) begin
      rd_idx = 3'($urandom_range(0, 7)); d_rd_idx = 3'($urandom_range(0, 7));
      d_rd_word = 2'($urandom_range(0, 3));
      inval_all = ($urandom_range(0, 19) == 0);
      set_en = ($urandom_range(0, 2) == 0); set_idx = 3'($urandom_range(0, 7)); set_tag = 20'($urandom());
      clr_en = ($urandom_range(0, 3) == 0); clr_idx = 3'($urandom_range(0, 7));
      wr_en  = ($urandom_range(0, 1) == 0); wr_idx = 3'($urandom_range(0, 7));
      wr_word = 2'($urandom_range(0, 3)); wr_data = $urandom(); wr_be = 4'($urandom());
      step(1);
    end
    finish_report();
    $finish;
  end
endmodule
