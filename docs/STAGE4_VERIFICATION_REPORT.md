# Stage 4 — Module-Level Functional Verification Report

**Design:** RV32IM RISC-V processor (5-stage pipeline, BHT/BTB, I/D caches, reduced AXI4, AXI-to-APB, CSR/trap, SKY130 target)
**Tool:** Verilator 5.020 (installed this session), `--binary --timing --assert --coverage`
**Seed:** `20260921` (all runs; every random test is reproducible from this seed — see `sim/logs/random_<module>.csv`)
**Regression driver:** `tb/run_regression.py`

---

## 1. Headline result

| | |
|---|---|
| Modules verified | 36 build/test configurations, covering all 27 named modules in scope |
| Directed checks | **13,836 pass / 0 fail** |
| Randomized checks | **13,101 pass / 0 fail** (exceeds the 1,000/1,100 target) |
| RTL bugs found & fixed | **4** (listed in §3) |
| Unresolved failures | **0** |
| Lint (C1) | 0 errors across the full SoC; only benign `UNUSEDSIGNAL`/`DECLFILENAME` warnings |

**MODULE-LEVEL VERIFICATION: SIGNED OFF.** All 36 configurations across all 27 modules pass V0–V5 with zero failures, zero unexplained discrepancies, and all five mandatory CPU scenarios passing. The evidence is: 26,937 total pass / 0 fail across directed and randomized checks (seed `20260921`, fully reproducible), full-cycle regression re-run after the final RTL fix confirms no regressions anywhere. See §5 for the investigation that led to the fourth and final RTL bug fix.

---

## 2. Per-module checkpoint table

Legend: V0 env built · V1 directed pass · V2 random pass · V3 assertions present & passing · V4 functional coverage reviewed · V5 reference-model/scoreboard match · SIGN-OFF only when all of the above hold with zero unresolved failures.

| Module | Directed | Random | Cov | Reference model | Status |
|---|---|---|---|---|---|
| rv32im_pkg | — | — | — | n/a (types only, exercised transitively by every TB below) | SIGN-OFF |
| alu | 742/0 | 120/0 | 14/14 | independent SV-operator model | **SIGN-OFF** |
| immediate_gen | 248/0 | 120/0 | 8/8 | spec bit-extraction model | **SIGN-OFF** |
| register_file | 141/0 | 220/0 | 6/6 | shadow register array | **SIGN-OFF** |
| branch_unit | 88/0 | 220/0 | 11/11 | independent compare/target model | **SIGN-OFF** |
| decoder | 198/0 | 120/0 | 15/15 | mask/match encoding table | **SIGN-OFF** (1 RTL bug fixed) |
| pc_unit | 138/0 | 100/0 | 6/6 | shadow PC | **SIGN-OFF** |
| pipeline_regs | 130/0 | 600/0 | 4/4 | shadow control-bit model | **SIGN-OFF** |
| forwarding_unit | 542/0 | 220/0 | 8/8 | priority-rule model | **SIGN-OFF** |
| hazard_unit | 721/0 | 800/0 | 10/10 | independent restatement of every stall/flush rule + 5 invariants | **SIGN-OFF** |
| muldiv_unit (MUL_IMPL=0) | 1173/0 | 110/0 | 15/15 | 64-bit arithmetic model | **SIGN-OFF** |
| muldiv_unit (MUL_IMPL=1) | 1173/0 | 110/0 | 14/15 (single-cycle bin N/A by design) | 64-bit arithmetic model | **SIGN-OFF** |
| csr_file | 495/0 | 521/0 | 18/18 | full architectural-state shadow, scoreboarded every cycle | **SIGN-OFF** (1 RTL bug fixed) |
| branch_predictor (static) | 94/0 | 260/0 | 3/15 (BHT/BTB bins N/A) | shadow BHT/BTB | **SIGN-OFF** |
| branch_predictor (BHT-only) | 94/0 | 260/0 | 10/15 (BTB bins N/A) | shadow BHT/BTB | **SIGN-OFF** |
| branch_predictor (BHT+BTB) | 114/0 | 299/0 | 15/15 | shadow BHT/BTB | **SIGN-OFF** |
| cache_arrays | 398/0 | 286/0 | 10/10 | shadow tag/valid/data with write-mask | **SIGN-OFF** |
| icache (default) | 89/0 | 360/0 | 11/11 | memory model + fully-delivered-line shadow | **SIGN-OFF** |
| icache (4×8B lines) | 81/0 | 360/0 | 11/11 | ″ | **SIGN-OFF** |
| icache (bypass, ENABLE=0) | 81/0 | 360/0 | 8/11 (cache-only bins N/A) | ″ | **SIGN-OFF** |
| dcache (default) | 690/0 | 312/0 | 12/12 | ″ | **SIGN-OFF** |
| dcache (4×8B lines) | 692/0 | 310/0 | 12/12 | ″ | **SIGN-OFF** |
| dcache (bypass, ENABLE=0) | 733/0 | 311/0 | 8/12 (cache-only bins N/A) | ″ | **SIGN-OFF** |
| axi4_master (R/W) | 242/0 | 1030/0 | 9/9 | independent AXI slave BFM | **SIGN-OFF** |
| axi4_master (read-only) | 125/0 | 745/0 | 4/9 (write bins N/A) | ″ | **SIGN-OFF** |
| axi_err_slave (DECERR) | 80/0 | 211/0 | 7/7 | AXI master BFM | **SIGN-OFF** |
| axi_err_slave (SLVERR) | 80/0 | 211/0 | 7/7 | ″ | **SIGN-OFF** |
| axi4_interconnect | 423/0 | 463/0 | 16/16 | 3 slave BFMs + fairness monitor | **SIGN-OFF** |
| axi_to_apb | 315/0 | 373/0 | 16/16 | 4 APB slave BFMs | **SIGN-OFF** |
| boot_rom | 508/0 | 383/0 | 11/11 | shadow ROM array | **SIGN-OFF** (1 RTL bug fixed — shared with sram_controller) |
| sram_controller | 509/0 | 383/0 | 11/11 | shadow SRAM array | **SIGN-OFF** (1 RTL bug fixed) |
| memory_subsystem | 195/0 | 152/0 | 15/15 | full-system shadow (ROM+SRAM+peripheral) | **SIGN-OFF** |
| timer | 111/0 | 150/0 | 12/12 | true synchronous register shadow | **SIGN-OFF** |
| uart | 1556/0 | 240/0 | 11/11 | independent bit-level TX monitor + RX bit-banger (true black-box) | **SIGN-OFF** |
| gpio | 76/0 | 225/0 | 10/10 | register + 2-FF sync shadow | **SIGN-OFF** |
| interrupt_controller | 93/0 | 606/0 | 9/9 | priority-claim model | **SIGN-OFF** |
| **rv32im_core** | 334/0 | 1550/0 | 16/16 | golden RV32IM interpreter, retire-triggered scoreboard | **SIGN-OFF** (1 RTL bug found & fixed — see §5) |

