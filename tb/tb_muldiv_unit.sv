// =============================================================================
// tb_muldiv_unit.sv - V0..V5 for muldiv_unit.sv  (run with -GMUL_IMPL=0 and =1)
//
// Reference model: independent 64-bit signed/unsigned arithmetic implementing
// the RISC-V M-extension definitions, including the mandated special cases
//   x / 0      -> DIV/DIVU = -1 (all ones),  REM/REMU = x
//   INT_MIN/-1 -> DIV = INT_MIN,             REM = 0
// Driver follows the RTL handshake: req is held until ready, ack frees the FSM.
// 110 randomized cases per configuration (220 across both -> meets the RV32M
// minimum of 200 on its own).
// =============================================================================
module tb_muldiv_unit;
  `include "tb_common.svh"

  parameter int MUL_IMPL = 0;

  logic        clk = 0, rst_n = 0, flush = 0, req = 0, ack = 1, ready;
  logic [2:0]  op;
  logic [31:0] a, b, result;
  string       cfgs;

  always #5 clk = ~clk;
  always @(posedge clk) cyc++;

  muldiv_unit #(.MUL_IMPL(MUL_IMPL)) dut (
    .clk(clk), .rst_n(rst_n), .flush(flush), .req(req), .op(op),
    .a(a), .b(b), .ack(ack), .ready(ready), .result(result)
  );

  // ---- assertion: ready must never be asserted without a request -------------
  ap_ready_req: assert property (@(posedge clk) disable iff (!rst_n) ready |-> req);

  // ---- independent reference model --------------------------------------------
  function automatic logic [31:0] ref_md(input logic [2:0] o, input logic [31:0] x, y);
    logic signed [63:0] sx, sy, sp;
    logic        [63:0] ux, uy, up;
    logic signed [31:0] xs, ys;
    sx = $signed({{32{x[31]}}, x});
    sy = $signed({{32{y[31]}}, y});
    ux = {32'd0, x};
    uy = {32'd0, y};
    xs = $signed(x);
    ys = $signed(y);
    case (o)
      3'b000: begin sp = sx * sy;                 return sp[31:0];  end   // MUL
      3'b001: begin sp = sx * sy;                 return sp[63:32]; end   // MULH
      3'b010: begin sp = sx * $signed(uy);        return sp[63:32]; end   // MULHSU
      3'b011: begin up = ux * uy;                 return up[63:32]; end   // MULHU
      3'b100: begin                                                        // DIV
        if (y == 32'd0)                                   return 32'hFFFF_FFFF;
        if (x == 32'h8000_0000 && y == 32'hFFFF_FFFF)     return 32'h8000_0000;
        return $signed(xs / ys);
      end
      3'b101: begin                                                        // DIVU
        if (y == 32'd0) return 32'hFFFF_FFFF;
        return x / y;
      end
      3'b110: begin                                                        // REM
        if (y == 32'd0)                                   return x;
        if (x == 32'h8000_0000 && y == 32'hFFFF_FFFF)     return 32'd0;
        return $signed(xs % ys);
      end
      default: begin                                                       // REMU
        if (y == 32'd0) return x;
        return x % y;
      end
    endcase
  endfunction

  // ---- transaction driver ------------------------------------------------------
  task automatic run_op(input logic [2:0] o, input logic [31:0] x, y, input bit is_rand);
    logic [31:0] exp, got;
    int          waited = 0;
    @(negedge clk);
    op = o; a = x; b = y; req = 1'b1; ack = 1'b1;
    #1;
    while (!ready) begin                           // hold the request until done
      @(negedge clk);
      #1;
      waited++;
      if (waited > 200) begin
        chk($sformatf("TIMEOUT op=%0d a=%0h b=%0h", o, x, y), 64'd1, 64'd0);
        break;
      end
    end
    got = result;
    exp = ref_md(o, x, y);
    cov_hit({29'd0, o});                            // bins 0..7 per operation
    if (y == 32'd0)                       cov_hit(8);
    if (x == 32'h8000_0000 && y == 32'hFFFF_FFFF) cov_hit(9);
    if (x == 32'd0 || y == 32'd0)         cov_hit(10);
    if (x == 32'h7FFF_FFFF || y == 32'h7FFF_FFFF) cov_hit(11);
    if (x[31] != y[31])                   cov_hit(12);   // mixed signs
    if (waited == 0)                      cov_hit(13);   // single-cycle result
    if (waited > 1)                       cov_hit(14);   // multi-cycle result
    if (is_rand) rchk($sformatf("M%0d_op%0d_a%08h_b%08h", MUL_IMPL, o, x, y), {32'd0, exp}, {32'd0, got});
    else         chk($sformatf("op=%0d a=%08h b=%08h", o, x, y), {32'd0, exp}, {32'd0, got});
    @(negedge clk);
    req = 1'b0;                                    // instruction leaves EX
    @(negedge clk);
  endtask

  logic [31:0] corner [12];

  initial begin
    tb_init($sformatf("muldiv_m%0d", MUL_IMPL));
    cfgs = $sformatf("MUL_IMPL=%0d", MUL_IMPL);
    cov_def(0,"MUL"); cov_def(1,"MULH"); cov_def(2,"MULHSU"); cov_def(3,"MULHU");
    cov_def(4,"DIV"); cov_def(5,"DIVU"); cov_def(6,"REM"); cov_def(7,"REMU");
    cov_def(8,"divide_by_zero"); cov_def(9,"INT_MIN_div_minus1"); cov_def(10,"zero_operand");
    cov_def(11,"INT_MAX_operand"); cov_def(12,"mixed_signs");
    cov_def(13,"single_cycle_result"); cov_def(14,"multi_cycle_result");

    corner = '{32'h0000_0000, 32'h0000_0001, 32'hFFFF_FFFF, 32'h8000_0000, 32'h7FFF_FFFF,
               32'h0000_0002, 32'hFFFF_FFFE, 32'h0000_00FF, 32'hFFFF_FF01, 32'h1234_5678,
               32'hDEAD_BEEF, 32'h5A5A_5A5A};

    repeat (3) @(posedge clk);
    rst_n = 1;
    @(posedge clk);

    // -------- V1 directed: full corner x corner cross product for all 8 ops -----
    for (int o = 0; o < 8; o++)
      foreach (corner[i])
        foreach (corner[j])
          run_op(3'(o), corner[i], corner[j], 0);

    // -------- V1 directed: explicitly named mandatory corner cases --------------
    run_op(3'b100, 32'h8000_0000, 32'hFFFF_FFFF, 0);     // INT_MIN / -1  -> INT_MIN
    run_op(3'b110, 32'h8000_0000, 32'hFFFF_FFFF, 0);     // INT_MIN % -1  -> 0
    run_op(3'b100, 32'd7,         32'd0,         0);     // DIV  by zero -> -1
    run_op(3'b101, 32'd7,         32'd0,         0);     // DIVU by zero -> all ones
    run_op(3'b110, 32'd7,         32'd0,         0);     // REM  by zero -> dividend
    run_op(3'b111, 32'd7,         32'd0,         0);     // REMU by zero -> dividend
    run_op(3'b000, 32'h8000_0000, 32'h8000_0000, 0);     // MUL    of two INT_MINs
    run_op(3'b001, 32'h8000_0000, 32'h8000_0000, 0);     // MULH
    run_op(3'b010, 32'h8000_0000, 32'hFFFF_FFFF, 0);     // MULHSU: signed x unsigned
    run_op(3'b011, 32'hFFFF_FFFF, 32'hFFFF_FFFF, 0);     // MULHU  max x max
    run_op(3'b100, 32'hFFFF_FFFF, 32'h0000_0001, 0);     // -1 / 1
    run_op(3'b100, 32'h0000_0001, 32'hFFFF_FFFF, 0);     //  1 / -1
    run_op(3'b110, 32'hFFFF_FFF9, 32'd4,         0);     // -7 % 4  (sign of dividend)
    run_op(3'b110, 32'd7,         32'hFFFF_FFFC, 0);     //  7 % -4
    run_op(3'b100, 32'hFFFF_FFF9, 32'd4,         0);     // -7 / 4  (truncation toward 0)

    // -------- V3: flush must abandon an in-flight operation ---------------------
    @(negedge clk);
    op = 3'b100; a = 32'h1000_0000; b = 32'd3; req = 1'b1;       // start a divide
    repeat (4) @(negedge clk);
    chk("div_busy_not_ready", 64'd0, {63'd0, ready});
    flush = 1'b1; @(negedge clk); flush = 1'b0; req = 1'b0;
    @(negedge clk);
    chk("flush_clears_ready", 64'd0, {63'd0, ready});
    @(negedge clk);
    run_op(3'b100, 32'd100, 32'd7, 0);                           // unit still works after flush

    // -------- V3: stalled ack (result must be held until acknowledged) ----------
    @(negedge clk);
    op = 3'b100; a = 32'd1000; b = 32'd3; req = 1'b1; ack = 1'b0;
    #1;
    while (!ready) begin @(negedge clk); #1; end
    chk("held_result_0", {32'd0, ref_md(3'b100, 32'd1000, 32'd3)}, {32'd0, result});
    repeat (3) @(negedge clk);
    #1;
    chk("held_result_stable", {32'd0, ref_md(3'b100, 32'd1000, 32'd3)}, {32'd0, result});
    chk("still_ready_when_not_acked", 64'd1, {63'd0, ready});
    ack = 1'b1; @(negedge clk); req = 1'b0; @(negedge clk);

    // -------- V2/V5: 110 randomized per configuration ---------------------------
    for (int i = 0; i < 110; i++) begin
      logic [31:0] x, y;
      // ~40% of operands come from the corner pool so special cases keep recurring
      x = ($urandom_range(0, 9) < 4) ? corner[$urandom_range(0, 11)] : $urandom();
      y = ($urandom_range(0, 9) < 4) ? corner[$urandom_range(0, 11)] : $urandom();
      run_op(3'($urandom_range(0, 7)), x, y, 1);
    end

    finish_report();
    $finish;
  end
endmodule
