# Stage 4 Verification Checkpoint Record
Seed: 20260921. All checkpoints below reflect the FINAL regression run after all RTL fixes.

```
Module: alu
RTL file: rtl/core/alu.sv
V0: PASS (testbench + reference model built)
V1: PASS (directed tests: 742 pass, 0 fail)
V2: PASS (randomized tests: 120 pass, 0 fail)
V3: PASS (assertions present and passing, 0 failures)
V4: PASS (functional coverage reviewed: 14/14 bins hit; any gap is unreachable by design, documented in report)
V5: PASS (reference model / scoreboard comparison passes)
V-SIGNOFF: PASS
Directed tests: 742
Random tests: 120
Seeds: 20260921
Assertions: passing, 0 failures
Coverage: 14/14
Reference model: yes (see STAGE4_VERIFICATION_REPORT.md section 2)
Known failures: none
Open bugs: none
Final status: SIGN-OFF
```

```
Module: immediate_gen
RTL file: rtl/core/immediate_gen.sv
V0: PASS (testbench + reference model built)
V1: PASS (directed tests: 248 pass, 0 fail)
V2: PASS (randomized tests: 120 pass, 0 fail)
V3: PASS (assertions present and passing, 0 failures)
V4: PASS (functional coverage reviewed: 8/8 bins hit; any gap is unreachable by design, documented in report)
V5: PASS (reference model / scoreboard comparison passes)
V-SIGNOFF: PASS
Directed tests: 248
Random tests: 120
Seeds: 20260921
Assertions: passing, 0 failures
Coverage: 8/8
Reference model: yes (see STAGE4_VERIFICATION_REPORT.md section 2)
Known failures: none
Open bugs: none
Final status: SIGN-OFF
```

```
Module: register_file
RTL file: rtl/core/register_file.sv
V0: PASS (testbench + reference model built)
V1: PASS (directed tests: 141 pass, 0 fail)
V2: PASS (randomized tests: 220 pass, 0 fail)
V3: PASS (assertions present and passing, 0 failures)
V4: PASS (functional coverage reviewed: 6/6 bins hit; any gap is unreachable by design, documented in report)
V5: PASS (reference model / scoreboard comparison passes)
V-SIGNOFF: PASS
Directed tests: 141
Random tests: 220
Seeds: 20260921
Assertions: passing, 0 failures
Coverage: 6/6
Reference model: yes (see STAGE4_VERIFICATION_REPORT.md section 2)
Known failures: none
Open bugs: none
Final status: SIGN-OFF
```

```
Module: branch_unit
RTL file: rtl/core/branch_unit.sv
V0: PASS (testbench + reference model built)
V1: PASS (directed tests: 88 pass, 0 fail)
V2: PASS (randomized tests: 220 pass, 0 fail)
V3: PASS (assertions present and passing, 0 failures)
V4: PASS (functional coverage reviewed: 11/11 bins hit; any gap is unreachable by design, documented in report)
V5: PASS (reference model / scoreboard comparison passes)
V-SIGNOFF: PASS
Directed tests: 88
Random tests: 220
Seeds: 20260921
Assertions: passing, 0 failures
Coverage: 11/11
Reference model: yes (see STAGE4_VERIFICATION_REPORT.md section 2)
Known failures: none
Open bugs: none
Final status: SIGN-OFF
```

```
Module: decoder
RTL file: rtl/core/decoder.sv
V0: PASS (testbench + reference model built)
V1: PASS (directed tests: 198 pass, 0 fail)
V2: PASS (randomized tests: 120 pass, 0 fail)
V3: PASS (assertions present and passing, 0 failures)
V4: PASS (functional coverage reviewed: 15/15 bins hit; any gap is unreachable by design, documented in report)
V5: PASS (reference model / scoreboard comparison passes)
V-SIGNOFF: PASS
Directed tests: 198
Random tests: 120
Seeds: 20260921
Assertions: passing, 0 failures
Coverage: 15/15
Reference model: yes (see STAGE4_VERIFICATION_REPORT.md section 2)
Known failures: none
Open bugs: none
Final status: SIGN-OFF
```

