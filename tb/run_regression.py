#!/usr/bin/env python3
"""Module-level verification regression runner (Stage 4).

Builds each testbench with Verilator (--binary --timing --assert --coverage)
and runs it with a recorded seed.  Parses the single RESULT line each TB
prints and writes sim/logs/regression.json + a human-readable summary.

Usage:  python3 tb/run_regression.py [--only NAME] [--seed N]
"""
import json, os, re, subprocess, sys, argparse

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SIM  = os.path.join(ROOT, "sim")
LOGS = os.path.join(SIM, "logs")
RTL  = os.path.join(ROOT, "rtl")

PKG  = f"{RTL}/rv32im_pkg.sv"
COMMON = None  # infra is an include file now

# name -> (rtl sources, tb file, extra verilator args)
TESTS = {
  # ---- Phase 2: basic/core ----
  "alu":              ([f"{RTL}/core/alu.sv"], "tb_alu.sv", []),
  "immediate_gen":    ([f"{RTL}/core/immediate_gen.sv"], "tb_immediate_gen.sv", []),
  "register_file":    ([f"{RTL}/core/register_file.sv"], "tb_register_file.sv", []),
  "branch_unit":      ([f"{RTL}/core/branch_unit.sv"], "tb_branch_unit.sv", []),
  "decoder":          ([f"{RTL}/core/decoder.sv"], "tb_decoder.sv", []),
  "pc_unit":          ([f"{RTL}/core/pc_unit.sv"], "tb_pc_unit.sv", []),
  "pipeline_regs":    ([f"{RTL}/core/pipeline_regs.sv"], "tb_pipeline_regs.sv", []),
  # ---- Phase 3: pipeline control ----
  "forwarding_unit":  ([f"{RTL}/core/forwarding_unit.sv"], "tb_forwarding_unit.sv", []),
  "hazard_unit":      ([f"{RTL}/core/hazard_unit.sv"], "tb_hazard_unit.sv", []),
  # ---- Phase 4: M extension (both implementations) ----
  "muldiv_m0":        ([f"{RTL}/core/muldiv_unit.sv"], "tb_muldiv_unit.sv", ["-GMUL_IMPL=0"]),
  "muldiv_m1":        ([f"{RTL}/core/muldiv_unit.sv"], "tb_muldiv_unit.sv", ["-GMUL_IMPL=1"]),
  # ---- Phase 5: CSR/trap ----
  "csr_file":         ([f"{RTL}/core/csr_file.sv"], "tb_csr_file.sv", []),
  # ---- Phase 6: branch prediction ----
  "bp_static":        ([f"{RTL}/core/branch_predictor.sv"], "tb_branch_predictor.sv", ["-GENABLE_BHT=0", "-GENABLE_BTB=0"]),
  "bp_bht":           ([f"{RTL}/core/branch_predictor.sv"], "tb_branch_predictor.sv", ["-GENABLE_BHT=1", "-GENABLE_BTB=0"]),
  "bp_btb":           ([f"{RTL}/core/branch_predictor.sv"], "tb_branch_predictor.sv", ["-GENABLE_BHT=1", "-GENABLE_BTB=1"]),
  # ---- Phase 7: caches ----
  "cache_arrays":     ([f"{RTL}/cache/cache_arrays.sv"], "tb_cache_arrays.sv", []),
  "icache_c1":        ([f"{RTL}/cache/cache_arrays.sv", f"{RTL}/cache/icache.sv"], "tb_icache.sv", []),
  "icache_c2":        ([f"{RTL}/cache/cache_arrays.sv", f"{RTL}/cache/icache.sv"], "tb_icache.sv", ["-GLINES=4", "-GLINE_BYTES=8"]),
  "icache_c0":        ([f"{RTL}/cache/cache_arrays.sv", f"{RTL}/cache/icache.sv"], "tb_icache.sv", ["-GENABLE=0"]),
  "dcache_c1":        ([f"{RTL}/cache/cache_arrays.sv", f"{RTL}/cache/dcache.sv"], "tb_dcache.sv", []),
  "dcache_c2":        ([f"{RTL}/cache/cache_arrays.sv", f"{RTL}/cache/dcache.sv"], "tb_dcache.sv", ["-GLINES=4", "-GLINE_BYTES=8"]),
  "dcache_c0":        ([f"{RTL}/cache/cache_arrays.sv", f"{RTL}/cache/dcache.sv"], "tb_dcache.sv", ["-GENABLE=0"]),
  # ---- Phase 8: bus ----
  "axi4_master_rw":   ([f"{RTL}/bus/axi4_master.sv"], "tb_axi4_master.sv", ["-GREAD_ONLY=0"]),
  "axi4_master_ro":   ([f"{RTL}/bus/axi4_master.sv"], "tb_axi4_master.sv", ["-GREAD_ONLY=1"]),
  "axi_err_decerr":   ([f"{RTL}/bus/axi4_interconnect.sv"], "tb_axi_err_slave.sv", ["-GRESP=3"]),
  "axi_err_slverr":   ([f"{RTL}/bus/axi4_interconnect.sv"], "tb_axi_err_slave.sv", ["-GRESP=2"]),
  "axi4_interconnect":([f"{RTL}/bus/axi4_interconnect.sv", f"{RTL}/memory/sram_controller.sv"],
                       "tb_axi4_interconnect.sv", []),
  "axi_to_apb":       ([f"{RTL}/bus/axi_to_apb.sv"], "tb_axi_to_apb.sv", []),
  # ---- Phase 9: memory ----
  "boot_rom":         ([f"{RTL}/bus/axi4_interconnect.sv", f"{RTL}/memory/boot_rom.sv"],
                       "tb_axi_mem_slave.sv", ["-GIS_ROM=1"]),
  "sram_controller":  ([f"{RTL}/memory/sram_controller.sv"], "tb_axi_mem_slave.sv", ["-GIS_ROM=0"]),
  "memory_subsystem": (["MEMSUB"], "tb_memory_subsystem.sv", []),
  # ---- Phase 10: peripherals ----
  "timer":            ([f"{RTL}/peripherals/timer.sv"], "tb_timer.sv", []),
  "uart":             ([f"{RTL}/peripherals/uart.sv"], "tb_uart.sv", []),
  "gpio":             ([f"{RTL}/peripherals/gpio.sv"], "tb_gpio.sv", []),
  "intc":             ([f"{RTL}/peripherals/interrupt_controller.sv"], "tb_intc.sv", []),
  # ---- Phase 11: CPU integration ----
  "rv32im_core":      (["CORE"], "tb_rv32im_core.sv", []),
  # ---- Phase 12: SoC top-level integration (no prior testbench) ----
  "rv32im_soc":       (["SOC"], "tb_rv32im_soc.sv", []),
  # ---- Stage 5 / Stage 6 ----
  "cpu_stage5":       (["CORE"], "cpu/tb_cpu_stage5.sv", []),
  "soc_stage6":       (["SOC"],  "soc/tb_soc_stage6.sv", []),
}

