#!/usr/bin/env python3
"""Tiny two-pass RV32I assembler, just enough to build the SoC bring-up firmware.
Not part of the RTL or of any existing testbench - purely a generator script that
emits sim/soc_test.hex (readmemh format) for tb_rv32im_soc.sv.
"""
import sys

OP_LUI, OP_JAL, OP_JALR, OP_BRANCH = 0x37, 0x6F, 0x67, 0x63
OP_LOAD, OP_STORE, OP_IMM, OP_REG, OP_FENCE, OP_SYSTEM = 0x03, 0x23, 0x13, 0x33, 0x0F, 0x73

def u(v, bits):
    return v & ((1 << bits) - 1)

class Asm:
    def __init__(self):
        self.words = []
        self.labels = {}
        self.fixups = []  # (word_index, kind, label)

    def here(self):
        return len(self.words) * 4

    def label(self, name):
        self.labels[name] = self.here()

    def emit(self, w):
        self.words.append(w & 0xFFFFFFFF)

    # ---- R/I-type ALU ----
    def ADDI(self, rd, rs1, imm):  self.emit((u(imm,12)<<20)|(rs1<<15)|(0<<12)|(rd<<7)|OP_IMM)
    def ORI(self, rd, rs1, imm):   self.emit((u(imm,12)<<20)|(rs1<<15)|(6<<12)|(rd<<7)|OP_IMM)
    def ANDI(self, rd, rs1, imm):  self.emit((u(imm,12)<<20)|(rs1<<15)|(7<<12)|(rd<<7)|OP_IMM)
    def SLLI(self, rd, rs1, shamt): self.emit((0<<25)|(u(shamt,5)<<20)|(rs1<<15)|(1<<12)|(rd<<7)|OP_IMM)
    def SRLI(self, rd, rs1, shamt): self.emit((0<<25)|(u(shamt,5)<<20)|(rs1<<15)|(5<<12)|(rd<<7)|OP_IMM)
    def SRAI(self, rd, rs1, shamt): self.emit((0x20<<25)|(u(shamt,5)<<20)|(rs1<<15)|(5<<12)|(rd<<7)|OP_IMM)
    def XORI(self, rd, rs1, imm):  self.emit((u(imm,12)<<20)|(rs1<<15)|(4<<12)|(rd<<7)|OP_IMM)
    def SLTI(self, rd, rs1, imm):  self.emit((u(imm,12)<<20)|(rs1<<15)|(2<<12)|(rd<<7)|OP_IMM)
    def SLTIU(self, rd, rs1, imm): self.emit((u(imm,12)<<20)|(rs1<<15)|(3<<12)|(rd<<7)|OP_IMM)
    def ADD(self, rd, rs1, rs2):   self.emit((0<<25)|(rs2<<20)|(rs1<<15)|(0<<12)|(rd<<7)|OP_REG)
    def SUB(self, rd, rs1, rs2):   self.emit((0x20<<25)|(rs2<<20)|(rs1<<15)|(0<<12)|(rd<<7)|OP_REG)
    def AND(self, rd, rs1, rs2):   self.emit((0<<25)|(rs2<<20)|(rs1<<15)|(7<<12)|(rd<<7)|OP_REG)
    def OR(self, rd, rs1, rs2):    self.emit((0<<25)|(rs2<<20)|(rs1<<15)|(6<<12)|(rd<<7)|OP_REG)
    def XOR(self, rd, rs1, rs2):   self.emit((0<<25)|(rs2<<20)|(rs1<<15)|(4<<12)|(rd<<7)|OP_REG)
    def SLT(self, rd, rs1, rs2):   self.emit((0<<25)|(rs2<<20)|(rs1<<15)|(2<<12)|(rd<<7)|OP_REG)
    def SLTU(self, rd, rs1, rs2):  self.emit((0<<25)|(rs2<<20)|(rs1<<15)|(3<<12)|(rd<<7)|OP_REG)
    def SLL(self, rd, rs1, rs2):   self.emit((0<<25)|(rs2<<20)|(rs1<<15)|(1<<12)|(rd<<7)|OP_REG)
    def SRL(self, rd, rs1, rs2):   self.emit((0<<25)|(rs2<<20)|(rs1<<15)|(5<<12)|(rd<<7)|OP_REG)
    def SRA(self, rd, rs1, rs2):   self.emit((0x20<<25)|(rs2<<20)|(rs1<<15)|(5<<12)|(rd<<7)|OP_REG)
    # ---- M extension ----
    def MUL(self, rd, rs1, rs2):    self.emit((1<<25)|(rs2<<20)|(rs1<<15)|(0<<12)|(rd<<7)|OP_REG)
    def MULH(self, rd, rs1, rs2):   self.emit((1<<25)|(rs2<<20)|(rs1<<15)|(1<<12)|(rd<<7)|OP_REG)
    def MULHSU(self, rd, rs1, rs2): self.emit((1<<25)|(rs2<<20)|(rs1<<15)|(2<<12)|(rd<<7)|OP_REG)
    def MULHU(self, rd, rs1, rs2):  self.emit((1<<25)|(rs2<<20)|(rs1<<15)|(3<<12)|(rd<<7)|OP_REG)
    def DIV(self, rd, rs1, rs2):    self.emit((1<<25)|(rs2<<20)|(rs1<<15)|(4<<12)|(rd<<7)|OP_REG)
    def DIVU(self, rd, rs1, rs2):   self.emit((1<<25)|(rs2<<20)|(rs1<<15)|(5<<12)|(rd<<7)|OP_REG)
    def REM(self, rd, rs1, rs2):    self.emit((1<<25)|(rs2<<20)|(rs1<<15)|(6<<12)|(rd<<7)|OP_REG)
    def REMU(self, rd, rs1, rs2):   self.emit((1<<25)|(rs2<<20)|(rs1<<15)|(7<<12)|(rd<<7)|OP_REG)
    def LUI(self, rd, imm20):      self.emit((u(imm20,20)<<12)|(rd<<7)|OP_LUI)
    def AUIPC(self, rd, imm20):    self.emit((u(imm20,20)<<12)|(rd<<7)|0x17)
    def NOP(self):                 self.ADDI(0,0,0)
    def LW(self, rd, rs1, imm):    self.emit((u(imm,12)<<20)|(rs1<<15)|(2<<12)|(rd<<7)|OP_LOAD)
    def LH(self, rd, rs1, imm):    self.emit((u(imm,12)<<20)|(rs1<<15)|(1<<12)|(rd<<7)|OP_LOAD)
    def LHU(self, rd, rs1, imm):   self.emit((u(imm,12)<<20)|(rs1<<15)|(5<<12)|(rd<<7)|OP_LOAD)
    def LB(self, rd, rs1, imm):    self.emit((u(imm,12)<<20)|(rs1<<15)|(0<<12)|(rd<<7)|OP_LOAD)
    def LBU(self, rd, rs1, imm):   self.emit((u(imm,12)<<20)|(rs1<<15)|(4<<12)|(rd<<7)|OP_LOAD)
    def JALR(self, rd, rs1, imm):  self.emit((u(imm,12)<<20)|(rs1<<15)|(0<<12)|(rd<<7)|OP_JALR)
    def SW(self, rs2, rs1, imm):
        imm = u(imm,12)
        self.emit(((imm>>5)<<25)|(rs2<<20)|(rs1<<15)|(2<<12)|((imm&0x1F)<<7)|OP_STORE)
    def SH(self, rs2, rs1, imm):
        imm = u(imm,12)
        self.emit(((imm>>5)<<25)|(rs2<<20)|(rs1<<15)|(1<<12)|((imm&0x1F)<<7)|OP_STORE)
    def SB(self, rs2, rs1, imm):
        imm = u(imm,12)
        self.emit(((imm>>5)<<25)|(rs2<<20)|(rs1<<15)|(0<<12)|((imm&0x1F)<<7)|OP_STORE)

    # ---- branches / jumps (label-based, resolved in pass 2) ----
    def BEQ(self, rs1, rs2, label):  self.fixups.append((len(self.words),'B',0,rs1,rs2,label)); self.emit(0)
    def BNE(self, rs1, rs2, label):  self.fixups.append((len(self.words),'B',1,rs1,rs2,label)); self.emit(0)
    def BLT(self, rs1, rs2, label):  self.fixups.append((len(self.words),'B',4,rs1,rs2,label)); self.emit(0)
    def BGE(self, rs1, rs2, label):  self.fixups.append((len(self.words),'B',5,rs1,rs2,label)); self.emit(0)
    def BLTU(self, rs1, rs2, label): self.fixups.append((len(self.words),'B',6,rs1,rs2,label)); self.emit(0)
    def BGEU(self, rs1, rs2, label): self.fixups.append((len(self.words),'B',7,rs1,rs2,label)); self.emit(0)
    def JAL(self, rd, label):        self.fixups.append((len(self.words),'J',rd,0,0,label)); self.emit(0)

    def _enc_B(self, f3, rs1, rs2, imm):
        imm = u(imm,13)
        b12=(imm>>12)&1; b11=(imm>>11)&1; b105=(imm>>5)&0x3F; b41=(imm>>1)&0xF
        return (b12<<31)|(b105<<25)|(rs2<<20)|(rs1<<15)|(f3<<12)|(b41<<8)|(b11<<7)|OP_BRANCH
    def _enc_J(self, rd, imm):
        imm = u(imm,21)
        b20=(imm>>20)&1; b101=(imm>>1)&0x3FF; b11=(imm>>11)&1; b1912=(imm>>12)&0xFF
        return (b20<<31)|(b101<<21)|(b11<<20)|(b1912<<12)|(rd<<7)|OP_JAL

    # ---- system ----
    def ECALL(self):  self.emit(0x00000073)
    def MRET(self):   self.emit(0x30200073)
    def FENCEI(self): self.emit(0x0000100F)
    def CSRRW(self, rd, rs1, csr): self.emit((csr<<20)|(rs1<<15)|(1<<12)|(rd<<7)|OP_SYSTEM)
    def CSRRS(self, rd, rs1, csr): self.emit((csr<<20)|(rs1<<15)|(2<<12)|(rd<<7)|OP_SYSTEM)

    # ---- pseudo: load a 32-bit constant with low12==0 (all our MMIO bases qualify) ----
    def LI_ALIGNED(self, rd, val32):
        assert (val32 & 0xFFF) == 0, hex(val32)
        self.LUI(rd, (val32 >> 12) & 0xFFFFF)

    def resolve(self):
        for idx,kind,rd_or_f3,rs1,rs2,label in self.fixups:
            target = self.labels[label]
            src = idx*4
            off = target - src
            if kind == 'B':
                self.words[idx] = self._enc_B(rd_or_f3, rs1, rs2, off)
            else:
                self.words[idx] = self._enc_J(rd_or_f3, off)

    def dump_hex(self, path, pad_to=512):
        self.resolve()
        with open(path,'w') as f:
            for i in range(pad_to):
                w = self.words[i] if i < len(self.words) else 0x00000013  # NOP fill
                f.write("%08x\n" % w)