```
Module: pc_unit
RTL file: rtl/core/pc_unit.sv
V0: PASS (testbench + reference model built)
V1: PASS (directed tests: 138 pass, 0 fail)
V2: PASS (randomized tests: 100 pass, 0 fail)
V3: PASS (assertions present and passing, 0 failures)
V4: PASS (functional coverage reviewed: 6/6 bins hit; any gap is unreachable by design, documented in report)
V5: PASS (reference model / scoreboard comparison passes)
V-SIGNOFF: PASS
Directed tests: 138
Random tests: 100
Seeds: 20260921
Assertions: passing, 0 failures
Coverage: 6/6
Reference model: yes (see STAGE4_VERIFICATION_REPORT.md section 2)
Known failures: none
Open bugs: none
Final status: SIGN-OFF
```

```
Module: pipeline_regs
RTL file: rtl/core/pipeline_regs.sv
V0: PASS (testbench + reference model built)
V1: PASS (directed tests: 130 pass, 0 fail)
V2: PASS (randomized tests: 600 pass, 0 fail)
V3: PASS (assertions present and passing, 0 failures)
V4: PASS (functional coverage reviewed: 4/4 bins hit; any gap is unreachable by design, documented in report)
V5: PASS (reference model / scoreboard comparison passes)
V-SIGNOFF: PASS
Directed tests: 130
Random tests: 600
Seeds: 20260921
Assertions: passing, 0 failures
Coverage: 4/4
Reference model: yes (see STAGE4_VERIFICATION_REPORT.md section 2)
Known failures: none
Open bugs: none
Final status: SIGN-OFF
```

```
Module: forwarding_unit
RTL file: rtl/core/forwarding_unit.sv
V0: PASS (testbench + reference model built)
V1: PASS (directed tests: 542 pass, 0 fail)
V2: PASS (randomized tests: 220 pass, 0 fail)
V3: PASS (assertions present and passing, 0 failures)
V4: PASS (functional coverage reviewed: 8/8 bins hit; any gap is unreachable by design, documented in report)
V5: PASS (reference model / scoreboard comparison passes)
V-SIGNOFF: PASS
Directed tests: 542
Random tests: 220
Seeds: 20260921
Assertions: passing, 0 failures
Coverage: 8/8
Reference model: yes (see STAGE4_VERIFICATION_REPORT.md section 2)
Known failures: none
Open bugs: none
Final status: SIGN-OFF
```

```
Module: hazard_unit
RTL file: rtl/core/hazard_unit.sv
V0: PASS (testbench + reference model built)
V1: PASS (directed tests: 721 pass, 0 fail)
V2: PASS (randomized tests: 800 pass, 0 fail)
V3: PASS (assertions present and passing, 0 failures)
V4: PASS (functional coverage reviewed: 10/10 bins hit; any gap is unreachable by design, documented in report)
V5: PASS (reference model / scoreboard comparison passes)
V-SIGNOFF: PASS
Directed tests: 721
Random tests: 800
Seeds: 20260921
Assertions: passing, 0 failures
Coverage: 10/10
Reference model: yes (see STAGE4_VERIFICATION_REPORT.md section 2)
Known failures: none
Open bugs: none
Final status: SIGN-OFF
```

```
Module: muldiv_unit (MUL_IMPL=0)
RTL file: rtl/core/muldiv_unit.sv
V0: PASS (testbench + reference model built)
V1: PASS (directed tests: 1173 pass, 0 fail)
V2: PASS (randomized tests: 110 pass, 0 fail)
V3: PASS (assertions present and passing, 0 failures)
V4: PASS (functional coverage reviewed: 15/15 bins hit; any gap is unreachable by design, documented in report)
V5: PASS (reference model / scoreboard comparison passes)
V-SIGNOFF: PASS
Directed tests: 1173
Random tests: 110
Seeds: 20260921
Assertions: passing, 0 failures
Coverage: 15/15
Reference model: yes (see STAGE4_VERIFICATION_REPORT.md section 2)
Known failures: none
Open bugs: none
Final status: SIGN-OFF
```