MEMSUB_SRC = [f"{RTL}/cache/cache_arrays.sv", f"{RTL}/cache/icache.sv", f"{RTL}/cache/dcache.sv",
              f"{RTL}/bus/axi4_master.sv", f"{RTL}/bus/axi4_interconnect.sv",
              f"{RTL}/memory/boot_rom.sv", f"{RTL}/memory/sram_controller.sv",
              f"{RTL}/memory/memory_subsystem.sv"]
CORE_SRC = [f"{RTL}/core/{m}.sv" for m in
            ["pipeline_regs", "pc_unit", "register_file", "immediate_gen", "decoder", "alu",
             "branch_unit", "forwarding_unit", "hazard_unit", "muldiv_unit", "csr_file",
             "branch_predictor", "rv32im_core"]]
SOC_SRC = CORE_SRC + MEMSUB_SRC + [
    f"{RTL}/bus/axi_to_apb.sv",
    f"{RTL}/peripherals/timer.sv", f"{RTL}/peripherals/uart.sv",
    f"{RTL}/peripherals/gpio.sv", f"{RTL}/peripherals/interrupt_controller.sv",
    f"{RTL}/soc/rv32im_soc.sv",
]

RESULT_RE = re.compile(r"RESULT (.*)")


def gen_rom_hex():
    """rom_test.hex: word i = (0x10000000 + i*0x111) ^ 0xA5A50000  (same formula as tb rom_word())"""
    os.makedirs(SIM, exist_ok=True)
    with open(os.path.join(SIM, "rom_test.hex"), "w") as f:
        for i in range(64):
            f.write("%08x\n" % (((0x10000000 + i * 0x111) ^ 0xA5A50000) & 0xFFFFFFFF))


