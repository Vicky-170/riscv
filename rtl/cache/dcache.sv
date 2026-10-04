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