```
Module: muldiv_unit (MUL_IMPL=1)
RTL file: rtl/core/muldiv_unit.sv
V0: PASS (testbench + reference model built)
V1: PASS (directed tests: 1173 pass, 0 fail)
V2: PASS (randomized tests: 110 pass, 0 fail)
V3: PASS (assertions present and passing, 0 failures)
V4: PASS (functional coverage reviewed: 14/15 bins hit; any gap is unreachable by design, documented in report)
V5: PASS (reference model / scoreboard comparison passes)
V-SIGNOFF: PASS
Directed tests: 1173
Random tests: 110
Seeds: 20260921
Assertions: passing, 0 failures
Coverage: 14/15
Reference model: yes (see STAGE4_VERIFICATION_REPORT.md section 2)
Known failures: none
Open bugs: none
Final status: SIGN-OFF
```

```
Module: csr_file
RTL file: rtl/core/csr_file.sv
V0: PASS (testbench + reference model built)
V1: PASS (directed tests: 495 pass, 0 fail)
V2: PASS (randomized tests: 521 pass, 0 fail)
V3: PASS (assertions present and passing, 0 failures)
V4: PASS (functional coverage reviewed: 18/18 bins hit; any gap is unreachable by design, documented in report)
V5: PASS (reference model / scoreboard comparison passes)
V-SIGNOFF: PASS
Directed tests: 495
Random tests: 521
Seeds: 20260921
Assertions: passing, 0 failures
Coverage: 18/18
Reference model: yes (see STAGE4_VERIFICATION_REPORT.md section 2)
Known failures: none
Open bugs: none
Final status: SIGN-OFF
```

```
Module: branch_predictor (static)
RTL file: rtl/core/branch_predictor.sv
V0: PASS (testbench + reference model built)
V1: PASS (directed tests: 94 pass, 0 fail)
V2: PASS (randomized tests: 260 pass, 0 fail)
V3: PASS (assertions present and passing, 0 failures)
V4: PASS (functional coverage reviewed: 3/15 bins hit; any gap is unreachable by design, documented in report)
V5: PASS (reference model / scoreboard comparison passes)
V-SIGNOFF: PASS
Directed tests: 94
Random tests: 260
Seeds: 20260921
Assertions: passing, 0 failures
Coverage: 3/15
Reference model: yes (see STAGE4_VERIFICATION_REPORT.md section 2)
Known failures: none
Open bugs: none
Final status: SIGN-OFF
```

```
Module: branch_predictor (BHT)
RTL file: rtl/core/branch_predictor.sv
V0: PASS (testbench + reference model built)
V1: PASS (directed tests: 94 pass, 0 fail)
V2: PASS (randomized tests: 260 pass, 0 fail)
V3: PASS (assertions present and passing, 0 failures)
V4: PASS (functional coverage reviewed: 10/15 bins hit; any gap is unreachable by design, documented in report)
V5: PASS (reference model / scoreboard comparison passes)
V-SIGNOFF: PASS
Directed tests: 94
Random tests: 260
Seeds: 20260921
Assertions: passing, 0 failures
Coverage: 10/15
Reference model: yes (see STAGE4_VERIFICATION_REPORT.md section 2)
Known failures: none
Open bugs: none
Final status: SIGN-OFF
```

```
Module: branch_predictor (BHT+BTB)
RTL file: rtl/core/branch_predictor.sv
V0: PASS (testbench + reference model built)
V1: PASS (directed tests: 114 pass, 0 fail)
V2: PASS (randomized tests: 299 pass, 0 fail)
V3: PASS (assertions present and passing, 0 failures)
V4: PASS (functional coverage reviewed: 15/15 bins hit; any gap is unreachable by design, documented in report)
V5: PASS (reference model / scoreboard comparison passes)
V-SIGNOFF: PASS
Directed tests: 114
Random tests: 299
Seeds: 20260921
Assertions: passing, 0 failures
Coverage: 15/15
Reference model: yes (see STAGE4_VERIFICATION_REPORT.md section 2)
Known failures: none
Open bugs: none
Final status: SIGN-OFF
```

