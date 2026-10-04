// =============================================================================
// apb_drv.svh - APB master tasks shared by the peripheral testbenches
//   Requires in the including TB: clk, psel, penable, pwrite, paddr, pwdata, pstrb,
//   prdata, pready, pslverr, a global `bit apb_is_rand`, and a function
//   `model_read(addr)` returning the reference value at the sampling instant.
//   apb_rd computes the expectation BEFORE sampling so no clock edge can intervene.
// =============================================================================
  bit apb_is_rand = 0;

  task automatic apb_wr(input logic [11:0] a, input logic [31:0] d, input logic [3:0] s);
    @(negedge clk);
    psel = 1; penable = 0; pwrite = 1; paddr = a; pwdata = d; pstrb = s;
    @(negedge clk);
    penable = 1;
    #1;
    if (apb_is_rand) begin rchk("pready_wr", 1, {63'd0, pready}); rchk("pslverr_wr", 0, {63'd0, pslverr}); end
    else begin chk("pready_wr", 1, {63'd0, pready}); chk("pslverr_wr", 0, {63'd0, pslverr}); end
    @(negedge clk);
    psel = 0; penable = 0; pwrite = 0; pstrb = 0;
  endtask

  task automatic apb_rd(input logic [11:0] a, output logic [31:0] d);
    logic [31:0] e;
    @(negedge clk);
    psel = 1; penable = 0; pwrite = 0; paddr = a; pstrb = 0;
    @(negedge clk);
    penable = 1;
    e = model_read(a);
    #1;
    d = prdata;
    if (apb_is_rand) begin
      rchk($sformatf("rd@%03h", a), {32'd0, e}, {32'd0, d});
      rchk("pready_rd", 1, {63'd0, pready}); rchk("pslverr_rd", 0, {63'd0, pslverr});
    end else begin
      chk($sformatf("rd@%03h", a), {32'd0, e}, {32'd0, d});
      chk("pready_rd", 1, {63'd0, pready}); chk("pslverr_rd", 0, {63'd0, pslverr});
    end
    @(negedge clk);
    psel = 0; penable = 0;
  endtask

  task automatic apb_idle(input int n); psel = 0; penable = 0; pwrite = 0; repeat (n) @(negedge clk); endtask

  function automatic logic [31:0] merge(input logic [31:0] old_v, new_v, input logic [3:0] be);
    logic [31:0] r = old_v;
    for (int b = 0; b < 4; b++) if (be[b]) r[8*b +: 8] = new_v[8*b +: 8];
    return r;
  endfunction