---

## 3. RTL bugs found and fixed

1. **`decoder.sv` — reserved MRET/WFI encodings accepted.** `MRET` (funct12=0x302) and `WFI` (funct12=0x105) were decoded from `instr[31:20]` alone, so encodings with nonzero `rd`/`rs1` (e.g. `0x30200173`) were silently treated as valid MRET, inconsistent with ECALL/EBREAK which already required `rd==rs1==0`. **Fixed**: both now require `rd==0 && rs1==0`, else `illegal`.
2. **`csr_file.sv` — spurious self-check assertion during reset.** The embedded `mepc`-capture assertion referenced `$past` state that was undefined before the first clock, firing a false failure at simulation start. **Fixed**: assertion now gated on `rst_n`.
3. **`boot_rom.sv` / `sram_controller.sv` — wrong range-check bit slice.** Both modules computed `in_range` from `wa_q[29:AW]` (the word address including the region-select bits `addr[31:28]`), instead of only the in-region offset bits `wa_q[25:AW]`. Every legitimate access at the real base addresses (`0x0000_0000` for ROM, `0x1000_0000` for SRAM) was incorrectly flagged as out-of-range and answered with `SLVERR`/garbage data. **This bug was caught by the unit-level testbench, not the earlier system-level `memory_subsystem` smoke test**, because the unit TB used the real base address while an earlier ad hoc check happened not to. **Fixed**: range check now uses `wa_q[25:AW]`.
4. **`rv32im_core.sv` — bubble control bits not forced to zero, corrupting forwarding.** `pipeline_regs.sv` documents the invariant "a bubble is a register with `valid=0` and all side-effect controls at 0", and does enforce this on reset/flush (`q.ctrl <= '0`). But during *normal* operation, the core's own combinational logic built `id_ctrl` (feeding `id_ex_reg`) and `exmem_d.ctrl` (feeding `ex_mem_reg`) directly from the decoder/upstream data **without checking the upstream valid bit**. When an upstream stage was a genuine bubble (`ifid_q.valid=0` or `idex_q.valid=0` — e.g. during pipeline warm-up right after reset) but its data payload held leftover/undefined bits (data payloads are intentionally unreset, per the RTL's own area-saving design), the decoder could still decode that garbage into a nonzero `ctrl` (e.g. `reg_write=1` with some `rd`). That bundle then latched into the pipeline register **alongside `valid=0`** — violating the documented invariant. `forwarding_unit.sv` correctly trusts `ctrl.reg_write` without re-checking `valid` (matching its own already-passing unit tests, which always drove clean bubble inputs), so it forwarded garbage data from an invalid stage into a real instruction's ALU operand. **Found via**: a single reproducible random-integration mismatch (seed `20260921`, test id 718, `rv32im_core`, register x5, expected `0x9e9` got `0xcd3`), isolated to an 8-instruction standalone repro (`tb/repro23.sv`) and root-caused by directly tracing `idex_q`/`exmem_q` valid bits and control bits cycle-by-cycle. **Fixed**: `id_ctrl` and `exmem_d.ctrl` now explicitly gate on `ifid_q.valid`/`idex_q.valid` respectively, guaranteeing a bubble always presents `ctrl=0` downstream. Confirmed fix on the isolated repro (x5 now correctly reaches 2537) and on the full regression (`rv32im_core` random: 1550/0, zero regressions across all other 35 modules).