```
Module: cache_arrays
RTL file: rtl/cache/cache_arrays.sv
V0: PASS (testbench + reference model built)
V1: PASS (directed tests: 398 pass, 0 fail)
V2: PASS (randomized tests: 286 pass, 0 fail)
V3: PASS (assertions present and passing, 0 failures)
V4: PASS (functional coverage reviewed: 10/10 bins hit; any gap is unreachable by design, documented in report)
V5: PASS (reference model / scoreboard comparison passes)
V-SIGNOFF: PASS
Directed tests: 398
Random tests: 286
Seeds: 20260921
Assertions: passing, 0 failures
Coverage: 10/10
Reference model: yes (see STAGE4_VERIFICATION_REPORT.md section 2)
Known failures: none
Open bugs: none
Final status: SIGN-OFF
```

```
Module: icache (default)
RTL file: rtl/cache/icache.sv
V0: PASS (testbench + reference model built)
V1: PASS (directed tests: 89 pass, 0 fail)
V2: PASS (randomized tests: 360 pass, 0 fail)
V3: PASS (assertions present and passing, 0 failures)
V4: PASS (functional coverage reviewed: 11/11 bins hit; any gap is unreachable by design, documented in report)
V5: PASS (reference model / scoreboard comparison passes)
V-SIGNOFF: PASS
Directed tests: 89
Random tests: 360
Seeds: 20260921
Assertions: passing, 0 failures
Coverage: 11/11
Reference model: yes (see STAGE4_VERIFICATION_REPORT.md section 2)
Known failures: none
Open bugs: none
Final status: SIGN-OFF
```

```
Module: icache (4x8B)
RTL file: rtl/cache/icache.sv
V0: PASS (testbench + reference model built)
V1: PASS (directed tests: 81 pass, 0 fail)
V2: PASS (randomized tests: 360 pass, 0 fail)
V3: PASS (assertions present and passing, 0 failures)
V4: PASS (functional coverage reviewed: 11/11 bins hit; any gap is unreachable by design, documented in report)
V5: PASS (reference model / scoreboard comparison passes)
V-SIGNOFF: PASS
Directed tests: 81
Random tests: 360
Seeds: 20260921
Assertions: passing, 0 failures
Coverage: 11/11
Reference model: yes (see STAGE4_VERIFICATION_REPORT.md section 2)
Known failures: none
Open bugs: none
Final status: SIGN-OFF
```

```
Module: icache (bypass)
RTL file: rtl/cache/icache.sv
V0: PASS (testbench + reference model built)
V1: PASS (directed tests: 81 pass, 0 fail)
V2: PASS (randomized tests: 360 pass, 0 fail)
V3: PASS (assertions present and passing, 0 failures)
V4: PASS (functional coverage reviewed: 8/11 bins hit; any gap is unreachable by design, documented in report)
V5: PASS (reference model / scoreboard comparison passes)
V-SIGNOFF: PASS
Directed tests: 81
Random tests: 360
Seeds: 20260921
Assertions: passing, 0 failures
Coverage: 8/11
Reference model: yes (see STAGE4_VERIFICATION_REPORT.md section 2)
Known failures: none
Open bugs: none
Final status: SIGN-OFF
```

```
Module: dcache (default)
RTL file: rtl/cache/dcache.sv
V0: PASS (testbench + reference model built)
V1: PASS (directed tests: 690 pass, 0 fail)
V2: PASS (randomized tests: 312 pass, 0 fail)
V3: PASS (assertions present and passing, 0 failures)
V4: PASS (functional coverage reviewed: 12/12 bins hit; any gap is unreachable by design, documented in report)
V5: PASS (reference model / scoreboard comparison passes)
V-SIGNOFF: PASS
Directed tests: 690
Random tests: 312
Seeds: 20260921
Assertions: passing, 0 failures
Coverage: 12/12
Reference model: yes (see STAGE4_VERIFICATION_REPORT.md section 2)
Known failures: none
Open bugs: none
Final status: SIGN-OFF
```

```
Module: dcache (4x8B)
RTL file: rtl/cache/dcache.sv
V0: PASS (testbench + reference model built)
V1: PASS (directed tests: 692 pass, 0 fail)
V2: PASS (randomized tests: 310 pass, 0 fail)
V3: PASS (assertions present and passing, 0 failures)
V4: PASS (functional coverage reviewed: 12/12 bins hit; any gap is unreachable by design, documented in report)
V5: PASS (reference model / scoreboard comparison passes)
V-SIGNOFF: PASS
Directed tests: 692
Random tests: 310
Seeds: 20260921
Assertions: passing, 0 failures
Coverage: 12/12
Reference model: yes (see STAGE4_VERIFICATION_REPORT.md section 2)
Known failures: none
Open bugs: none
Final status: SIGN-OFF
```

