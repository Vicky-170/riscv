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
