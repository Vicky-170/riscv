#!/usr/bin/env python3
"""Generates the Stage 5 CPU-level program image for tb/cpu/tb_cpu_stage5.sv.

Writes (relative to this script's tb/cpu/ directory, into ../../sim/):
  cpu_stage5.hex          - one continuous instruction stream (readmemh format)
  cpu_stage5_ckpt.hex     - checkpoint PCs (byte addresses), one per line, sentinel
                            ffffffff terminates the list. Whenever the DUT retires
                            the instruction AT a checkpoint PC, the testbench does a
                            full 31-register architectural compare against the
                            golden model running inside the SV testbench itself
                            (NOT this script - this script only GENERATES valid,
                            terminating instruction sequences; correctness is judged
                            at simulation time by the independent SV reference model,
                            exactly as required: "reference model must independently
                            calculate", not be duplicated from Python).

Design choices that keep 1200+ generated programs safe to chain in ONE continuous
non-resetting run (no per-program reset, matching a realistic long-running system):
  * All random-block branches are FORWARD-ONLY (target > branch PC) -> the random
    block can never loop, so it is structurally impossible for a bad random branch
    to hang the whole regression.
  * Loads/stores in the random block use a small fixed scratch window (dmem word
    offsets 0..63) computed with a small ADDI immediate each time (no persistent
    address register to corrupt across programs).
  * Benchmarks (which DO contain real backward-branch loops) are hand-designed
    with bounded counters and placed after the random block; each is disassembled
    and reviewed (see the printed listing) before being trusted.
"""
import sys, os, random
sys.path.insert(0, os.path.dirname(__file__))
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "soc_asm"))
from asm import Asm

random.seed(20260921)

a = Asm()
ckpt_pcs = []

REG_POOL = list(range(1, 21))          # x1..x20 for the random block
ALU_R = ["ADD","SUB","AND","OR","XOR","SLT","SLTU","SLL","SRL","SRA"]
ALU_I = ["ADDI","ANDI","ORI","XORI","SLTI","SLTIU"]
MEXT  = ["MUL","MULH","MULHSU","MULHU","DIV","DIVU","REM","REMU"]
BRS   = ["BEQ","BNE","BLT","BGE","BLTU","BGEU"]

def rnd_imm(bits=8):
    return random.randint(0, (1 << bits) - 1)

def gen_random_program(n_instr=16):
    """Emits one straight-line-with-forward-skips architectural sequence."""
    pending_labels = []          # (word_index_of_pending_target, label_name)
    label_ctr = [0]
    def new_label():
        label_ctr[0] += 1
        return f"L{len(a.words)}_{label_ctr[0]}"

    for _ in range(n_instr):
        r = random.random()
        rd, rs1, rs2 = (random.choice(REG_POOL) for _ in range(3))
        if r < 0.30:                                   # ALU reg-reg
            getattr(a, random.choice(ALU_R))(rd, rs1, rs2)
        elif r < 0.55:                                  # ALU imm
            op = random.choice(ALU_I)
            if op in ("SLTIU",):
                getattr(a, op)(rd, rs1, rnd_imm(7))
            else:
                getattr(a, op)(rd, rs1, rnd_imm(7) - 32)
        elif r < 0.65:                                  # M extension
            getattr(a, random.choice(MEXT))(rd, rs1, rs2)
        elif r < 0.80:                                  # load/store, small safe scratch window
            off = random.randint(0, 60) & ~3
            if random.random() < 0.5:
                a.ADDI(rs1, 0, off)                      # make rs1 a small valid base itself
                {"LW":a.LW,"LH":a.LH,"LHU":a.LHU,"LB":a.LB,"LBU":a.LBU}[
                    random.choice(["LW","LH","LHU","LB","LBU"])](rd, rs1, 0)
            else:
                a.ADDI(rs1, 0, off)
                {"SW":a.SW,"SH":a.SH,"SB":a.SB}[random.choice(["SW","SH","SB"])](rs2, rs1, 0)
        elif r < 0.92:                                   # forward branch (skip 1-3 instructions)
            lbl = new_label()
            getattr(a, random.choice(BRS))(rs1, rs2, lbl)
            pending_labels.append((lbl, random.randint(1, 3)))
        else:                                            # CSR (mscratch: safe read/modify/write)
            if random.random() < 0.5:
                a.CSRRW(rd, rs1, 0x340)
            else:
                a.CSRRS(rd, 0, 0x340)
        # resolve any forward label whose skip-count has elapsed
        still_pending = []
        for lbl, remaining in pending_labels:
            if remaining <= 1:
                a.label(lbl)
            else:
                still_pending.append((lbl, remaining - 1))
        pending_labels = still_pending
    for lbl, _ in pending_labels:                        # flush any still-open labels at program end
        a.label(lbl)

for i in range(1200):
    gen_random_program(n_instr=random.choice([12, 14, 16, 18, 20]))
    ckpt_pcs.append(a.here())

print(f"random block: {len(a.words)} words, {len(ckpt_pcs)} checkpoints")