```
Module: dcache (bypass)
RTL file: rtl/cache/dcache.sv
V0: PASS (testbench + reference model built)
V1: PASS (directed tests: 733 pass, 0 fail)
V2: PASS (randomized tests: 311 pass, 0 fail)
V3: PASS (assertions present and passing, 0 failures)
V4: PASS (functional coverage reviewed: 8/12 bins hit; any gap is unreachable by design, documented in report)
V5: PASS (reference model / scoreboard comparison passes)
V-SIGNOFF: PASS
Directed tests: 733
Random tests: 311
Seeds: 20260921
Assertions: passing, 0 failures
Coverage: 8/12
Reference model: yes (see STAGE4_VERIFICATION_REPORT.md section 2)
Known failures: none
Open bugs: none
Final status: SIGN-OFF
```

```
Module: axi4_master (R/W)
RTL file: rtl/bus/axi4_master.sv
V0: PASS (testbench + reference model built)
V1: PASS (directed tests: 242 pass, 0 fail)
V2: PASS (randomized tests: 1030 pass, 0 fail)
V3: PASS (assertions present and passing, 0 failures)
V4: PASS (functional coverage reviewed: 9/9 bins hit; any gap is unreachable by design, documented in report)
V5: PASS (reference model / scoreboard comparison passes)
V-SIGNOFF: PASS
Directed tests: 242
Random tests: 1030
Seeds: 20260921
Assertions: passing, 0 failures
Coverage: 9/9
Reference model: yes (see STAGE4_VERIFICATION_REPORT.md section 2)
Known failures: none
Open bugs: none
Final status: SIGN-OFF
```

```
Module: axi4_master (RO)
RTL file: rtl/bus/axi4_master.sv
V0: PASS (testbench + reference model built)
V1: PASS (directed tests: 125 pass, 0 fail)
V2: PASS (randomized tests: 745 pass, 0 fail)
V3: PASS (assertions present and passing, 0 failures)
V4: PASS (functional coverage reviewed: 4/9 bins hit; any gap is unreachable by design, documented in report)
V5: PASS (reference model / scoreboard comparison passes)
V-SIGNOFF: PASS
Directed tests: 125
Random tests: 745
Seeds: 20260921
Assertions: passing, 0 failures
Coverage: 4/9
Reference model: yes (see STAGE4_VERIFICATION_REPORT.md section 2)
Known failures: none
Open bugs: none
Final status: SIGN-OFF
```

```
Module: axi_err_slave (DECERR)
RTL file: rtl/bus/axi4_interconnect.sv
V0: PASS (testbench + reference model built)
V1: PASS (directed tests: 80 pass, 0 fail)
V2: PASS (randomized tests: 211 pass, 0 fail)
V3: PASS (assertions present and passing, 0 failures)
V4: PASS (functional coverage reviewed: 7/7 bins hit; any gap is unreachable by design, documented in report)
V5: PASS (reference model / scoreboard comparison passes)
V-SIGNOFF: PASS
Directed tests: 80
Random tests: 211
Seeds: 20260921
Assertions: passing, 0 failures
Coverage: 7/7
Reference model: yes (see STAGE4_VERIFICATION_REPORT.md section 2)
Known failures: none
Open bugs: none
Final status: SIGN-OFF
```

```
Module: axi_err_slave (SLVERR)
RTL file: rtl/bus/axi4_interconnect.sv
V0: PASS (testbench + reference model built)
V1: PASS (directed tests: 80 pass, 0 fail)
V2: PASS (randomized tests: 211 pass, 0 fail)
V3: PASS (assertions present and passing, 0 failures)
V4: PASS (functional coverage reviewed: 7/7 bins hit; any gap is unreachable by design, documented in report)
V5: PASS (reference model / scoreboard comparison passes)
V-SIGNOFF: PASS
Directed tests: 80
Random tests: 211
Seeds: 20260921
Assertions: passing, 0 failures
Coverage: 7/7
Reference model: yes (see STAGE4_VERIFICATION_REPORT.md section 2)
Known failures: none
Open bugs: none
Final status: SIGN-OFF
```

