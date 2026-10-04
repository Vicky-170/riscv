// =============================================================================
// native_mem.svh - memory-side model for cache testbenches (included in the TB)
//
// Acts as the "far side" of the cache's native request port:
//   * word-organised backing memory `mem` (16 KiB, address wraps)
//   * configurable latency (0..lat_max), inter-beat gaps (gap_pct %), and a byte
//     address error window [err_lo, err_hi] (beats in the window return rsp_err)
//   * MMIO region (addr[31:28]==4) returns data that changes on every read, so a
//     wrongly-cached peripheral read is caught immediately
//   * SHADOW of which cache lines have been fully and successfully delivered
//     (filled_v/filled_tag) - the independent reference for hit/miss checking.
//     A refill request clears the shadow line at acceptance; the last OK beat sets it.
//   * transaction counters and the last request captured for exact checking
// Expects in the including TB: clk, rst_n, req_valid, req_write, req_addr, req_len,
// req_wdata, req_wstrb (inputs from DUT) and req_ready, rsp_valid, rsp_data, rsp_last,
// rsp_err (driven here); parameters LINES, LINE_BYTES.
// =============================================================================
  localparam int MEM_WORDS = 4096;
  localparam int NM_OFFW   = $clog2(LINE_BYTES);
  localparam int NM_IDXW   = $clog2(LINES);

  logic [31:0] mem [MEM_WORDS];
  int unsigned lat_max = 2, gap_pct = 0;
  logic [31:0] err_lo = 32'hFFFF_FFFF, err_hi = 32'h0000_0000;   // empty window by default

  int          n_st = 0;                        // 0 idle, 1 wait, 2 read data, 3 (unused)
  logic [31:0] q_addr, q_wdata;
  logic [7:0]  q_len;
  logic [3:0]  q_wstrb;
  bit          q_wr, q_err_acc;
  int          q_lat, q_beat;

  int unsigned n_rd_req = 0, n_wr_req = 0, n_refill_req = 0, n_rd_beats = 0;
  logic [31:0] last_req_addr, last_req_wdata, last_bus_rdata;
  logic [7:0]  last_req_len;
  logic [3:0]  last_req_wstrb;
  bit          last_req_wr;

  bit          filled_v   [LINES];
  logic [31:0] filled_tag [LINES];

  function automatic bit in_err(input logic [31:0] a);
    return (a >= err_lo) && (a <= err_hi);
  endfunction
  function automatic logic [31:0] mword(input logic [31:0] a);
    return mem[(a >> 2) % MEM_WORDS];
  endfunction
  function automatic int nm_idx(input logic [31:0] a);  return int'((a >> NM_OFFW) % LINES); endfunction
  function automatic logic [31:0] nm_tag(input logic [31:0] a); return a >> (NM_OFFW + NM_IDXW); endfunction
  function automatic bit line_present(input logic [31:0] a);
    return filled_v[nm_idx(a)] && (filled_tag[nm_idx(a)] == nm_tag(a));
  endfunction
  function automatic logic [31:0] bus_word(input logic [31:0] a);
    // peripheral space returns a different value on every read
    if (a[31:28] == 4'h4) return mword(a) ^ (32'(n_rd_beats) * 32'h0101_0101);
    return mword(a);
  endfunction

  task automatic mem_init();
    for (int i = 0; i < MEM_WORDS; i++) mem[i] = 32'hC0DE_0000 ^ (32'(i) * 32'h0001_0007);
    for (int i = 0; i < LINES; i++) begin filled_v[i] = 0; filled_tag[i] = 0; end
  endtask

  assign req_ready = (n_st == 0) && rst_n;

  always @(posedge clk) begin
    rsp_valid <= 1'b0;
    rsp_last  <= 1'b0;
    rsp_err   <= 1'b0;
    if (!rst_n) begin
      n_st <= 0;
    end else begin
      case (n_st)
        0: if (req_valid) begin                               // accept command
          q_addr <= req_addr; q_len <= req_len; q_wr <= req_write;
          q_wdata <= req_wdata; q_wstrb <= req_wstrb;
          last_req_addr <= req_addr; last_req_len <= req_len; last_req_wr <= req_write;
          last_req_wdata <= req_wdata; last_req_wstrb <= req_wstrb;
          if (req_write) n_wr_req = n_wr_req + 1;
          else begin
            n_rd_req = n_rd_req + 1;
            if (req_len != 0) begin
              n_refill_req = n_refill_req + 1;
              filled_v[nm_idx(req_addr)] = 1'b0;              // victim line is gone
            end
          end
          q_lat <= (lat_max == 0) ? 0 : $urandom_range(0, lat_max);
          q_beat <= 0; q_err_acc <= 1'b0;
          n_st <= 1;
        end
        1: begin
          if (q_lat > 0) q_lat <= q_lat - 1;
          else if (q_wr) begin                                // single-beat write
            if (!in_err(q_addr))
              for (int b = 0; b < 4; b++)
                if (q_wstrb[b]) mem[(q_addr >> 2) % MEM_WORDS][8*b +: 8] = q_wdata[8*b +: 8];
            rsp_valid <= 1'b1; rsp_last <= 1'b1; rsp_err <= in_err(q_addr); rsp_data <= 32'd0;
            n_st <= 0;
          end else n_st <= 2;
        end
        2: if ((gap_pct == 0) || ($urandom_range(0, 99) >= gap_pct)) begin
          logic [31:0] a;
          a = q_addr + 32'(4 * q_beat);
          rsp_valid <= 1'b1;
          rsp_data  <= bus_word(a);
          last_bus_rdata <= bus_word(a);
          rsp_err   <= in_err(a);
          rsp_last  <= (q_beat == q_len);
          n_rd_beats = n_rd_beats + 1;
          if (in_err(a)) q_err_acc <= 1'b1;
          if (q_beat == q_len) begin
            n_st <= 0;
            if (q_len != 0 && !q_err_acc && !in_err(a)) begin  // fully delivered, no errors
              filled_v[nm_idx(q_addr)]   = 1'b1;
              filled_tag[nm_idx(q_addr)] = nm_tag(q_addr);
            end
          end else q_beat <= q_beat + 1;
        end
        default: n_st <= 0;
      endcase
    end
  end
