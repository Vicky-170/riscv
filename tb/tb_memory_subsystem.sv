// =============================================================================
// tb_memory_subsystem.sv - V0..V5 for memory_subsystem.sv
//
// Integrates icache + dcache + 2 AXI masters + interconnect + ROM + SRAM; the
// peripheral AXI port is terminated by a BFM.  Small geometry (8 lines x 16 B
// caches, 64-word ROM/SRAM) so conflicts and range errors are easy to reach.
//
// Reference model (independent of the DUT)
//   ROM  0x0000_0000 : rom_test.hex words, read-only, write -> error
//   SRAM 0x1000_0000 : shadow word array updated by every successful store
//   PERIPH 0x4xxx_xxxx : BFM, data = f(address), never cached (each access reaches the port)
//   out-of-range words / unmapped regions -> error on both ports
// System behaviours checked: I/D concurrency, write-through coherence for data,
//   I-cache staleness without FENCE.I and freshness after it, ROM write rejection,
//   error reporting on both ports, peripheral bypass.
// =============================================================================
module tb_ps_bfm import rv32im_pkg::*; (
  input  logic clk, rst_n,
  input  axi_req_t s_req,
  output axi_rsp_t s_rsp
);
  int unsigned n_rd = 0, n_wr = 0, p_ready = 100;
  logic [31:0] last_waddr, last_wdata; logic [3:0] last_wstrb;
  bit arok = 0, awok = 0, wok = 0, rvalid_w = 0, rlast_w = 0, bvalid_w = 0, aw_got = 0, w_got = 0;
  int rd_st = 0, wr_st = 0, rd_beat = 0;
  logic [31:0] rd_addr, aw_addr, w_data, rdata_w = 0; logic [7:0] rd_len; logic [3:0] w_strb;
  logic [1:0] rresp_w = 0, bresp_w = 0;
  function automatic logic [31:0] pat(input logic [31:0] a); return {4'd2, 4'hD, 8'h5A, a[15:0]}; endfunction
  wire arready_w = (rd_st == 0) && arok;
  wire awready_w = !aw_got && awok;
  wire wready_w  = !w_got && wok;
  assign s_rsp = {awready_w, wready_w, bresp_w, bvalid_w, arready_w, rdata_w, rresp_w, rlast_w, rvalid_w};
  always @(posedge clk) begin
    bit aw_hs, w_hs;
    arok <= ($urandom_range(0, 99) < p_ready); awok <= ($urandom_range(0, 99) < p_ready); wok <= ($urandom_range(0, 99) < p_ready);
    if (!rst_n) begin rd_st <= 0; wr_st <= 0; aw_got <= 0; w_got <= 0; rvalid_w <= 0; bvalid_w <= 0; end
    else begin
      aw_hs = s_req.awvalid && awready_w; w_hs = s_req.wvalid && wready_w;
      if (s_req.arvalid && arready_w) begin rd_addr <= s_req.araddr; rd_len <= s_req.arlen; rd_beat <= 0; rd_st <= 1; n_rd = n_rd + 1; end
      if (rd_st == 1) begin
        if (!rvalid_w) begin
          if ($urandom_range(0, 99) < p_ready) begin
            rvalid_w <= 1; rlast_w <= (rd_beat == int'(rd_len)); rdata_w <= pat(rd_addr + 32'(4 * rd_beat)); rresp_w <= 0;
          end
        end else if (s_req.rready) begin rvalid_w <= 0; if (rlast_w) rd_st <= 0; else rd_beat <= rd_beat + 1; end
      end
      if (aw_hs) begin aw_got <= 1; aw_addr <= s_req.awaddr; end
      if (w_hs)  begin w_got <= 1; w_data <= s_req.wdata; w_strb <= s_req.wstrb; end
      case (wr_st)
        0: if ((aw_got || aw_hs) && (w_got || w_hs)) begin
             last_waddr = aw_hs ? s_req.awaddr : aw_addr; last_wdata = w_hs ? s_req.wdata : w_data;
             last_wstrb = w_hs ? s_req.wstrb : w_strb; n_wr = n_wr + 1; bresp_w <= 0; wr_st <= 1;
           end
        1: if ($urandom_range(0, 99) < p_ready) begin bvalid_w <= 1; wr_st <= 2; end
        2: if (s_req.bready) begin bvalid_w <= 0; wr_st <= 0; aw_got <= 0; w_got <= 0; end
        default: wr_st <= 0;
      endcase
    end
  end
endmodule

// =============================================================================
module tb_memory_subsystem import rv32im_pkg::*;;
  `include "tb_common.svh"

  localparam int WORDS = 64;

  logic        clk = 0, rst_n = 0;
  logic [31:0] imem_addr = 0, imem_rdata;
  logic        imem_ready, imem_err, imem_inval = 0;
  logic        dmem_req = 0, dmem_we = 0;
  logic [31:0] dmem_addr = 0, dmem_wdata = 0, dmem_rdata;
  logic [3:0]  dmem_be = 0;
  logic        dmem_ready, dmem_err, dmem_busy, evt_icache_miss, evt_dcache_miss;
  axi_req_t    per_req;  axi_rsp_t per_rsp;

  always #5 clk = ~clk;
  always @(posedge clk) cyc++;

  memory_subsystem #(.ICACHE_ENABLE(1), .DCACHE_ENABLE(1), .ICACHE_LINES(8), .ICACHE_LINE_BYTES(16),
                     .DCACHE_LINES(8), .DCACHE_LINE_BYTES(16), .ROM_WORDS(WORDS), .SRAM_WORDS(WORDS),
                     .ROM_INIT_FILE("rom_test.hex")) dut (.*);
  tb_ps_bfm u_per (.clk(clk), .rst_n(rst_n), .s_req(per_req), .s_rsp(per_rsp));

  // ---- V3 assertions (system level) ---------------------------------------------------
  ap_ierr:   assert property (@(posedge clk) disable iff (!rst_n) imem_err |-> imem_ready);
  ap_derr:   assert property (@(posedge clk) disable iff (!rst_n) dmem_err |-> dmem_ready);
  ap_per_stable: assert property (@(posedge clk) disable iff (!rst_n)
                    (per_req.arvalid && !per_rsp.arready) |=> (per_req.arvalid && $stable(per_req.araddr)));
  ap_per_wr_single: assert property (@(posedge clk) disable iff (!rst_n) per_req.awvalid |-> (per_req.awlen == 0));
  ap_per_region: assert property (@(posedge clk) disable iff (!rst_n)
                    per_req.arvalid |-> (per_req.araddr[31:28] == REGION_PERIPH));
  ap_per_region_w: assert property (@(posedge clk) disable iff (!rst_n)
                    per_req.awvalid |-> (per_req.awaddr[31:28] == REGION_PERIPH));
  ap_per_no_ifetch_burst: assert property (@(posedge clk) disable iff (!rst_n)
                    per_req.arvalid |-> (per_req.arlen == 0));   // only D-side uncached reads are legal here

  // ---- reference model ------------------------------------------------------------------
  logic [31:0] sm [WORDS];
  function automatic logic [31:0] rom_word(input int i); return 32'h1000_0000 + 32'(i) * 32'h0000_0111 ^ 32'hA5A5_0000; endfunction
  function automatic logic [31:0] pat(input logic [31:0] a); return {4'd2, 4'hD, 8'h5A, a[15:0]}; endfunction
  function automatic int widx(input logic [31:0] a); return int'(a[27:2]); endfunction
  // returns 1 when the access must fail
  function automatic bit exp_err(input bit we, input logic [31:0] a);
    case (a[31:28])
      REGION_ROM:    return we || (widx(a) >= WORDS);
      REGION_SRAM:   return (widx(a) >= WORDS);
      REGION_PERIPH: return 1'b0;
      default:       return 1'b1;
    endcase
  endfunction
  function automatic logic [31:0] exp_data(input logic [31:0] a);
    case (a[31:28])
      REGION_ROM:    return rom_word(widx(a));
      REGION_SRAM:   return sm[widx(a)];
      default:       return pat(a);
    endcase
  endfunction

  // ---- instruction-side driver ---------------------------------------------------------------
  logic [31:0] i_res = 0; bit i_res_err = 0;
  task automatic i_fetch(input logic [31:0] a, input bit is_rand, input bit check_data = 1);
    int g = 0;
    bit e = exp_err(0, a) && (a[31:28] != REGION_PERIPH);
    @(negedge clk);
    imem_addr = a; #1;
    while (!imem_ready && g < 600) begin @(negedge clk); #1; g++; end
    i_res = imem_rdata; i_res_err = imem_err;
    if (g >= 600) chk("ifetch_TIMEOUT", 1, 0);
    if (is_rand) rchk("i_err", {63'd0, e}, {63'd0, imem_err});
    else         chk($sformatf("i_err a=%08h", a), {63'd0, e}, {63'd0, imem_err});
    if (!e && check_data) begin
      if (is_rand) rchk("i_data", {32'd0, exp_data(a)}, {32'd0, imem_rdata});
      else         chk($sformatf("i_data a=%08h", a), {32'd0, exp_data(a)}, {32'd0, imem_rdata});
    end
    if (a[31:28] == REGION_ROM && !e) cov_hit(0);
    if (a[31:28] == REGION_SRAM && !e) cov_hit(1);
    if (e) cov_hit(2);
    @(posedge clk);
  endtask

  task automatic i_inval();
    @(negedge clk); imem_inval = 1; @(negedge clk); imem_inval = 0;
  endtask

  // ---- data-side driver -------------------------------------------------------------------------
  logic [31:0] d_res = 0; bit d_res_err = 0;
  task automatic d_op(input bit we, input logic [31:0] a, input logic [31:0] wd, input logic [3:0] be, input bit is_rand);
    int g = 0; bit e; int n_r0, n_w0;
    e = exp_err(we, a);
    n_r0 = u_per.n_rd; n_w0 = u_per.n_wr;
    @(negedge clk);
    dmem_req = 1; dmem_we = we; dmem_addr = a; dmem_wdata = wd; dmem_be = be; #1;
    while (!dmem_ready && g < 800) begin @(negedge clk); #1; g++; end
    d_res = dmem_rdata; d_res_err = dmem_err;
    if (g >= 800) chk("dop_TIMEOUT", 1, 0);
    if (is_rand) rchk("d_err", {63'd0, e}, {63'd0, dmem_err});
    else         chk($sformatf("d_err we=%0b a=%08h", we, a), {63'd0, e}, {63'd0, dmem_err});
    if (!we && !e) begin
      if (is_rand) rchk("d_data", {32'd0, exp_data(a)}, {32'd0, dmem_rdata});
      else         chk($sformatf("d_data a=%08h", a), {32'd0, exp_data(a)}, {32'd0, dmem_rdata});
    end
    @(posedge clk); @(negedge clk);
    dmem_req = 0; dmem_we = 0;
    // reference updates and port accounting
    if (we && !e && a[31:28] == REGION_SRAM)
      for (int b = 0; b < 4; b++) if (be[b]) sm[widx(a)][8*b +: 8] = wd[8*b +: 8];
    if (a[31:28] == REGION_PERIPH) begin
      repeat (3) @(negedge clk);
      if (we) begin
        chk("periph_store_reaches_port", 64'(n_w0 + 1), 64'(u_per.n_wr));
        chk("periph_store_strobe", {60'd0, be}, {60'd0, u_per.last_wstrb});
        cov_hit(6);
      end else begin
        chk("periph_load_reaches_port", 64'(n_r0 + 1), 64'(u_per.n_rd));   // never served from a cache
        cov_hit(5);
      end
    end
    if (a[31:28] == REGION_ROM && !e) cov_hit(3);
    if (a[31:28] == REGION_SRAM && !e) cov_hit(4);
    if (e) cov_hit(7);
    if (we && a[31:28] == REGION_ROM) cov_hit(8);                          // ROM write rejection
    if (we && a[31:28] == REGION_SRAM && !e) cov_hit(9);
  endtask
  task automatic ld(input logic [31:0] a, input bit r = 0); d_op(0, a, 32'd0, 4'h0, r); endtask
  task automatic st(input logic [31:0] a, input logic [31:0] d, input logic [3:0] be, input bit r = 0); d_op(1, a, d, be, r); endtask

  // ---- concurrent random threads (own tasks: Verilator fork/loop-variable workaround) --------------
  task automatic thr_i(input int n);
    for (int i = 0; i < n; i++) begin
      logic [31:0] a;
      case ($urandom_range(0, 9))
        0, 1, 2, 3: a = {4'h0, 28'($urandom_range(0, WORDS - 1) * 4)};                 // ROM
        4, 5, 6:    a = {4'h1, 28'($urandom_range(WORDS / 2, WORDS - 1) * 4)};         // SRAM upper half (never written concurrently)
        7:          a = {4'h0, 28'($urandom_range(WORDS, WORDS + 8) * 4)};             // ROM out of range
        8:          a = {4'h1, 28'($urandom_range(WORDS, WORDS + 8) * 4)};             // SRAM out of range
        default:    a = {4'($urandom_range(2, 3)), 28'($urandom_range(0, 40) * 4)};    // unmapped
      endcase
      if ($urandom_range(0, 9) == 0) i_inval();
      i_fetch(a, 1);
    end
  endtask
  task automatic thr_d(input int n);
    for (int i = 0; i < n; i++) begin
      logic [31:0] a, wd; logic [3:0] be; int r = $urandom_range(0, 9);
      case ($urandom_range(0, 9))
        0, 1:    a = {4'h0, 28'($urandom_range(0, WORDS + 4) * 4)};                     // ROM (+ few out of range)
        2, 3, 4, 5: a = {4'h1, 28'($urandom_range(0, WORDS / 2 - 1) * 4)};             // SRAM lower half
        6:       a = {4'h1, 28'($urandom_range(WORDS, WORDS + 4) * 4)};                 // SRAM out of range
        7, 8:    a = {4'h4, 28'($urandom_range(0, 15) * 4)};                             // peripheral
        default: a = {4'($urandom_range(2, 3)), 28'($urandom_range(0, 40) * 4)};        // unmapped
      endcase
      case ($urandom_range(0, 2))
        0: begin be = 4'b0001 << $urandom_range(0, 3); wd = {4{8'($urandom())}}; end
        1: begin be = ($urandom_range(0, 1)) ? 4'b1100 : 4'b0011; wd = {2{16'($urandom())}}; end
        default: begin be = 4'hF; wd = $urandom(); end
      endcase
      if (r < 5) d_op(1, a, wd, be, 1); else d_op(0, a, 32'd0, 4'h0, 1);
    end
  endtask

  initial begin
    tb_init("memory_subsystem");
    cov_def(0,"ifetch_ROM"); cov_def(1,"ifetch_SRAM"); cov_def(2,"ifetch_error"); cov_def(3,"dload_ROM");
    cov_def(4,"dload_or_store_SRAM"); cov_def(5,"periph_load_bypass"); cov_def(6,"periph_store");
    cov_def(7,"dside_error"); cov_def(8,"ROM_write_rejected"); cov_def(9,"SRAM_store");
    cov_def(10,"simultaneous_I_D_miss"); cov_def(11,"stale_ifetch_without_fencei");
    cov_def(12,"fresh_ifetch_after_fencei"); cov_def(13,"icache_miss_event"); cov_def(14,"dcache_miss_event");
    for (int i = 0; i < WORDS; i++) sm[i] = 32'd0;
    repeat (3) @(negedge clk);
    rst_n = 1;
    i_fetch(32'h0, 0, 0);                                   // settle the reset-time fetch of address 0
    repeat (6) @(negedge clk);

    // ---- V1: ROM fetch and data reads -----------------------------------------------------------
    for (int i = 0; i < 16; i++) i_fetch(32'(i * 4), 0);
    for (int i = 0; i < 16; i++) ld(32'(i * 4));
    ld(32'h0000_00FC);                                        // last ROM word
    // ---- V1: SRAM writes (write-through) and data coherence ----------------------------------------
    st(32'h1000_0000, 32'hAABB_CCDD, 4'hF);  ld(32'h1000_0000);
    st(32'h1000_0004, 32'h1122_3344, 4'hF);  ld(32'h1000_0004);
    st(32'h1000_0000, 32'h0000_00EE, 4'b0001); ld(32'h1000_0000);
    st(32'h1000_0000, 32'hEE00_0000, 4'b1000); ld(32'h1000_0000);
    st(32'h1000_0004, 32'h5678_0000, 4'b1100); ld(32'h1000_0004);
    st(32'h1000_00FC, 32'hCAFE_F00D, 4'hF);  ld(32'h1000_00FC);    // last SRAM word
    // no-write-allocate behaviour observable through the system: store then load of a fresh line
    st(32'h1000_0040, 32'h0BAD_CAFE, 4'hF);  ld(32'h1000_0040);
    // conflict between two SRAM lines mapping to one D-cache index (8 lines x 16B = 128B apart)
    st(32'h1000_0010, 32'h1111_1111, 4'hF); st(32'h1000_0090, 32'h2222_2222, 4'hF);
    ld(32'h1000_0010); ld(32'h1000_0090); ld(32'h1000_0010);
    // ---- V1: ROM write rejection: error reported, contents unchanged -------------------------------------
    st(32'h0000_0010, 32'hDEAD_BEEF, 4'hF);
    ld(32'h0000_0010);
    st(32'h0000_0040, 32'hDEAD_BEEF, 4'b0011); i_fetch(32'h0000_0040, 0);
    // ---- V1: out-of-range and unmapped regions (both ports) -----------------------------------------------
    ld(32'h0000_0100); ld(32'h0000_01FC); st(32'h0000_0100, 32'h1, 4'hF);
    ld(32'h1000_0100); st(32'h1000_0100, 32'h1, 4'hF); ld(32'h1000_0FFC);
    ld(32'h2000_0000); st(32'h2000_0000, 32'h1, 4'hF); ld(32'h8000_0000); st(32'hF000_0004, 32'h1, 4'hF);
    i_fetch(32'h0000_0100, 0); i_fetch(32'h1000_0100, 0); i_fetch(32'h2000_0000, 0); i_fetch(32'h3000_0040, 0);
    i_fetch(32'h0000_0104, 0);                                 // same erroring line again
    i_fetch(32'h0000_0010, 0);                                 // a good line clears the error state
    // ---- V1: peripheral region is uncached (each access reaches the peripheral port) -----------------------
    ld(32'h4000_0100); ld(32'h4000_0100); ld(32'h4000_1004); st(32'h4000_2008, 32'h55, 4'b0001); st(32'h4000_2008, 32'h66, 4'b0001);
    ld(32'h4000_2008);
    // ---- V1: self-modifying code: stale without FENCE.I, fresh after it ---------------------------------------
    st(32'h1000_0080 + 32'h40, 32'hAAAA_0001, 4'hF);
    i_inval();
    i_fetch(32'h1000_00C0, 0);                                 // I$ now holds the line
    st(32'h1000_00C0, 32'hBBBB_0002, 4'hF);                    // modify the instruction in SRAM
    i_fetch(32'h1000_00C0, 0, 0);
    chk("stale_fetch_without_fencei", 64'hAAAA_0001, {32'd0, i_res}); cov_hit(11);
    i_inval();
    i_fetch(32'h1000_00C0, 0);                                 // exp_data() now has the new value
    chk("fresh_fetch_after_fencei", 64'hBBBB_0002, {32'd0, i_res}); cov_hit(12);
    // ---- V1: simultaneous I-side and D-side cache misses -------------------------------------------------------
    i_inval();
    ld(32'h0000_00E0);                                         // warm one D line so the mix is not all misses
    begin
      int m0 = evt_icache_miss;
      fork
        thr_i_one(32'h0000_0060);
        thr_d_one(32'h0000_00A0);
      join
      cov_hit(10);
    end
    fork
      thr_i_one(32'h1000_0060);
      thr_d_one(32'h1000_0020);
    join
    fork
      thr_i_one(32'h0000_0020);
      thr_d_one(32'h0000_00A0);
    join

    // ---- V2/V5: preload SRAM upper half, then 110 concurrent random operations ----------------------------------------
    for (int i = WORDS / 2; i < WORDS; i++) st(32'h1000_0000 + 32'(i * 4), 32'hF000_0000 + 32'(i) * 32'h0101, 4'hF);
    i_inval();
    fork
      thr_i(55);
      thr_d(55);
    join

    finish_report();
    $finish;
  end

  // one-shot helpers for the directed concurrency tests
  task automatic thr_i_one(input logic [31:0] a); i_fetch(a, 0); endtask
  task automatic thr_d_one(input logic [31:0] a); ld(a); endtask

  // miss-event coverage
  always @(posedge clk) begin
    if (evt_icache_miss) cov_hit(13);
    if (evt_dcache_miss) cov_hit(14);
  end
endmodule