```
Module: axi4_interconnect
RTL file: rtl/bus/axi4_interconnect.sv
V0: PASS (testbench + reference model built)
V1: PASS (directed tests: 423 pass, 0 fail)
V2: PASS (randomized tests: 463 pass, 0 fail)
V3: PASS (assertions present and passing, 0 failures)
V4: PASS (functional coverage reviewed: 16/16 bins hit; any gap is unreachable by design, documented in report)
V5: PASS (reference model / scoreboard comparison passes)
V-SIGNOFF: PASS
Directed tests: 423
Random tests: 463
Seeds: 20260921
Assertions: passing, 0 failures
Coverage: 16/16
Reference model: yes (see STAGE4_VERIFICATION_REPORT.md section 2)
Known failures: none
Open bugs: none
Final status: SIGN-OFF
```

```
Module: axi_to_apb
RTL file: rtl/bus/axi_to_apb.sv
V0: PASS (testbench + reference model built)
V1: PASS (directed tests: 315 pass, 0 fail)
V2: PASS (randomized tests: 373 pass, 0 fail)
V3: PASS (assertions present and passing, 0 failures)
V4: PASS (functional coverage reviewed: 16/16 bins hit; any gap is unreachable by design, documented in report)
V5: PASS (reference model / scoreboard comparison passes)
V-SIGNOFF: PASS
Directed tests: 315
Random tests: 373
Seeds: 20260921
Assertions: passing, 0 failures
Coverage: 16/16
Reference model: yes (see STAGE4_VERIFICATION_REPORT.md section 2)
Known failures: none
Open bugs: none
Final status: SIGN-OFF
```

```
Module: boot_rom
RTL file: rtl/memory/boot_rom.sv
V0: PASS (testbench + reference model built)
V1: PASS (directed tests: 508 pass, 0 fail)
V2: PASS (randomized tests: 383 pass, 0 fail)
V3: PASS (assertions present and passing, 0 failures)
V4: PASS (functional coverage reviewed: 11/11 bins hit; any gap is unreachable by design, documented in report)
V5: PASS (reference model / scoreboard comparison passes)
V-SIGNOFF: PASS
Directed tests: 508
Random tests: 383
Seeds: 20260921
Assertions: passing, 0 failures
Coverage: 11/11
Reference model: yes (see STAGE4_VERIFICATION_REPORT.md section 2)
Known failures: none
Open bugs: none
Final status: SIGN-OFF
```

```
Module: sram_controller
RTL file: rtl/memory/sram_controller.sv
V0: PASS (testbench + reference model built)
V1: PASS (directed tests: 509 pass, 0 fail)
V2: PASS (randomized tests: 383 pass, 0 fail)
V3: PASS (assertions present and passing, 0 failures)
V4: PASS (functional coverage reviewed: 11/11 bins hit; any gap is unreachable by design, documented in report)
V5: PASS (reference model / scoreboard comparison passes)
V-SIGNOFF: PASS
Directed tests: 509
Random tests: 383
Seeds: 20260921
Assertions: passing, 0 failures
Coverage: 11/11
Reference model: yes (see STAGE4_VERIFICATION_REPORT.md section 2)
Known failures: none
Open bugs: none
Final status: SIGN-OFF
```

```
Module: memory_subsystem
RTL file: rtl/memory/memory_subsystem.sv
V0: PASS (testbench + reference model built)
V1: PASS (directed tests: 195 pass, 0 fail)
V2: PASS (randomized tests: 152 pass, 0 fail)
V3: PASS (assertions present and passing, 0 failures)
V4: PASS (functional coverage reviewed: 15/15 bins hit; any gap is unreachable by design, documented in report)
V5: PASS (reference model / scoreboard comparison passes)
V-SIGNOFF: PASS
Directed tests: 195
Random tests: 152
Seeds: 20260921
Assertions: passing, 0 failures
Coverage: 15/15
Reference model: yes (see STAGE4_VERIFICATION_REPORT.md section 2)
Known failures: none
Open bugs: none
Final status: SIGN-OFF
```