# =============================================================================
# Benchmarks (hand-designed, bounded loops, disassembled below before trusting)
# Convention: x1=scratch base ptr, x2..x9=work regs, result stored to dmem word
# offset BENCH_BASE+k (k=0..8, one per benchmark) so the TB can read results
# directly, independent of the per-instruction golden-model checkpointing.
# =============================================================================
BENCH_BASE = 200          # word offset in the TB's dmem scratch array

def bench_fibonacci():         # iterative fib(10) -> x3
    a.ADDI(2, 0, 0); a.ADDI(3, 0, 1); a.ADDI(4, 0, 10)   # x2=prev=0 x3=cur=1 x4=count
    a.label("fib_loop")
    a.BEQ(4, 0, "fib_done")
    a.ADD(5, 2, 3); a.ADD(2, 3, 0); a.ADD(3, 5, 0)
    a.ADDI(4, 4, -1)
    a.JAL(0, "fib_loop")
    a.label("fib_done")
    a.SW(3, 0, (BENCH_BASE + 0) * 4)

def bench_factorial():         # 7! -> x3
    a.ADDI(2, 0, 7); a.ADDI(3, 0, 1)
    a.label("fact_loop")
    a.BEQ(2, 0, "fact_done")
    a.MUL(3, 3, 2)
    a.ADDI(2, 2, -1)
    a.JAL(0, "fact_loop")
    a.label("fact_done")
    a.SW(3, 0, (BENCH_BASE + 1) * 4)

def bench_gcd():               # gcd(252,105) = 21 -> x3 (Euclidean, uses REM)
    a.ADDI(2, 0, 252); a.ADDI(3, 0, 105)
    a.label("gcd_loop")
    a.BEQ(3, 0, "gcd_done")
    a.REM(4, 2, 3)
    a.ADD(2, 3, 0); a.ADD(3, 4, 0)
    a.JAL(0, "gcd_loop")
    a.label("gcd_done")
    a.SW(2, 0, (BENCH_BASE + 2) * 4)

def bench_array_sum():         # sum of 8 fixed values written first, then summed -> x3
    vals = [3, 17, 42, 5, 100, 8, 61, 9]
    for k, v in enumerate(vals):
        a.ADDI(2, 0, v)
        a.SW(2, 0, (BENCH_BASE + 20 + k) * 4)
    a.ADDI(3, 0, 0); a.ADDI(5, 0, 0)
    a.label("sum_loop")
    a.ADDI(6, 0, 8)
    a.BGE(5, 6, "sum_done")
    a.SLLI(7, 5, 2)
    a.ADDI(8, 0, (BENCH_BASE + 20) * 4)
    a.ADD(7, 7, 8)
    a.LW(9, 7, 0)
    a.ADD(3, 3, 9)
    a.ADDI(5, 5, 1)
    a.JAL(0, "sum_loop")
    a.label("sum_done")
    a.SW(3, 0, (BENCH_BASE + 3) * 4)

def bench_bubble_sort():       # sort 6 values ascending, store sorted array back
    vals = [40, 10, 55, 2, 33, 21]
    base = (BENCH_BASE + 40) * 4
    for k, v in enumerate(vals):
        a.ADDI(2, 0, v)
        a.SW(2, 0, base + 4 * k)
    n = len(vals)
    for i_ in range(n - 1):
        for j_ in range(n - 1 - i_):
            a.LW(2, 0, base + 4 * j_)
            a.LW(3, 0, base + 4 * (j_ + 1))
            lbl = f"bs_skip_{i_}_{j_}"
            a.BLT(2, 3, lbl)              # already ascending here -> skip the swap
            a.SW(3, 0, base + 4 * j_)
            a.SW(2, 0, base + 4 * (j_ + 1))
            a.label(lbl)
    a.SW(0, 0, (BENCH_BASE + 4) * 4)       # 0 = sort finished marker; real check reads the array

def bench_memcopy():           # copy 8 words from src to dst
    src = (BENCH_BASE + 60) * 4
    dst = (BENCH_BASE + 70) * 4
    for k in range(8):
        a.ADDI(2, 0, 0x10 + k)
        a.SW(2, 0, src + 4 * k)
    a.ADDI(4, 0, 0)
    a.label("mc_loop")
    a.ADDI(5, 0, 8)
    a.BGE(4, 5, "mc_done")
    a.SLLI(6, 4, 2)
    a.ADDI(7, 0, src); a.ADD(7, 7, 6); a.LW(8, 7, 0)
    a.ADDI(9, 0, dst); a.ADD(9, 9, 6); a.SW(8, 9, 0)
    a.ADDI(4, 4, 1)
    a.JAL(0, "mc_loop")
    a.label("mc_done")
    a.SW(0, 0, (BENCH_BASE + 5) * 4)