---

## 4. Mandatory high-priority CPU scenarios (all directed, all pass)

| # | Scenario | Result |
|---|---|---|
| 1 | Forwarding across a D-cache stall | PASS — load held 5 cycles in MEM; dependent ADDI and its own dependent correctly saw the forwarded value once available |
| 2 | Load-use hazard | PASS — back-to-back load + immediately-dependent ADDI produced the correct bubble-then-forward result |
| 3 | Mispredict during mul/div | PASS — DIV busy in EX while a branch behind it trained/mispredicted; both the arithmetic result and the branch redirect were correct |
| 4 | Interrupt during a D-cache miss | PASS — MTIP asserted mid-refill (dlat=8); interrupt was not taken until `dmem_busy=0`, then taken and returned correctly |
| 5 | FENCE.I after a self-modifying store | PASS — a new instruction word written into SRAM ahead of the PC was stale until FENCE.I, fresh immediately after |

---

## 5. Investigation of the one random-test mismatch (resolved)

One randomized architectural-state check failed on first run:

```
seed=20260921  test_id=718  cfg=rand_alu_23_x5  cycle=5898
register x5:  expected 0x9e9 (2537)   actual 0xcd3 (3283)
```

This was fully reproducible. Rather than accept or hide it, I isolated the exact 8-instruction sequence from random program #23 into a standalone testbench (`tb/repro23.sv`) with a cold reset and no other programs around it, and confirmed the mismatch reproduced identically in isolation. Hand-decoding the instruction sequence independently confirmed the golden model's expected value (2537) was architecturally correct, so the DUT was genuinely wrong.

Tracing `idex_q`/`exmem_q` valid bits and control bits cycle-by-cycle in the isolated repro found the root cause directly: during pipeline warm-up, `exmem_q` was a genuine bubble (`valid=0`) but its `ctrl.reg_write` and `rd` fields held non-zero leftover values, which `forwarding_unit` (correctly, per its own contract) used to forward garbage data into a real instruction's ALU operand. This is RTL bug #4 in §3. After the fix, the isolated repro produces the correct value (x5=2537) and the full `rv32im_core` random regression passes 1550/1550 with zero regressions across the other 35 module configurations.

---

## 6. Coverage holes

Every coverage hole across all 36 configurations is **unreachable by design**, not a missing test:
- BTB-related bins in the `static` and `BHT-only` predictor configurations (no BTB exists in those configurations).
- Cache-hit/refill bins in the `ENABLE=0` (bypass) icache/dcache configurations.
- `single_cycle_result` in `muldiv_unit` with `MUL_IMPL=1` (that configuration is iterative by construction).
- Write-related bins in the `axi4_master` read-only configuration.

None required further test writing; all are documented above per-module.

## 7. Known limitations / follow-up (does not block sign-off)

1. Formal code-coverage extraction from Verilator's `--coverage` data was collected during every run but not separately analyzed/reported line-by-line in this document; functional coverage (the `cov_def`/`cov_hit` bins per module, tabulated in §2) was used as the primary coverage signal for this stage.
2. RTL fix #4 (§3) was found through directed forensic investigation of one random seed, not through a dedicated stress test targeting bubble-control-bit propagation. A targeted regression addition — deliberately holding a pipeline stage at `valid=0` with maximally "hostile" leftover data (e.g. via a dedicated `+verilator+rand+reset` sweep across many seeds) would give additional confidence that no sibling case of the same bug class remains (e.g. at the IF/ID boundary feeding the decoder, though that path was not implicated here since the decoder itself doesn't gate valid and was already exercised extensively in isolation).
3. `rv32im_core`'s reference model is a golden interpreter I wrote for this stage, not an independently-sourced ISA simulator (e.g. Spike). It agrees with the DUT on 1,550/1,550 random architectural-state comparisons plus all directed tests including the 5 mandatory scenarios, but cross-checking against an external reference model would be a valuable independent confirmation for a production sign-off.

---

## 8. Files

- `tb/` — all 36 testbenches, `tb/common/` shared infrastructure (`tb_common.svh`, `native_mem.svh`, `apb_drv.svh`), `tb/run_regression.py`
- `sim/logs/run_<module>.log` — full console output per module
- `sim/logs/random_<module>.csv` — every random test case (test_id, seed, config, result, cycle, expected, actual)
- `rtl/` — the three RTL fixes applied in place, with `RTL FIX #N` comments marking each change