```
Module: timer
RTL file: rtl/peripherals/timer.sv
V0: PASS (testbench + reference model built)
V1: PASS (directed tests: 111 pass, 0 fail)
V2: PASS (randomized tests: 150 pass, 0 fail)
V3: PASS (assertions present and passing, 0 failures)
V4: PASS (functional coverage reviewed: 12/12 bins hit; any gap is unreachable by design, documented in report)
V5: PASS (reference model / scoreboard comparison passes)
V-SIGNOFF: PASS
Directed tests: 111
Random tests: 150
Seeds: 20260921
Assertions: passing, 0 failures
Coverage: 12/12
Reference model: yes (see STAGE4_VERIFICATION_REPORT.md section 2)
Known failures: none
Open bugs: none
Final status: SIGN-OFF
```

```
Module: uart
RTL file: rtl/peripherals/uart.sv
V0: PASS (testbench + reference model built)
V1: PASS (directed tests: 1556 pass, 0 fail)
V2: PASS (randomized tests: 240 pass, 0 fail)
V3: PASS (assertions present and passing, 0 failures)
V4: PASS (functional coverage reviewed: 11/11 bins hit; any gap is unreachable by design, documented in report)
V5: PASS (reference model / scoreboard comparison passes)
V-SIGNOFF: PASS
Directed tests: 1556
Random tests: 240
Seeds: 20260921
Assertions: passing, 0 failures
Coverage: 11/11
Reference model: yes (see STAGE4_VERIFICATION_REPORT.md section 2)
Known failures: none
Open bugs: none
Final status: SIGN-OFF
```

```
Module: gpio
RTL file: rtl/peripherals/gpio.sv
V0: PASS (testbench + reference model built)
V1: PASS (directed tests: 76 pass, 0 fail)
V2: PASS (randomized tests: 225 pass, 0 fail)
V3: PASS (assertions present and passing, 0 failures)
V4: PASS (functional coverage reviewed: 10/10 bins hit; any gap is unreachable by design, documented in report)
V5: PASS (reference model / scoreboard comparison passes)
V-SIGNOFF: PASS
Directed tests: 76
Random tests: 225
Seeds: 20260921
Assertions: passing, 0 failures
Coverage: 10/10
Reference model: yes (see STAGE4_VERIFICATION_REPORT.md section 2)
Known failures: none
Open bugs: none
Final status: SIGN-OFF
```

```
Module: interrupt_controller
RTL file: rtl/peripherals/interrupt_controller.sv
V0: PASS (testbench + reference model built)
V1: PASS (directed tests: 93 pass, 0 fail)
V2: PASS (randomized tests: 606 pass, 0 fail)
V3: PASS (assertions present and passing, 0 failures)
V4: PASS (functional coverage reviewed: 9/9 bins hit; any gap is unreachable by design, documented in report)
V5: PASS (reference model / scoreboard comparison passes)
V-SIGNOFF: PASS
Directed tests: 93
Random tests: 606
Seeds: 20260921
Assertions: passing, 0 failures
Coverage: 9/9
Reference model: yes (see STAGE4_VERIFICATION_REPORT.md section 2)
Known failures: none
Open bugs: none
Final status: SIGN-OFF
```

```
Module: rv32im_core
RTL file: rtl/core/rv32im_core.sv
V0: PASS (testbench + reference model built)
V1: PASS (directed tests: 334 pass, 0 fail)
V2: PASS (randomized tests: 1550 pass, 0 fail)
V3: PASS (assertions present and passing, 0 failures)
V4: PASS (functional coverage reviewed: 16/16 bins hit; any gap is unreachable by design, documented in report)
V5: PASS (reference model / scoreboard comparison passes)
V-SIGNOFF: PASS
Directed tests: 334
Random tests: 1550
Seeds: 20260921
Assertions: passing, 0 failures
Coverage: 16/16
Reference model: yes (see STAGE4_VERIFICATION_REPORT.md section 2)
Known failures: none
Open bugs: none
Final status: SIGN-OFF
```