def gen_soc_fw():
    """Assembles tb/soc_asm/gen_soc_fw.py -> sim/soc_test.hex (SoC bring-up firmware)."""
    for g in ("soc_asm/gen_soc_fw.py", "cpu/gen_cpu_programs.py", "soc/gen_soc_stage6_fw.py"):
        subprocess.run([sys.executable, os.path.join(ROOT, "tb", g)], check=True,
                       stdout=subprocess.DEVNULL)


def build_and_run(name, seed):
    srcs, tb, extra = TESTS[name]
    if srcs == ["MEMSUB"]: srcs = MEMSUB_SRC
    if srcs == ["CORE"]:   srcs = CORE_SRC
    if srcs == ["SOC"]:    srcs = SOC_SRC
    if srcs == ["SOC"]:    srcs = SOC_SRC
    tbfile = os.path.join(ROOT, "tb", tb)
    top = os.path.splitext(os.path.basename(tb))[0]
    mdir = os.path.join(SIM, "obj_" + name)
    cmd = ["verilator", "--binary", "--timing", "--assert", "--coverage",
           "-Wno-fatal", "-Wno-DECLFILENAME", "-Wno-UNUSEDSIGNAL", "-Wno-UNUSEDPARAM",
           "-Wno-WIDTHEXPAND", "-Wno-WIDTHTRUNC",
           "--top-module", top, "-o", name, "--Mdir", mdir,
           "+incdir+" + os.path.join(ROOT, "tb", "common")] + extra + \
          [PKG] + srcs + [tbfile]
    b = subprocess.run(cmd, capture_output=True, text=True, cwd=ROOT)
    if b.returncode != 0:
        return {"name": name, "status": "BUILD-FAIL",
                "log": (b.stdout + b.stderr)[-4000:]}
    exe = os.path.join(mdir, name)
    r = subprocess.run([exe, f"+SEED={seed}", "+verilator+rand+reset+2"],
                       capture_output=True, text=True, cwd=SIM, timeout=1800)
    out = r.stdout + r.stderr
    m = RESULT_RE.search(out)
    if not m:
        return {"name": name, "status": "RUN-FAIL", "log": out[-4000:]}
    res = {"name": name, "seed": seed}
    for kv in m.group(1).split():
        k, v = kv.split("=", 1)
        res[k] = int(v) if v.isdigit() else v
    # count $error / assertion failures reported by Verilator
    res["assert_fail"] = out.count("%Error: ") + out.count("Assertion failed")
    # activity guard: a TB that executed nothing must never be reported as PASS
    executed = res.get("dir_pass", 0) + res.get("rnd_total", 0)
    if executed == 0:
        res["status"] = "NO-ACTIVITY"
    else:
        res["status"] = "PASS" if (res.get("dir_fail", 1) == 0 and res.get("rnd_fail", 1) == 0
                                   and res["assert_fail"] == 0) else "FAILURE"
    res["log"] = out[-6000:]
    with open(os.path.join(LOGS, f"run_{name}.log"), "w") as f:
        f.write(out)
    return res


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", default=None)
    ap.add_argument("--seed", type=int, default=20260921)
    a = ap.parse_args()
    os.makedirs(LOGS, exist_ok=True)
    gen_rom_hex()
    gen_soc_fw()
    gen_soc_fw()
    names = [a.only] if a.only else list(TESTS)
    out = []
    for n in names:
        r = build_and_run(n, a.seed)
        out.append(r)
        print(f"{r['status']:12s} {n:20s} dir={r.get('dir_pass','-')}/{r.get('dir_fail','-')} "
              f"rnd={r.get('rnd_pass','-')}/{r.get('rnd_fail','-')} "
              f"cov={r.get('cov_hit','-')}/{r.get('cov_bins','-')}")
        if r["status"] != "PASS":
            print(r.get("log", "")[-2500:])
    tot_r = sum(x.get("rnd_total", 0) for x in out)
    print(f"\nTOTAL random tests executed: {tot_r}")
    print("Modules PASS: %d / %d" % (sum(1 for x in out if x["status"] == "PASS"), len(out)))
    prev = {}
    jf = os.path.join(LOGS, "regression.json")
    if a.only and os.path.exists(jf):
        prev = {x["name"]: x for x in json.load(open(jf))}
    for x in out: prev[x["name"]] = x
    json.dump(list(prev.values()), open(jf, "w"), indent=1)


if __name__ == "__main__":
    main()
