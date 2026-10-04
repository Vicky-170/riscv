#!/usr/bin/env python3
"""Generates the Stage 6 SoC-level random regression firmware for
tb/soc/tb_soc_stage6.sv: 1200 short chained micro-tests, each exercising the
REAL memory map end to end (core -> I$/D$ -> AXI4 -> interconnect -> AXI-to-APB
-> a randomly chosen peripheral register), through the actual rv32im_soc RTL.

Each micro-test: a couple of ALU instructions compute a pseudo-random 32-bit
value from a Python-chosen immediate, the firmware writes it to a randomly
chosen RW peripheral register (GPIO OUT/DIR/IRQ_EN, TIMER MTIMECMP_LO/HI/CTRL,
INTC ENABLE, UART BAUD/CTRL), reads it straight back, and stores the read-back
value to a unique SRAM slot. Since every targeted register is a plain
read-after-write store (no hidden side effects beyond the bits actually
implemented - e.g. TIMER CTRL only has bit0 defined), the expected read-back is
computable in Python directly from the value written and each register's valid
bit mask. A mismatch means the value was corrupted somewhere on the way to or
from the peripheral, or (for a masked register) the mask itself needs revisiting.

Directed system tests (boot, UART TX, GPIO pins, GPIO-in roundtrip, timer IRQ,
external IRQ via INTC) already exist and pass in tb_rv32im_soc.sv and are
reused as-is for SOC-V1..SOC-V4; this script covers SOC-V7 (>=1000 randomized
SoC tests) and, via the varied peripheral mix, contributes to SOC-V3/SOC-V8.
"""
import sys, os, random
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "soc_asm"))
from asm import Asm

random.seed(20260921)

GPIO, TIMER, INTC, UART, SRAM = 0x40002000, 0x40000000, 0x40003000, 0x40001000, 0x10000000

# (upper20, offset, valid-bit-mask) - mask models exactly what the RTL stores
REGS = [
    (GPIO,  0x00, 0xFFFFFFFF),   # GPIO OUT
    (GPIO,  0x04, 0xFFFFFFFF),   # GPIO DIR
    (GPIO,  0x0C, 0xFFFFFFFF),   # GPIO IRQ_EN
    (TIMER, 0x10, 0xFFFFFFFF),   # MTIMECMP_LO
    (TIMER, 0x14, 0xFFFFFFFF),   # MTIMECMP_HI
    (TIMER, 0x00, 0x00000001),   # CTRL (only bit0 implemented)
    (INTC,  0x04, 0x000000FF),   # ENABLE (8 sources)
    (UART,  0x10, 0x0000FFFF),   # BAUD (16-bit divisor)
    (UART,  0x0C, 0x00000003),   # CTRL (TX_IRQ_EN, RX_IRQ_EN)
]

a = Asm()
n_tests = 1200

def store_slot(rs, word_idx, tmp=5):
    """SW rs -> SRAM[word_idx], reachable for ANY index: SW's immediate is only a signed
    12-bit byte offset (+-2047), so split the address LUI+offset style (the standard
    relocation technique) instead of assuming word_idx*4 fits."""
    addr  = SRAM + word_idx * 4
    upper = ((addr + 0x800) >> 12) & 0xFFFFF
    lower = addr - (upper << 12)            # always in [-2048, 2047]
    a.LUI(tmp, upper)
    a.SW(rs, tmp, lower)
expected = []

for i in range(n_tests):
    base, off, mask = random.choice(REGS)
    val = random.randint(0, 0xFFFFFFFF)
    exp = val & mask
    # compute `val` purely from two ADDI-sized halves (12-bit chunks) via LUI+ADDI so any
    # 32-bit pattern is reachable without relying on ORI's sign-extension pitfalls
    upper = (val >> 12) & 0xFFFFF
    lower = val & 0xFFF
    if lower & 0x800:             # ADDI sign-extends its 12-bit immediate; if this chunk would be
        upper = (upper + 1) & 0xFFFFF   # read as negative, compensate the upper 20 bits by +1
                                          # (the standard LUI+ADDI relocation technique - passing
                                          # `lower` (0..4095) straight to ADDI is already correct
                                          # once this compensation is applied, since ADDI's own
                                          # encoding just takes the low 12 bits verbatim).
    a.LUI(2, upper)
    a.ADDI(2, 2, lower)
    a.LI_ALIGNED(3, base)
    a.SW(2, 3, off)               # write
    a.LW(4, 3, off)               # read back
    store_slot(4, 300 + i)        # store the observed read-back to a unique SRAM slot
    expected.append(exp)

a.ADDI(7, 0, 1)
store_slot(7, 1600)           # dedicated DONE marker (independent of any test's actual value)
a.label("halt")
a.JAL(0, "halt")

out_dir = os.path.join(os.path.dirname(__file__), "..", "..", "sim")
os.makedirs(out_dir, exist_ok=True)
a.dump_hex(os.path.join(out_dir, "soc_stage6.hex"), pad_to=16384)
with open(os.path.join(out_dir, "soc_stage6_expect.hex"), "w") as f:
    for e in expected:
        f.write("%08x\n" % e)

print(f"assembled {len(a.words)} words, {n_tests} randomized SoC micro-tests")
