#!/usr/bin/env python3
"""
mutate_l1.py -- show that every L1 check can fail (PROJECT_INSTRUCTIONS 4.5).

Same method as ci/mutate_l0.py, whose snapshot and edit helpers it uses: for
the baseline and each mutant, a fresh copy of the working tree (no build
products, no git-ignored .elf files), the edits applied with exact-count
assertions, then ci/l1.sh inside the copy. A mutant is CAUGHT only if L1 exits
non-zero AND its expected check is FAIL. Each L1 run rebuilds every harness
from nothing, so this takes several minutes per run.

Usage:  python3 ci/mutate_l1.py [--keep]
Exit:   0 baseline passed and every mutant was caught; 1 otherwise.
"""

import importlib.util
import os
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

REPO = pathlib.Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location("mutate_l0", REPO / "ci/mutate_l0.py")
m0 = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m0)

CT = "verif/verilator/coverage/classify_toggles.py"
REAL_SAIL = os.path.expanduser("~/src/sail-riscv-bin/bin/sail_riscv_sim")
# "@WRAP:<name>@" is replaced at run time by a wrapper script around the real Sail.
WRAPPERS = {
    "exit1": '"{sail}" "$@"\nexit 1\n',
    "exit0": '"{sail}" "$@"\nexit 0\n',
    "silent0": '"{sail}" "$@" > /dev/null 2>&1\nexit 0\n',
}
MUTANTS = [
    ("R1", "lockstep", "RTL bug: SUB computes a + b",
     [("rtl/core/alu.sv", "      ALU_SUB:    result = a - b;\n", "      ALU_SUB:    result = a + b;\n", 1)], {}),
    ("X1", "lockstep", "wrong expected checksum for t05_csr",
     [("verif/sail/run_lockstep.sh", '    t05_csr)      echo "0x82a4c825" ;;',
       '    t05_csr)      echo "0x82a4c826" ;;', 1)], {}),
    # S1-S5 run with ~/work already holding the previous runs' Sail traces --
    # exactly the condition under which the pre-M3.7 run_lockstep.sh compared a
    # stale trace and reported agreement (measured 2026-10-30, docs/results/0030).
    ("S1", "lockstep", "reference model missing (exit 127, no trace)",
     [], {"SAIL": "/nonexistent/sail_riscv_sim"}),
    ("S2", "lockstep", "reference model exits 0 but writes no trace",
     [], {"SAIL": "/bin/true"}),
    # S3-S5 wrap the real Sail. Each defeats exactly one clause of the verdict
    # rule in run_lockstep.sh (trace present; one termination line; SUCCESS
    # with exit 0 or FAILURE with exit non-zero).
    ("S3", "lockstep", "Sail prints SUCCESS but exits 1",
     [], {"SAIL": "@WRAP:exit1@"}),
    ("S4", "lockstep", "Sail prints FAILURE but exits 0",
     [], {"SAIL": "@WRAP:exit0@"}),
    ("S5", "lockstep", "Sail exits 0 with a trace but no termination line",
     [], {"SAIL": "@WRAP:silent0@"}),
    ("H1", "swbuild", "tracked .hex no longer matches its .S",
     [("sw/tests/t01_alu.hex", None, b"00000013\n", 0)], {}),
    ("T1", "coverage", "rtl/core below a 5.3 target (toggle target raised to 99%)",
     [("verif/verilator/coverage/run_coverage.sh",
       'TARGET = {"line": 95.0, "branch": 95.0, "toggle": 90.0}',
       'TARGET = {"line": 95.0, "branch": 95.0, "toggle": 99.0}', 1)], {}),
    ("K1", "classify", "a classification rule deleted (points become unmatched)",
     [(CT, '  ("JALR_LSB", "construction", [("rv32_core.sv", "ex_jalr_target")], {0}, BOTH,\n'
           '   "JALR clears bit 0 (rv32_core.sv:405)"),\n', "", 1)], {}),
    ("K2", "classify", "a rule widened until two rules claim one point",
     [(CT, "LO, HI = {0, 1}, set(range(19, 32))", "LO, HI = {0, 1}, set(range(0, 32))", 1)], {}),
]


def run_l1(root, env_extra):
    env = dict(os.environ)
    env.update(env_extra)
    r = subprocess.run(["bash", str(root / "ci/l1.sh")], cwd=root, env=env,
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
    summary = r.stdout.split("==================== L1 SUMMARY", 1)
    fails = re.findall(r"^  \[FAIL\] (\S+)", summary[1], re.M) if len(summary) == 2 else ["NO-SUMMARY"]
    return r.returncode, fails, r.stdout


def main():
    keep = "--keep" in sys.argv
    work = pathlib.Path(tempfile.mkdtemp(prefix="mutate_l1_"))
    print(f"mutate_l1: work dir {work}")
    rows, ok_all = [], True

    base = work / "baseline"
    n = m0.snapshot(base)
    rc, fails, log = run_l1(base, {})
    (work / "baseline.log").write_text(log)
    if not keep:
        shutil.rmtree(base)
    print(f"\n==================== BASELINE ({n} files)\n{log}")
    if rc != 0:
        print(f"mutate_l1: BASELINE FAILED (exit {rc}) -- mutants would prove nothing")
        ok_all = False
    rows.append(("base", "-", "unmodified tree", "PASS" if rc == 0 else "FAIL", rc, ",".join(fails) or "-"))

    wrap = {}
    for name, body in WRAPPERS.items():
        w = work / f"sail_{name}.sh"
        w.write_text("#!/bin/sh\n" + body.format(sail=REAL_SAIL))
        w.chmod(0o755)
        wrap[f"@WRAP:{name}@"] = str(w)

    for mid, want, what, edits, env in MUTANTS:
        env = {k: wrap.get(v, v) for k, v in env.items()}
        root = work / mid
        m0.snapshot(root)
        err = None
        for path, old, new, count in edits:
            err = m0.apply(root, path, old, new, count)
            if err:
                err = f"{path}: {err}"
                break
        if not edits and not env:
            err = "mutant has neither edits nor environment"
        if err:
            print(f"\n==================== {mid}: MUTATION NOT APPLIED -- {err}")
            rows.append((mid, want, what, "ERROR", "-", "edit not applied"))
            ok_all = False
            continue
        rc, fails, log = run_l1(root, env)
        (work / f"{mid}.log").write_text(log)
        if not keep:
            shutil.rmtree(root)
        print(f"\n==================== {mid} [{want}] {what}\n{log}")
        caught = rc != 0 and want in fails
        ok_all &= caught
        rows.append((mid, want, what, "CAUGHT" if caught else "MISSED", rc, ",".join(fails) or "-"))

    print("\n==================== MUTATION SUMMARY (L1)")
    print(f"  {'id':<5} {'expected':<10} {'verdict':<7} {'exit':<4} {'checks failed':<32} what")
    for mid, want, what, verdict, rc, fails in rows:
        print(f"  {mid:<5} {want:<10} {verdict:<7} {str(rc):<4} {fails:<32} {what}")
    n_caught = sum(1 for r in rows if r[3] == "CAUGHT")
    print(f"  {n_caught} of {len(MUTANTS)} mutants caught; baseline {rows[0][3]}")
    if keep:
        print(f"  copies kept in {work}")
    else:
        shutil.rmtree(work)
    print("MUTATE_L1: " + ("PASS" if ok_all else "FAIL"))
    sys.exit(0 if ok_all else 1)


if __name__ == "__main__":
    main()
