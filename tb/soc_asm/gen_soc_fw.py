#!/usr/bin/env python3
"""Assembles the SoC bring-up firmware used by tb_rv32im_soc.sv and writes
sim/soc_test.hex.  Exercises, through the REAL memory map and bus fabric
(core -> AXI4 -> interconnect -> peripherals, AXI-to-APB), in one program:
  Phase A: UART TX          (TB decodes the byte off the real uart_txd pin)
  Phase B: GPIO OUT/DIR      (TB reads gpio_o/gpio_oe pins directly)
  Phase C: GPIO IN           (TB drives gpio_i; firmware stores it to SRAM)
  Phase D: Timer -> MTIP     (real CSR/trap path, handler runs, MRET returns)
  Phase E: ext_irq -> INTC -> MEIP (INTC aggregation, second handler, MRET)
Register convention: x2=MMIO base, x3=value, x4=SRAM base, x6=CSR scratch.
SRAM markers (word offset from SRAM base):
  [0]=gpio_i as read by firmware   [1]=0x11 (timer handler ran)
  [2]=0x22 (ext handler ran)       [7]=1    (firmware reached the end)
"""
import sys, os
sys.path.insert(0, os.path.dirname(__file__))
from asm import Asm

UART_BASE, GPIO_BASE, TIMER_BASE, INTC_BASE, SRAM_BASE = \
    0x40001000, 0x40002000, 0x40000000, 0x40003000, 0x10000000

a = Asm()

# ---- Phase A: UART TX ------------------------------------------------------
a.LI_ALIGNED(2, UART_BASE)
a.ADDI(3, 0, 4)          # baud divisor (fast sim)
a.SW(3, 2, 0x10)         # BAUD
a.ADDI(3, 0, 0xA5)
a.SW(3, 2, 0x00)         # TXDATA <- 0xA5

# ---- Phase B: GPIO OUT / DIR -----------------------------------------------
a.LI_ALIGNED(2, GPIO_BASE)
a.ADDI(3, 0, 0xFF)
a.SW(3, 2, 0x04)         # DIR <- 0xFF (lower 8 bits output)
a.ADDI(3, 0, 0x5A)
a.SW(3, 2, 0x00)         # OUT <- 0x5A

# settle the 2-FF input synchroniser before reading IN
for _ in range(6):
    a.NOP()

# ---- Phase C: GPIO IN -> SRAM[0] -------------------------------------------
a.LW(3, 2, 0x08)         # x3 = GPIO IN  (x2 still == GPIO_BASE)
a.LI_ALIGNED(4, SRAM_BASE)
a.SW(3, 4, 0x00)         # SRAM[0] = sampled GPIO input

# ---- mtvec -> timer_handler -------------------------------------------------
a.ADDI(6, 0, 0)          # placeholder, patched below once the label exists
timer_mtvec_fixup = len(a.words) - 1
a.CSRRW(0, 6, 0x305)     # mtvec <- x6

# ---- enable timer, MTIMECMP a little ahead ---------------------------------
a.LI_ALIGNED(2, TIMER_BASE)
a.ADDI(3, 0, 1)
a.SW(3, 2, 0x00)         # CTRL <- 1 (start counting)
a.ADDI(3, 0, 80)
a.SW(3, 2, 0x10)         # MTIMECMP_LO <- 80
a.SW(0, 2, 0x14)         # MTIMECMP_HI <- 0

# ---- mie.MTIE, mstatus.MIE --------------------------------------------------
a.ADDI(3, 0, 128)        # bit7 = MTIE
a.CSRRW(0, 3, 0x304)
a.ADDI(3, 0, 8)          # bit3 = MIE
a.CSRRW(0, 3, 0x300)

for _ in range(100):     # spin waiting for the timer interrupt
    a.NOP()

# ---- Phase E: INTC source 2 (ext_irq[0]) -> MEIP ---------------------------
a.LI_ALIGNED(2, INTC_BASE)
a.ADDI(3, 0, 4)           # bit2 = source index 2
a.SW(3, 2, 0x04)          # ENABLE <- 0x4

a.ADDI(6, 0, 0)           # placeholder, patched below once the label exists
ext_mtvec_fixup = len(a.words) - 1
a.CSRRW(0, 6, 0x305)      # mtvec <- x6  (switch vector for phase E)

a.ADDI(3, 0, 1)
a.SLLI(3, 3, 11)          # x3 = 0x800 (MEIE, bit11 - out of ADDI's signed range)
a.CSRRW(0, 3, 0x304)      # mie <- 0x800  (mstatus.MIE already 1, restored by the first MRET)

for _ in range(100):      # spin waiting for the external interrupt
    a.NOP()

# ---- done marker + halt -----------------------------------------------------
a.LI_ALIGNED(4, SRAM_BASE)
a.ADDI(3, 0, 1)
a.SW(3, 4, 0x1C)          # SRAM[7] = 1  (DONE)
a.label("halt")
a.JAL(0, "halt")

# ---- timer trap handler -----------------------------------------------------
a.label("timer_handler")
a.LI_ALIGNED(4, SRAM_BASE)
a.ADDI(3, 0, 0x11)
a.SW(3, 4, 0x04)          # SRAM[1] = 0x11
a.LI_ALIGNED(2, TIMER_BASE)
a.SW(0, 2, 0x00)          # CTRL <- 0 (stop the timer so it can't re-fire)
a.CSRRS(6, 0, 0x341)      # x6 = mepc (pure read, rs1=x0)
a.ADDI(6, 6, 4)
a.CSRRW(0, 6, 0x341)      # mepc <- x6 + 4
a.MRET()

# ---- external-interrupt trap handler ----------------------------------------
a.label("ext_handler")
a.LI_ALIGNED(4, SRAM_BASE)
a.ADDI(3, 0, 0x22)
a.SW(3, 4, 0x08)          # SRAM[2] = 0x22
a.LI_ALIGNED(2, INTC_BASE)
a.SW(0, 2, 0x04)          # ENABLE <- 0 (stop further external interrupts)
a.CSRRS(6, 0, 0x341)
a.ADDI(6, 6, 4)
a.CSRRW(0, 6, 0x341)
a.MRET()

# ---- patch the two mtvec loads now that the handler addresses are known ----
a.words[timer_mtvec_fixup] = (0 << 20) | (0 << 15) | (0 << 12) | (6 << 7) | 0x13  # ADDI x6,x0,imm (placeholder op form)
th = a.labels["timer_handler"]
eh = a.labels["ext_handler"]
assert th < 2048 and eh < 2048, "handler offset exceeds ADDI's signed 12-bit immediate range"
def encode_addi(rd, rs1, imm):
    return ((imm & 0xFFF) << 20) | (rs1 << 15) | (0 << 12) | (rd << 7) | 0x13
a.words[timer_mtvec_fixup] = encode_addi(6, 0, th)
a.words[ext_mtvec_fixup]   = encode_addi(6, 0, eh)

out = os.path.join(os.path.dirname(__file__), "..", "..", "sim", "soc_test.hex")
os.makedirs(os.path.dirname(out), exist_ok=True)
a.dump_hex(out, pad_to=512)
print("assembled", len(a.words), "words; timer_handler @ word", th // 4, "ext_handler @ word", eh // 4)
print("wrote", out)
