// =============================================================================
// muldiv_unit.sv - RV32M multiply / divide
//
//   MUL_IMPL = 0 : MUL/MULH/MULHSU/MULHU in ONE cycle (33x33 signed multiplier,
//                  fast, large).  Division is always iterative.
//   MUL_IMPL = 1 : iterative shift-add multiplier (33 cycles, small).
//   Division     : radix-2 restoring divider on magnitudes, 32 cycles; signs are
//                  fixed up at the end.  Corner cases follow the RISC-V spec:
//                    x/0  -> DIV/DIVU = all ones, REM/REMU = x
//                    INT_MIN / -1 -> DIV = INT_MIN, REM = 0   (falls out of the
//                                    magnitude arithmetic, no special case)
//
// Handshake with the core (instruction stays in EX until it is done):
//   req   : MD instruction is in EX (level, held)
//   ready : result valid this cycle (comb).  Core stalls while req & ~ready.
//   ack   : instruction leaves EX this cycle (frees the FSM from DONE)
//   flush : instruction killed (pipeline flush) -> FSM returns to IDLE
// =============================================================================
module muldiv_unit #(
  parameter int MUL_IMPL = 0
) (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        flush,
  input  logic        req,
  input  logic [2:0]  op,              // funct3: 000 MUL 001 MULH 010 MULHSU 011 MULHU 100 DIV 101 DIVU 110 REM 111 REMU
  input  logic [31:0] a,
  input  logic [31:0] b,
  input  logic        ack,
  output logic        ready,
  output logic [31:0] result
);
  typedef enum logic [1:0] { MD_IDLE, MD_RUN, MD_DONE } md_state_e;
  md_state_e   st;
  logic [2:0]  op_q;
  logic [5:0]  cnt;
  logic [65:0] acc;                    // mul: accumulator | div: {rem[31:0], quo[31:0]}
  logic [65:0] mcand;                  // iterative mul: sign-extended multiplicand (shifts left)
  logic [32:0] mplr;                   // iterative mul: multiplier (shifts right)
  logic [31:0] dvsr;                   // divisor magnitude
  logic        q_neg, r_neg;

  wire is_div    = op[2];
  wire fast_path = (MUL_IMPL == 0) && !is_div;

  // ---- operand preparation ---------------------------------------------------
  wire a_signed = (op[1:0] != 2'b11);            // MUL/MULH/MULHSU: rs1 signed
  wire b_signed = ~op[1];                        // MUL/MULH: rs2 signed
  wire signed [32:0] ma = {a_signed & a[31], a};
  wire signed [32:0] mb = {b_signed & b[31], b};
  wire signed [65:0] prod_f = ma * mb;           // used only when MUL_IMPL == 0

  wire        div_signed = ~op[0];               // DIV/REM signed, DIVU/REMU unsigned
  wire        a_neg      = div_signed & a[31];
  wire        b_neg      = div_signed & b[31];
  wire [31:0] abs_a      = a_neg ? (32'd0 - a) : a;
  wire [31:0] abs_b      = b_neg ? (32'd0 - b) : b;

  // ---- one iteration of restoring division / shift-add ----------------------
  wire [32:0] trial    = {acc[63:32], acc[31]};              // shift next dividend bit into remainder
  wire [32:0] diff     = trial - {1'b0, dvsr};
  wire        sub_ok   = ~diff[32];                          // remainder >= divisor
  wire [31:0] next_rem = sub_ok ? diff[31:0] : trial[31:0];
  wire [31:0] next_quo = {acc[30:0], sub_ok};
  // multiplier bit 32 carries negative weight (two's complement)
  wire [65:0] addend   = mplr[0] ? ((cnt == 6'd32) ? (66'd0 - mcand) : mcand) : 66'd0;

  always_ff @(posedge clk) begin
    if (!rst_n || flush) begin
      st <= MD_IDLE;
    end else begin
      case (st)
        MD_IDLE: if (req && !fast_path) begin
          st   <= MD_RUN;
          op_q <= op;
          cnt  <= 6'd0;
          if (is_div) begin
            acc   <= {34'd0, abs_a};
            dvsr  <= abs_b;
            q_neg <= div_signed & (a[31] ^ b[31]) & (b != 32'd0);   // x/0 -> all ones, not negated
            r_neg <= a_neg;
          end else if (MUL_IMPL != 0) begin
            acc   <= 66'd0;
            mcand <= {{33{ma[32]}}, ma};
            mplr  <= mb;
          end
        end

        MD_RUN: begin
          cnt <= cnt + 6'd1;
          if (op_q[2]) begin
            acc <= {2'b00, next_rem, next_quo};
            if (cnt == 6'd31) st <= MD_DONE;
          end else if (MUL_IMPL != 0) begin
            acc   <= acc + addend;
            mcand <= mcand << 1;
            mplr  <= mplr >> 1;
            if (cnt == 6'd32) st <= MD_DONE;
          end
        end

        MD_DONE: if (ack) st <= MD_IDLE;
        default: st <= MD_IDLE;
      endcase
    end
  end

  // ---- result / ready -----------------------------------------------------------
  always_comb begin
    if (fast_path) begin
      ready  = req;
      result = (op[1:0] == 2'b00) ? prod_f[31:0] : prod_f[63:32];
    end else begin
      ready = req & (st == MD_DONE);
      if (op_q[2])                                   // DIV/DIVU (bit1=0) or REM/REMU (bit1=1)
        result = op_q[1] ? (r_neg ? (32'd0 - acc[63:32]) : acc[63:32])
                         : (q_neg ? (32'd0 - acc[31:0])  : acc[31:0]);
      else
        result = (op_q[1:0] == 2'b00) ? acc[31:0] : acc[63:32];
    end
  end

`ifndef SYNTHESIS
  always @(posedge clk) if (rst_n) begin
    assert (!(ready && st == MD_RUN)) else $error("muldiv: ready during RUN");
  end
`endif
endmodule