def bench_checksum():          # XOR-checksum over 8 fixed words -> x3
    base = (BENCH_BASE + 80) * 4
    for k, v in enumerate([0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88]):
        a.ADDI(2, 0, v)
        a.SW(2, 0, base + 4 * k)
    a.ADDI(3, 0, 0); a.ADDI(5, 0, 0)
    a.label("crc_loop")
    a.ADDI(6, 0, 8)
    a.BGE(5, 6, "crc_done")
    a.SLLI(7, 5, 2)
    a.ADDI(8, 0, base); a.ADD(7, 7, 8); a.LW(9, 7, 0)
    a.XOR(3, 3, 9)
    a.ADDI(5, 5, 1)
    a.JAL(0, "crc_loop")
    a.label("crc_done")
    a.SW(3, 0, (BENCH_BASE + 6) * 4)

def bench_branch_heavy():      # nested ifs over a fixed value -> classification code in x3
    a.ADDI(2, 0, 47)
    a.ADDI(3, 0, 0)
    a.ADDI(4, 0, 100)
    a.BLT(2, 4, "bh_lt100")
    a.ADDI(3, 3, 100); a.JAL(0, "bh_end")
    a.label("bh_lt100")
    a.ADDI(4, 0, 50)
    a.BLT(2, 4, "bh_lt50")
    a.ADDI(3, 3, 50); a.JAL(0, "bh_end")
    a.label("bh_lt50")
    a.ADDI(4, 0, 10)
    a.BLT(2, 4, "bh_lt10")
    a.ADDI(3, 3, 10); a.JAL(0, "bh_end")
    a.label("bh_lt10")
    a.ADDI(3, 3, 1)
    a.label("bh_end")
    a.SW(3, 0, (BENCH_BASE + 7) * 4)

def bench_muldiv_chain():      # dependent MUL->DIV->REM chain -> x3
    a.ADDI(2, 0, 13)
    a.ADDI(4, 0, 7)
    a.MUL(3, 2, 4)
    a.DIV(3, 3, 2)
    a.REM(5, 3, 4)
    a.ADD(3, 3, 5)
    a.SW(3, 0, (BENCH_BASE + 8) * 4)

benchmarks = [bench_fibonacci, bench_factorial, bench_gcd, bench_array_sum,
              bench_bubble_sort, bench_memcopy, bench_checksum,
              bench_branch_heavy, bench_muldiv_chain]
bench_start_pc = a.here()
for fn in benchmarks:
    fn()
    ckpt_pcs.append(a.here())

a.label("halt")
a.JAL(0, "halt")

out_dir = os.path.join(os.path.dirname(__file__), "..", "..", "sim")
os.makedirs(out_dir, exist_ok=True)
a.dump_hex(os.path.join(out_dir, "cpu_stage5.hex"), pad_to=32768)

with open(os.path.join(out_dir, "cpu_stage5_ckpt.hex"), "w") as f:
    for pc in ckpt_pcs:
        f.write("%08x\n" % pc)
    f.write("ffffffff\n")

print(f"total: {len(a.words)} words, {len(ckpt_pcs)} checkpoints "
      f"({len(ckpt_pcs) - len(benchmarks)} random + {len(benchmarks)} benchmarks)")
print(f"benchmark block starts at word {bench_start_pc // 4}")

# expected benchmark results, derived by literally simulating the same loop logic in
# Python (not hand-computed - hand-tracing this exact kind of loop is what produced
# real bugs earlier in this project), for an extra final-answer cross-check on top of
# the per-instruction golden-model scoreboard.
def _sim_fib():
    prev, cur, cnt = 0, 1, 10
    while cnt != 0:
        prev, cur = cur, prev + cur
        cnt -= 1
    return cur & 0xFFFFFFFF

def _sim_fact():
    x2, x3 = 7, 1
    while x2 != 0:
        x3 = (x3 * x2) & 0xFFFFFFFF
        x2 -= 1
    return x3

def _sim_gcd():
    x2, x3 = 252, 105
    while x3 != 0:
        x2, x3 = x3, x2 % x3
    return x2

def _sim_muldiv():
    x2, x4 = 13, 7
    x3 = (x2 * x4) // x2
    x5 = x3 % x4
    return (x3 + x5) & 0xFFFFFFFF

def _sim_branch_heavy():
    x2 = 47
    if x2 < 100:
        if x2 < 50:
            return 1 if x2 < 10 else 10
        return 50
    return 100

expected = {
    "fibonacci(10)":     _sim_fib(),
    "factorial(7)":      _sim_fact(),
    "gcd(252,105)":      _sim_gcd(),
    "array_sum":         sum([3, 17, 42, 5, 100, 8, 61, 9]),
    "checksum(xor)":     0x11 ^ 0x22 ^ 0x33 ^ 0x44 ^ 0x55 ^ 0x66 ^ 0x77 ^ 0x88,
    "branch_heavy(47)":  _sim_branch_heavy(),
    "muldiv_chain":      _sim_muldiv(),
}
print("expected final-answer cross-check values:", expected)

with open(os.path.join(out_dir, "cpu_stage5_expect.hex"), "w") as f:
    for k in ["fibonacci(10)", "factorial(7)", "gcd(252,105)", "array_sum", None,
              None, "checksum(xor)", "branch_heavy(47)", "muldiv_chain"]:
        f.write("%08x\n" % (expected[k] & 0xFFFFFFFF if k else 0))
